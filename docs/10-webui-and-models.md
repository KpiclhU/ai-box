# 10 — Web UI, connectors and model management

> **The household front door is Open WebUI** ([12](12-deployment-and-client.md)): accounts,
> chat and images on `:3000` behind the Caddy VM. This page documents llama.cpp's own UI and APIs — the
> admin/debug surface and the model-management features the front door does not replace.

Three things people ask for after the model answers: a chat window, tools the model can call,
and a way to see the whole model library without editing a unit file. On this box the first
two are covered by Open WebUI; the llama.cpp features below remain the admin path.

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
llama-server pins `--cors-origins` to localhost when they are on, and refuses a non-loopback
bind without either an `--api-key` or `--allow-unauthenticated-tools` — the key is the one to
use.

### Server tools: files, shell and the internet

`--tools` switches on llama-server's built-in tools. The set is deliberately minimal, and
there is **no web-search or fetch tool** — internet access is `exec_shell_command` running
`curl` as `ai-user` on this box, with whatever network the box has:

| Tool | What it does |
|---|---|
| `read_file` | file contents, optionally a 1-based line range (64 MB cap) |
| `file_glob_search`, `grep_search` | find files by glob; regex search with context lines |
| `exec_shell_command` | one shell command: `curl`, `git`, `python3`, `97-comfy-gen.sh …` |
| `write_file`, `edit_file` | create a file; apply an edit to an existing one |
| `get_info` | `uname -a` and the working directory the tools run in |

```
# ~/.config/ai-box/llama-router.env   (single-model unit: llama-server.env)
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --mcp-servers-config /home/ai-user/.config/ai-box/mcp.json --api-key KEY --cors-origins https://ai-chat.example.com --tools all"
```

`all` is shorthand; name them to leave some out
(`--tools read_file,file_glob_search,grep_search,get_info`). `exec_shell_command` is not a
lesser tool — one command can write anything — so a subset without it is the only
read-only variant.

What to know before switching it on:

- **The agent loop lives in the browser.** Llama Chat fetches `GET /tools`, offers those
  definitions to the model, and `POST`s each call back. llama.cpp keeps no server-side loop
  on purpose, so anything that talks to `/v1` directly — your editor, a script — never
  gets these tools. Only the Web UI runs them.
- **`--cors-origins` has to name the origin you open.** `--tools`, `--agent` and
  `--mcp-servers-config` all pin CORS to `localhost`, so the UI at `https://ai-chat.…` is
  refused unless that origin is spelled out. It is the same flag the API-key setup needs.
- **One command may run 60 s and return 16 KB.** The model chooses the timeout (default
  10 s, hard max 60) and the output cap is fixed. Long jobs do not fit: a first ComfyUI run
  that compiles kernels will be killed, so use the `comfyui_*` MCP tools for images and
  `nohup … &` plus a log file for anything slower.
- **Prompt injection is the actual risk.** Any page `curl` prints, any file `read_file`
  returns, can tell the model to run something else. Keep `write_file`/`edit_file` off
  unless you are using them, and do not leave `--tools all` reachable by more than you.
- **The tools inherit systemd's environment**: `ai-user`, its SSH keys, and the repo `.env`
  with whichever secrets are on the box. `--tools-runtime docker:<image>` (needs Docker) or
  `ssh:<target>` moves execution into a container or another host. There is no allowlist.
- **Router mode** passes `LLAMA_EXTRA_ARGS` to every child, so the tools follow whichever
  model is loaded; `/tools` stays empty until one loads.

## Access from the LAN

> **The default is now the front door** ([12](12-deployment-and-client.md)): Open WebUI on
> `:3000` behind the Caddy VM, with `llama-server` and ComfyUI on loopback. This
> section is the **legacy** direct-UI layout — useful for an admin-only box with no accounts.
> Do not run both.

Nothing else binds `0.0.0.0` on purpose: there is no auth in llama-server or ComfyUI, so
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

1. checks the firewall — ufw active with `Default: deny (incoming)` — and adds rules letting
   **only** `--proxy`'s address reach 8080/8188;
2. sets `HOST=0.0.0.0` in `llama-server.env`/`llama-router.env` and `comfyui.env`, then
   restarts whichever llama unit is running plus ComfyUI;
3. writes the site blocks for the Caddy box to `~/.config/ai-box/caddy-ai-box.caddy`.

With ufw missing, inactive or default-allow it stops with both services still on `127.0.0.1`
and exits non-zero, printing the rules to add.

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

- **The ufw rules are the security boundary.** Nothing on ai-box authenticates, so the bind
  only happens once they exist; `sudo AI_BOX_UNFIREWALLED=1` skips the gate for a box already
  covered by firewalld, nftables or a VLAN ACL. `--revert` puts the env files back on
  `127.0.0.1` and deletes the snippet.
- **The bcrypt hash is generated here** from `caddy`, `htpasswd` or python-bcrypt if any is
  present. If none is, the snippet contains `__BCRYPT_HASH__` and the script tells you to run
  `caddy hash-password` on the Caddy box and paste the result over both occurrences.
- **Credentials live on the Caddy box**, in that one file; keep it out of any repo you
  publish.
- **Caddy adds `X-Forwarded-For` itself**, so the `/v1` API needs no extra headers.
- **Never port-forward 8080/8188.** Only the Caddy box should reach them, and only its
  80/443 should face outward.
- **Open WebUI is unaffected** — it keeps talking to `127.0.0.1:8080`.

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
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --mcp-servers-config /home/ai-user/.config/ai-box/mcp.json"
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

### ComfyUI: let the router draw

`scripts/comfy-mcp.py` is an MCP server for ComfyUI that ships with this repo: stdlib only,
no `mcp` SDK, no venv, nothing to download at boot. That matters because llama-server starts
every MCP server once at startup and again on each model load — an `npx`/`uvx` server pays a
registry round-trip each time, this one starts in milliseconds.

Tools it exposes (`comfyui_*` once llama.cpp namespaces them):

| Tool | What it does |
|---|---|
| `generate_image` | Queues the repo's SDXL graph, waits, returns the PNG path, a `/view` URL and a markdown image line |
| `list_models` | Checkpoints and diffusion models ComfyUI can actually load right now |
| `status` | Device, free/total memory, queue depth |
| `free_memory` | `POST /free` — drop cached weights before the LLM needs the room |

```bash
chmod +x ~/ai-box/scripts/comfy-mcp.py
mkdir -p ~/.config/ai-box
cat > ~/.config/ai-box/mcp.json <<'JSON'
{
  "mcpServers": {
    "comfyui": {
      "command": "/usr/bin/python3",
      "args": ["/home/ai-user/ai-box/scripts/comfy-mcp.py"],
      "env": {
        "COMFY_URL": "http://127.0.0.1:8188",
        "COMFY_PUBLIC_URL": "https://comfy.example.com"
      },
      "timeout_ms": 900000
    }
  }
}
JSON
```

`timeout_ms` is llama.cpp's cap on a single tool call (default 30 s) — too short for a ComfyUI
job that has to load SDXL first. `COMFY_PUBLIC_URL` is the address the *link* uses while
`COMFY_URL` stays loopback; leave it out and the link is local too.

Then add one flag to `LLAMA_EXTRA_ARGS` in the env file of the unit you are **actually**
running. The router reads `llama-router.env`; `llama-server.env` is ignored while
`llama-router.service` owns the port:

```
# ~/.config/ai-box/llama-router.env
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 \
  --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 \
  --mcp-servers-config /home/ai-user/.config/ai-box/mcp.json"
```

It has to be one line in the file — the unit splits this string on whitespace, so the `\`
above is just how it is printed here.

```bash
sudo systemctl restart llama-router
curl -s localhost:8080/tools | head -40    # comfyui_generate_image must be listed
journalctl -u llama-router -n 40 --no-pager | grep -i mcp
```

What is different in router mode:

- **Every model gets the tools.** `LLAMA_EXTRA_ARGS` is passed to each model instance, so the
  image tools follow whichever GGUF you load. Harmless — unlike `--spec-type draft-mtp`, a
  tool config cannot stop a model from loading; it costs prompt tokens and nothing else.
- **`/tools` is empty until a model is loaded.** The router spawns its children when it loads
  a model, and it loads on the first request. Send a chat message, then check again.
- **The image is written by ComfyUI, not by this server.** `SaveImage` puts it in
  `~/ai/comfyui/output/` (prefix `chat_`), and the tool returns that path plus a `/view?...`
  URL. With no `COMFY_PUBLIC_URL` the URL is `http://127.0.0.1:8188/view?...` and only the
  tunnel (`-L 8188:127.0.0.1:8188`) reaches it; set `COMFY_PUBLIC_URL` to the published name
  and the same link works in a browser off the box. The Caddy site has `basic_auth`, so the
  inline image renders once that browser has logged in to the ComfyUI host.
- **Ask in plain language:** *“draw a corgi astronaut, cinematic lighting”*. SDXL takes
  15–25 s; the model sits in the tool call until then, which is expected, not a hang.
- **Tool-call timeouts.** Some builds cap a single MCP call. SDXL and Flux-schnell finish well
  inside any sane cap; a 20-step Flux.1-dev job may not — run those from
  `scripts/97-comfy-gen.sh` instead.
- **Memory.** SDXL (~10 GB) fits alongside a 25 GB model in the 48 GiB pool. Flux.1-dev
  (~34 GB) does not: unload the model in the router UI (`POST /models/unload`) first, or call
  the `comfyui_free_memory` tool between jobs.
- **Keep `HOST=127.0.0.1`.** With tools enabled, llama.cpp refuses a non-loopback bind unless
  you pass `--allow-unauthenticated-tools`, which turns "use my model" into "run code and
  read files on this box" for anyone who reaches the port. If you set up Caddy through
  `80-lan-access.sh`, either drop the MCP flag or keep the LLM loopback-only and proxy
  ComfyUI alone.

Override the defaults with `env` entries in `mcp.json`: `COMFY_URL`, `COMFY_PUBLIC_URL`,
`COMFY_WORKFLOW` (any API-format graph), `COMFY_CHECKPOINT`, `COMFY_PREFIX`, `COMFY_TIMEOUT`
(default 900 s — but the `timeout_ms` above is what actually stops the call).

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
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2"
```

`--ctx-size` here is the **total** the router passes to each model it loads, so `--parallel 2`
gives each request 64k. Every loaded model reserves its own KV cache for it; that is why the
value is one number here and per-model in `models.ini` below. `MODELS_MAX=1` is deliberate. On ~48 GiB of shared GTT two 24 GB models do not fit, and the
router's default of 4 would try. The two units `Conflicts=` each other, so enabling one stops
the other; enable only one at a time.

Then open `http://127.0.0.1:8080` → **Models**. Every GGUF the router can see is listed with
its load state, and that panel loads, unloads and downloads models — including from Hugging
Face by `user/repo:QUANT`. The same, over the API:

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
`Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf`. Any client has to carry it in the `model` field.
Open WebUI discovers it from `/v1/models`, so after switching to router mode just refresh the
connection's model list in **Admin → Settings → Connections** and pick the `.gguf` entry.
Command-line clients (editors, scripts) need the same id instead of `local`.

Friendly names come from a preset file. This also gives per-model arguments, which matters as
soon as two models want different context sizes:

```bash
llama-server --models-preset ~/.config/ai-box/models.ini
```

```ini
version = 1

[*]
ctx-size = 131072
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
  Flux job, unload it: `POST /models/unload`, or run ComfyUI's
  `POST /free {"unload_models": true}` only — that one frees ComfyUI's models, not the LLM's.
- **First request is slow.** A 24 GB model has to come off NVMe; the UI shows `loading` and
  the chat request waits. That is not a dead connection. `--no-models-autoload` plus an
  explicit `load` is the alternative if you would rather preload.

## If you want another web app

You already have one: **Open WebUI**, the front door ([12](12-deployment-and-client.md)) —
accounts, per-user history, ComfyUI images, and the same `http://127.0.0.1:8080/v1` behind it.

Adding a second front end is possible (any OpenAI-compatible client works) but nothing about
the model, ports or memory changes, and two front ends mean two places to manage accounts.
The only one worth considering is **LibreChat** if you specifically want its agent builder; it
is a six-service stack (MongoDB, Meilisearch, a RAG service) for five users, so it is a
project, not a setting.

What none of them fix: a 30B model on a 256 GB/s memory bus. A prettier UI does not change
tok/s, and RAG over your notes still competes for the same 48 GiB.
