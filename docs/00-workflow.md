# 00 — The whole build, one page

Every script in this repo, in the order they run, with the command that proves each one
worked. Prose, background and the "why" live in [01](01-hardware-and-bios.md) through
[12](12-deployment-and-client.md); this page is the path only.

Assumes the box is `ai-box`, the user `ai-user`, the repo cloned to `~/ai-box`, and
`~/ai/models` for GGUFs. `sudo` is needed by exactly three scripts: `10`, `50`, `81`.

| # | Step | Command | Proof it worked |
|---|---|---|---|
| 0 | BIOS | — | 512 MB iGPU carve-out, USB first in boot order |
| 1 | OS | `windows-seed-usb.ps1` then boot | `ssh ai-user@192.168.150.40` |
| 2 | GPU memory | `sudo ./scripts/10-gpu-memory.sh 48` | `./scripts/00-preflight.sh` |
| 3 | llama.cpp | `./scripts/20-install-llama.sh rocm` | `llama-server --version` |
| 4 | Models | `hf download …` | `ls -lh ~/ai/models/*.gguf` |
| 5 | Services | `sudo ./scripts/50-install-services.sh` | `curl -s localhost:8080/health` |
| 6 | ComfyUI | `./scripts/30-install-comfyui.sh` | `./scripts/97-comfy-gen.sh "test"` |
| 7 | Open WebUI | `./scripts/45-install-openwebui.sh` | `curl -s -o /dev/null -w '%{http_code}' localhost:3000` |
| 8 | Front door | `sudo ./scripts/81-front-door.sh` | `https://ai.pilchlab.ca` from Windows |
| 9 | Accounts + images | admin UI | one account per person, SDXL draws |
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
powershell -ExecutionPolicy Bypass -File .\scripts\windows-seed-usb.ps1 -Root F:\
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

It writes `llama-server.env`, `llama-router.env`, `comfyui.env` and `openwebui.env` **only if
they do not exist**, so re-running it after later phases is safe. It enables llama-server (set
to the first GGUF over 1 GB it finds, by name — check `MODEL=` in the env file) and ComfyUI, and
skips Open WebUI until step 7 has built it.

Headless box: open one tunnel and leave it running for the rest of the build —

```bash
ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai-user@ai-box
```

`http://127.0.0.1:8080` is llama.cpp's own chat UI (admin/debug only now), and
`http://127.0.0.1:8080/v1` is the OpenAI-compatible endpoint for Claude Code / opencode /
Continue / Cline / Aider ([04](04-llm-stack.md)).

**Keep `--tools` off.** With Open WebUI generating images itself, llama-server has no reason to
expose shell execution over HTTP. If you add it for a one-off, remember that it turns "use the
model" into "run commands as `ai-user`" for anyone who reaches the port
([10](10-webui-and-models.md#server-tools-files-shell-and-the-internet)).

## 5. ComfyUI (1–2 h, mostly downloads)

```bash
./scripts/30-install-comfyui.sh
./scripts/96-comfy-models.sh download stabilityai/stable-diffusion-xl-base-1.0 \
  'sd_xl_base_1.0.safetensors' checkpoints
sudo ./scripts/50-install-services.sh     # existing env files are left alone
./scripts/97-comfy-gen.sh "a corgi astronaut, cinematic lighting"
```

The PNG path it prints is the CLI path: useful for testing ComfyUI without the web UI. The
front door draws through ComfyUI directly (§7). Model layout and the FP8 trap:
[05](05-image-generation.md).

## 6. Open WebUI (15 min, mostly pip)

```bash
./scripts/45-install-openwebui.sh         # uv + pinned Python 3.12 + venv. No sudo.
sudo ./scripts/50-install-services.sh     # openwebui.env + unit; prints the admin login
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/    # 200
```

Why native and not the container: this box has no Docker, and the install is a venv plus one
unit. `DATA_DIR` is `~/ai/data/openwebui`, so chats and users are outside the venv and survive
an upgrade.

## 7. Front door — Caddy on the Proxmox VM (20 min)

```bash
sudo ./scripts/81-front-door.sh --caddy-ip 192.168.150.13 --hostname ai.pilchlab.ca
```

It enforces `HOST=127.0.0.1` on llama-server and ComfyUI, opens `:3000` to the Caddy VM only, and
only then moves Open WebUI to `HOST=0.0.0.0` (the proxy is on another machine). With ufw missing,
inactive or default-allow it **refuses**: the bind stays on loopback and the script exits non-zero
with the four commands that fix it. It also sets `WEBUI_URL` and writes
`~/.config/ai-box/caddy-ai-box.caddy`. On the VM:

```bash
scp ai-user@192.168.150.40:~/.config/ai-box/caddy-ai-box.caddy /tmp/
sudo mv /tmp/caddy-ai-box.caddy /etc/caddy/caddy-ai-box.caddy
# add one line to /etc/caddy/Caddyfile:   import /etc/caddy/caddy-ai-box.caddy
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

Trust the site's certificate on each Windows PC (Caddy's local CA, because the VM is on a
private address):

```bash
sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt > root.crt   # on the VM
certutil -addstore -f Root root.crt                                                    # Windows, as admin
```

Then, on the box:

```bash
ss -ltnp | grep -E ':(3000|8080|8188)\b'   # 8080/8188 on 127.0.0.1; 3000 on 0.0.0.0
ufw status verbose                         # Status: active; Default: deny (incoming)
```

## 8. First sign-in: accounts and images (15 min)

1. `https://ai.pilchlab.ca` → sign in with the admin email and password printed by
   `50-install-services.sh` (the account is created at startup, sign-ups stay off).
2. **Admin → Settings → Users**: create one account per person (up to five).
3. **Settings → Images** is already set to ComfyUI, the SDXL graph and
   `sd_xl_base_1.0.safetensors`; the checkpoint must exist on disk. Node map:
   [12](12-deployment-and-client.md#sdxl-the-default).
4. **Settings → Connections**: OpenAI-compatible, `http://127.0.0.1:8080/v1`, any placeholder
   key (llama-server does not check one on loopback).
5. Optional: import `workflows/openwebui-flux-schnell.api.json` when you want Flux instead;
   set Steps to 4 with it.

Prove it: ask a question (the reply streams), then use the **Image** toggle in the message bar
and confirm the picture appears inline and in the *Images* sidebar.

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
once. Model names are the `.gguf` file names, and Open WebUI's connection keeps working because
the port and the `/v1` path are the same.
[10](10-webui-and-models.md#model-management-router-mode).

## Checklist

- [ ] BIOS: 512 MB iGPU carve-out, USB first
- [ ] Install completes and powers off; SSH answers on the address in the answer file
- [ ] `00-preflight.sh` shows ~48 GiB GTT, `/dev/kfd`, render group
- [ ] `20-install-llama.sh rocm` finished without a CMake error
- [ ] `curl localhost:8080/health` is `ok`, `/props` n_ctx is 65536
- [ ] Your editor's model list shows `local` at `http://127.0.0.1:8080/v1`
- [ ] `97-comfy-gen.sh "test"` writes a PNG
- [ ] `http://127.0.0.1:3000/` answers 200 and `open-webui` is active
- [ ] `https://ai.pilchlab.ca` loads from Windows with no certificate warning
- [ ] First account is admin; sign-ups are off; everyone else has an account
- [ ] Chat streams in Open WebUI; the Image toggle returns a picture inline
- [ ] `ufw status verbose` is active with default deny; `ss -ltnp` shows 8080/8188 on 127.0.0.1
      and 3000 on 0.0.0.0
- [ ] `90-bench.sh` numbers recorded in `bench/`

## When a step fails

`00-preflight.sh` first, then [09](09-troubleshooting.md) — symptom → cause → fix, including
`HIP error: invalid device function` (wrong torch wheel index), a `netplan` crash during install,
model load failures from `--ctx-size`, ComfyUI holding GTT the LLM needs
(`96-comfy-models.sh free`), a 502 from Caddy, and the certificate warning that means the root
CA was never trusted.
