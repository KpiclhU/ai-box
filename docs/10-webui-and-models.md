# 10 — Web UI, connectors and model management

Three things people ask for after the model answers: a chat window, tools the model can call,
and a way to see the whole model library without editing a unit file. On this box all three
come from llama.cpp itself; the heavyweight alternatives are at the bottom.

Everything here stays on loopback and is reached from your laptop over the tunnel from
[docs/04](04-llm-stack.md):

```bash
ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai@ai-box
```

## The built-in UI (nothing to install)

`llama-server` serves **Llama Chat** on the same port as the API:

```
http://127.0.0.1:8080
```

Open that through the tunnel and you have streaming chat, Markdown, code blocks, LaTeX,
collapsible reasoning, conversation branching, search, JSON import/export, image/PDF/audio
attachments for multimodal models, and structured output via a custom JSON schema. No extra
service, no extra RAM, no second copy of the model — it is the same process that already
answers `/v1/chat/completions`.

Useful server-side UI flags:

| Flag | Effect |
|---|---|
| `--ui-config '{"theme":"dark"}'` | default preferences for everyone |
| `--no-ui` | disable the UI, API only |
| `--host 0.0.0.0` | expose it to the LAN — **don't**; there is no auth (see *Access from the LAN*) |

### Images

Llama Chat has **no image generation of its own** — the built-in tools are the file/shell set
(`read_file`, `exec_shell_command`, …) and there is no image-backend flag. To draw from the
chat, either give the server the shell tool and let the model run
`scripts/97-comfy-gen.sh` (writes a PNG, replies with the path), or put Open WebUI in front
and use its Image Generation tool, which speaks ComfyUI natively. Both, plus model management
for the ComfyUI side (`scripts/96-comfy-models.sh`), are in
[05-image-generation.md](05-image-generation.md#getting-an-image-out-of-the-chat-window).

The shell tool is a real hazard: `--tools`/`--agent` expose command execution over the API.
llama-server pins `--cors-origins` to localhost when they are on, and refuses non-loopback
binds without `--allow-unauthenticated-tools` — leave that alone unless the box is isolated.

## Access from the LAN

Nothing binds `0.0.0.0` on purpose: there is no auth in llama-server, ComfyUI or the bot, so
exposing them raw means anyone on the network can drive your box — and if MCP tools or
`--agent` are on, "use the model" becomes "run code on the machine".

Two sane ways out.

### Proxying from a Caddy on another machine

The box has no authentication of its own, so the proxy authenticates — on whichever machine
already runs Caddy:

```bash
sudo ./scripts/80-lan-access.sh --proxy 192.168.1.10
```

`--proxy` is the Caddy host's IP (or a CIDR). ai-box installs no proxy and keeps no
`Caddyfile` of its own. The script:

1. sets `HOST=0.0.0.0` in `llama-server.env`/`llama-router.env` and `comfyui.env`, then
   restarts whichever llama unit is running plus ComfyUI;
2. writes the site blocks for the Caddy box to `~/.config/ai-box/caddy-ai-box.caddy`;
3. adds ufw rules letting **only** `--proxy`'s address reach 8080/8188.

Then, on the Caddy box:

```bash
scp ai-user@ai-box:~/.config/ai-box/caddy-ai-box.caddy /etc/caddy/caddy-ai-box.caddy
# add one line to its Caddyfile:  import /etc/caddy/caddy-ai-box.caddy
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

The published URLs are `http://<caddy-box>:8090` and `http://<caddy-box>:8190`, or pass
`--hostnames ai.example.com comfy.example.com` to use names whose DNS points at the Caddy box —
Caddy then gets certificates automatically and you get HTTPS. Other flags: `--user`,
`--password`, `--proxy-ports 8090 8190`, `--ai-ip` (when `hostname -I` picks the wrong
interface), `--dry-run`, `--revert`.

What to know:

- **The ufw rules are the security boundary.** Nothing on ai-box authenticates, so if ufw is
  inactive the ports are open to your whole LAN; the script says so and prints the rules to
  add. `--revert` puts the env files back on `127.0.0.1` and deletes the snippet.
- **The bcrypt hash is generated here** from `caddy`, `htpasswd` or python-bcrypt if any is
  present. If none is, the snippet contains `__BCRYPT_HASH__` and the script tells you to run
  `caddy hash-password` on the Caddy box and paste the result over both occurrences.
- **Credentials live on the Caddy box**, in that one file; keep it out of any repo you
  publish.
- **Caddy adds `X-Forwarded-For` itself**, so the `/v1` API needs no extra headers.
- **Never port-forward 8080/8188.** Only the Caddy box should reach them, and only its
  80/443 should face outward.
- **The bot is unaffected** — it keeps talking to `127.0.0.1:8080`.

### VPN instead of opening ports

Tailscale (or plain WireGuard) gives you `http://ai-box:8080` from your laptop anywhere with
no proxy and no exposed port. The trade-off is a third-party account and a client on each
device. If you go that way, bind the services to the VPN interface only — with Tailscale that
means `--host 0.0.0.0` plus `ufw allow in on tailscale0 to any port 8080,8188` — rather than
relying on the router's firewall alone.

## Connectors (MCP tools)

The UI is an MCP host. Point the server at a Cursor-compatible JSON file and every MCP server
in it becomes a tool the model can call (`GET /tools` lists them):

```bash
llama-server ... --mcp-servers-config ~/.config/ai-box/mcp.json
```

`mcp.example.json` in the repo root is a starting point. Copy it and edit the paths:

```bash
mkdir -p ~/.config/ai-box
cp mcp.example.json ~/.config/ai-box/mcp.json
```

With the systemd service, add the flag to the extra-args line instead of the unit:

```
LLAMA_EXTRA_ARGS="--ctx-size 32768 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --mcp-servers-config /home/ai-user/.config/ai-box/mcp.json"
```

```bash
sudo systemctl restart llama-server
journalctl -u llama-server -n 30 --no-pager     # each server is listed once at startup
```

What to know before you point it at your files:

- **stdio only.** llama-server spawns each MCP server as a child process and speaks JSON-RPC
  over its stdin/stdout. Nothing is installed permanently and nothing listens on a port.
- **Every server is started once at boot** to list its tools, then stopped and restarted on
  demand. A server that needs a token gets it from the `env` block in the JSON.
- **systemd's PATH is `/usr/bin:/bin`.** Use absolute paths (`/usr/bin/npx`,
  `~/.local/bin/uvx`) or the child process will not start. `npx` needs
  `sudo apt install -y nodejs npm`; `uvx` needs `uv`.
- **Tools are named `<server>_<tool>`**, so keep server names short and unique.
- **The model must be able to call tools.** `--jinja` is already in the extra args, and a
  30B-class model is fine; a 4B model will mostly ignore the tools.
- **Loopback only.** `--mcp-servers-config` pins `--cors-origins` to localhost and
  `--allow-unauthenticated-tools` on a LAN address is a remote-code-execution hole by design.
- **`--agent`** additionally enables the built-in tools and the CORS proxy. It is a bigger
  surface than a hand-written `mcp.json`; enable it only while you are watching.

Reaching a *remote* MCP server from the browser (one with a URL and no CORS headers) is what
`--ui-mcp-proxy` is for. It refuses loopback, LAN and link-local addresses on purpose, so it
does nothing for servers running on this box.

Cost: each MCP tool schema goes into the prompt, and each call is tokens. Three servers is
pleasant; fifteen makes a 30B model worse at its actual job.

## Model management: router mode

The default unit serves exactly one model, named by `MODEL=` in
`~/.config/ai-box/llama-server.env`. Router mode serves *every* GGUF you own behind one port,
loads a model on first request, and unloads the least recently used one. Same API, same UI,
same port — plus a model selector in the UI and an HTTP API for the library.

```bash
sudo systemctl disable --now llama-server
sudo systemctl enable --now llama-router
```

`50-install-services.sh` writes `~/.config/ai-box/llama-router.env`:

```
MODELS_DIR=/home/ai-user/ai/models
MODELS_MAX=1
HOST=127.0.0.1
PORT=8080
LLAMA_EXTRA_ARGS="--ctx-size 32768 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2"
```

`MODELS_MAX=1` is deliberate. On ~48 GiB of shared GTT two 24 GB models do not fit, and the
router's default of 4 would try. The two units `Conflicts=` each other, so enabling one stops
the other; enable only one at a time.

Then:

```bash
./scripts/95-models.sh list                      # what the router can see, plus load state
./scripts/95-models.sh load Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf
./scripts/95-models.sh unload Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf
./scripts/95-models.sh download unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M
./scripts/95-models.sh reload                    # rescan MODELS_DIR after copying a file in
```

The same thing over the API, if you prefer:

| Request | Effect |
|---|---|
| `GET /models` | every model and its state (`loaded`, `loading`, `sleeping`, `downloading`, `incomplete`) |
| `POST /models/load` `{"model":"x.gguf"}` | load now |
| `POST /models/unload` `{"model":"x.gguf"}` | free the memory |
| `POST /models` `{"model":"user/repo:Q4_K_M"}` | download from Hugging Face into the cache |
| `GET /models/sse` | live events for the above |
| `GET /models?reload=1` | rescan the model sources |

### Model names, and what breaks

With `--models-dir`, the model id **is the file name**:
`Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf`. Requests have to carry it in the `model` field, and
the Discord bot sends `LLM_MODEL` from `./.env`, whose default is `local`. Switching to the
router therefore means:

```
# ./.env
LLM_MODEL=Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf
```

```bash
sudo systemctl restart ai-discord-bot
```

Friendly names come from a preset file. This also gives per-model arguments, which matters as
soon as two models want different context sizes:

```bash
llama-server --models-preset ~/.config/ai-box/models.ini
```

```ini
version = 1

[*]
ctx-size = 32768
n-gpu-layers = 999
flash-attn = on
jinja = true
parallel = 2

[coder]
model = /home/ai-user/ai/models/Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf

[chat]
model = /home/ai-user/ai/models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf
c = 16384
```

Now `LLM_MODEL=coder` survives a model swap, and `--models-preset` replaces `--models-dir`
(pass it inside `LLAMA_EXTRA_ARGS`).

Two gotchas worth knowing:

- **Memory.** A model stays loaded until something else needs the room. Before a ComfyUI
  Flux job, unload it: `./scripts/95-models.sh unload <model>`, or run ComfyUI's
  `POST /free {"unload_models": true}` only — that one frees ComfyUI's models, not the LLM's.
- **First request is slow.** A 24 GB model has to come off NVMe; the UI shows `loading` and
  the chat request waits. That is not a dead connection. `--no-models-autoload` plus an
  explicit `load` is the alternative if you would rather preload.

## If you want a real web app instead

The built-in UI is one conversation list on one machine, with no accounts. If you need users,
retrieval over documents, or a prettier chat surface, these two are the usual answers; both
talk to the same `http://127.0.0.1:8080/v1` and both support MCP.

**Open WebUI** — the closest thing to a drop-in. Native MCP since v0.6.31
(*Admin → Settings → Integrations → External Tool Servers → + Add Connection*, type
**MCP (Streamable HTTP)**; stdio servers go through `mcpo`). Add the llama.cpp endpoint as an
OpenAI connection: `http://127.0.0.1:8080/v1`, no key. It is a separate app with its own
database, so it costs ~1–2 GB of RAM and a second model copy is *not* involved. Run it in
Docker (`ghcr.io/open-webui/open-webui:main`) with `--network=host` or an
`--add-host=host.docker.internal:host-gateway` entry, since `127.0.0.1` inside a container is
the container. Set `WEBUI_SECRET_KEY`, or OAuth-connected tools re-authenticate on every
restart. Reach it through one more `ssh -L 3000:127.0.0.1:8080`-style forward — do not bind
it to the LAN without auth.

**LibreChat** — heavier (MongoDB, Meilisearch, a RAG service), but it has agents, per-chat MCP
toggles and a `librechat.yaml` that keeps model and MCP config in version control. Custom
OpenAI-compatible endpoint plus an `mcpServers:` block. Worth it only if you want the agent
builder; otherwise it is a lot of moving parts for one user.

What none of them fix: a 30B model on a 256 GB/s memory bus. A prettier UI does not change
tok/s, and RAG over your notes still competes for the same 48 GiB.
