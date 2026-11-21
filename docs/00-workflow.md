# 00 — The whole build, one page

Every script in this repo, in the order they run, with the command that proves each one
worked. Prose, background and the "why" live in [01](01-hardware-and-bios.md) through
[10](10-webui-and-models.md); this page is the path only.

Assumes the box is `ai-box`, the user `ai-user`, the repo cloned to `~/ai-box`, and
`~/ai/models` for GGUFs. `sudo` is needed by exactly three scripts: `10`, `50`, `80`.

| # | Step | Command | Proof it worked |
|---|---|---|---|
| 0 | BIOS | — | 512 MB iGPU carve-out, USB first in boot order |
| 1 | OS | `windows-seed-usb.ps1` then boot | `ssh ai-user@192.168.150.40` |
| 2 | GPU memory | `sudo ./scripts/10-gpu-memory.sh 48` | `./scripts/00-preflight.sh` |
| 3 | llama.cpp | `./scripts/20-install-llama.sh rocm` | `llama-server --version` |
| 4 | Models | `hf download …` | `ls -lh ~/ai/models/*.gguf` |
| 5 | Services | `sudo ./scripts/50-install-services.sh` | `curl -s localhost:8080/health` |
| 6 | ComfyUI | `./scripts/30-install-comfyui.sh` | `./scripts/97-comfy-gen.sh "test"` |
| 7 | Bot | `./scripts/40-install-bot.sh` | `/chat` in Discord |
| 8 | MCP | `mcp.json` + one flag | `curl -s localhost:8080/tools` |
| 9 | LAN | `sudo ./scripts/80-lan-access.sh` | a browser through Caddy |
| 10 | Bench | `./scripts/90-bench.sh` | `bench/YYYY-MM-DD.md` |

---

## 0. BIOS (30 min)

`F2` at boot: `Advanced` → `iGPU Memory Configuration` → `Custom` → **512 MB**. Change nothing
else. USB first in boot order. Details: [01](01-hardware-and-bios.md).

## 1. OS (45 min, then unattended)

Unattended, one stick, from Windows — the answer file already sets hostname, user, SSH keys,
the toolchain, `ttm.pages_limit` for 48 GiB and the `render,video` groups:

```powershell
# Windows, from the repo, with the live-server ISO written to the stick in Rufus ISO mode
powershell -ExecutionPolicy Bypass -File .\scripts\windows-seed-usb.ps1 -Root F:
```

Boot the stick. It installs and powers off; pull the stick and turn it on. It comes up on the
address in `autoinstall.yaml` (DHCP unless you swapped in the static block).

```bash
ssh ai-user@ai-box.local          # or the static address
uname -r                          # want >= 6.18.4 ; 7.x on 26.04
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update
git clone https://github.com/KpiclHU/ai-box ~/ai-box
```

Manual install instead: [02](02-os-install.md). Static address: [02](02-os-install.md#static-address-instead-of-dhcp).

## 2. GPU memory (20 min)

**Skip this if you installed from `autoinstall/user-data`** — its `late-commands` already wrote
the same GRUB arguments (that is what `12582912` pages is). Verify instead:

```bash
./scripts/00-preflight.sh          # expect ~48 GiB GTT, /dev/kfd, render group, vulkaninfo
```

Doing it by hand on any other install:

```bash
sudo ./scripts/10-gpu-memory.sh 48
sudo reboot
./scripts/00-preflight.sh
```

`00-preflight.sh` is read-only; run it after every phase from here on. Background:
[03](03-gpu-memory.md).

## 3. llama.cpp (1–2 h, mostly compile)

```bash
./scripts/20-install-llama.sh rocm       # HIP: best prompt processing. `vulkan` or `both` also work
pipx install huggingface_hub             # once; `hf` is not installed by any script
hf download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF --include '*Q6_K*' --local-dir ~/ai/models
```

## 4. Services — llama-server (5 min)

```bash
sudo ./scripts/50-install-services.sh     # renders units + env files into ~/.config/ai-box
curl -s localhost:8080/health             # {"status":"ok"} once the model has loaded
curl -s localhost:8080/props | jq '.default_generation_settings.n_ctx'   # 65536 (131072 / 2 slots)
```

It writes `llama-server.env`, `llama-router.env` and `comfyui.env` **only if they do not exist**,
so re-running it after later phases is safe. It enables llama-server (set to the first GGUF
over 1 GB it finds, by name — check `MODEL=` in the env file), ComfyUI, and skips the bot until
`.env` has a real token.

Headless box: open one tunnel and leave it running for the rest of the build —

```bash
ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai-user@ai-box
```

`http://127.0.0.1:8080` is now a chat UI, and `http://127.0.0.1:8080/v1` is the
OpenAI-compatible endpoint for Claude Code / opencode / Continue / Cline / Aider
([04](04-llm-stack.md)).

## 5. ComfyUI (1–2 h, mostly downloads)

```bash
./scripts/30-install-comfyui.sh
./scripts/96-comfy-models.sh download stabilityai/stable-diffusion-xl-base-1.0 \
  'sd_xl_base_1.0.safetensors' checkpoints
sudo ./scripts/50-install-services.sh     # existing env files are left alone
./scripts/97-comfy-gen.sh "a corgi astronaut, cinematic lighting"
```

The PNG path it prints is the whole API: `97-comfy-gen.sh` is how the terminal, the bot and
(the slow path) the model all generate images. Model layout and the FP8 trap:
[05](05-image-generation.md).

## 6. Discord bot (30 min)

1. <https://discord.com/developers/applications> → **Bot** → copy token; invite with `bot` +
   `applications.commands`.
2. ```bash
   ./scripts/40-install-bot.sh        # venv + deps, creates .env from bot/.env.example
   $EDITOR .env                       # DISCORD_TOKEN, DISCORD_GUILD_ID, COMFY_CHECKPOINT
   sudo ./scripts/50-install-services.sh
   journalctl -u ai-discord-bot -f
   ```
3. In Discord: `/chat`, `/image`, `/reset`, `/status`.

Behaviour, history and limits: [06](06-discord-bot.md).

## 7. MCP — let the chat model draw (10 min)

Three edits and one flag. `scripts/comfy-mcp.py` is stdlib-only, so it starts in milliseconds
and costs nothing to have configured.

```bash
chmod +x ~/ai-box/scripts/comfy-mcp.py
mkdir -p ~/.config/ai-box
cp ~/ai-box/mcp.example.json ~/.config/ai-box/mcp.json
```

Edit `~/.config/ai-box/mcp.json`. Absolute paths only — systemd's `PATH` is `/usr/bin:/bin`, so
a bare `npx`/`uvx` will not start. Keep `comfyui` and drop the other two unless you want them
(`filesystem` needs nodejs/npm, `git` needs `uv`):

```json
{
  "mcpServers": {
    "comfyui": {
      "command": "/usr/bin/python3",
      "args": ["/home/ai-user/ai-box/scripts/comfy-mcp.py"],
      "env": { "COMFY_URL": "http://127.0.0.1:8188" }
    }
  }
}
```

Then add the flag to **the env file of the unit that actually owns port 8080**. `llama-router.env`
is the one that matters in router mode; `llama-server.env` is ignored while the router runs. It
must be a single line — the unit splits it on whitespace, so no backslashes:

```
# ~/.config/ai-box/llama-router.env
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --mcp-servers-config /home/ai-user/.config/ai-box/mcp.json"
```

```bash
sudo systemctl restart llama-router        # or llama-server, whichever you run
curl -s localhost:8080/tools | jq          # comfyui_generate_image, _list_models, _status, _free_memory
journalctl -u llama-router -n 40 --no-pager | grep -i mcp
```

`/tools` is empty until a model is loaded — in router mode the children start with the model,
so send a chat message first. Then ask it plainly: *"draw a corgi astronaut"*. The tool returns
the file path plus a `/view` URL on port 8188, which renders through the tunnel above.

Two things to keep in mind: **`HOST=127.0.0.1`** (tools on a LAN address is remote code
execution by design), and **prompt cost** — every tool schema is tokens on every request, so
three servers is pleasant and fifteen is not. Details: [10](10-webui-and-models.md#connectors-mcp-tools).

## 8. LAN through Caddy (optional, last)

The box itself runs no proxy. The script binds the UIs to the LAN, firewalls everything except
the Caddy host, and writes the site block to import there:

```bash
sudo ./scripts/80-lan-access.sh --proxy 192.168.150.5
# then, on the Caddy box:  import /etc/caddy/caddy-ai-box.caddy
```

**Decide one thing first:** if you enable MCP tools, keep the LLM loopback-only and proxy
ComfyUI alone — or drop the `--mcp-servers-config` flag. Authentication happens on the Caddy
box, not here. [10](10-webui-and-models.md#access-from-the-lan).

## 9. Measure (10 min)

```bash
sudo systemctl stop llama-server          # it already holds the model in GTT
./scripts/90-bench.sh                     # both builds if you installed `both`
```

Results append to `bench/YYYY-MM-DD.md`. Then `sudo systemctl start llama-server`.

---

## Router mode — several GGUFs, one port

The default is one model, one port. To serve everything in `~/ai/models` and switch in the UI:

```bash
sudo systemctl disable --now llama-server
sudo systemctl enable --now llama-router
curl -s localhost:8080/models | jq
```

`MODELS_MAX=1` in `llama-router.env` is correct for 48 GiB — two 24 GB models do not fit at
once. Model names are the `.gguf` file names. [10](10-webui-and-models.md#model-management-router-mode).

## Checklist

- [ ] BIOS: 512 MB iGPU carve-out, USB first
- [ ] Install completes and powers off; SSH answers on the address in the answer file
- [ ] `00-preflight.sh` shows ~48 GiB GTT, `/dev/kfd`, render group
- [ ] `20-install-llama.sh rocm` finished without a CMake error
- [ ] `curl localhost:8080/health` is `ok`, `/props` n_ctx is 65536
- [ ] Your editor's model list shows `local` at `http://127.0.0.1:8080/v1`
- [ ] `97-comfy-gen.sh "test"` writes a PNG
- [ ] Bot is online, `/chat` streams, `/image` returns a file
- [ ] `curl localhost:8080/tools` lists `comfyui_generate_image`
- [ ] `80-lan-access.sh` only if you want off-box access, and only with loopback LLM
- [ ] `90-bench.sh` numbers recorded in `bench/`

## When a step fails

`00-preflight.sh` first, then [09](09-troubleshooting.md) — symptom → cause → fix, including
`HIP error: invalid device function` (wrong torch wheel index), a `netplan` crash during install,
model load failures from `--ctx-size`, and ComfyUI holding GTT the LLM needs
(`96-comfy-models.sh free`).
