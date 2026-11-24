# 00 — The whole build, one page

Every script in this repo, in the order they run, with the command that proves each one
worked. Prose, background and the "why" live in [01](01-hardware-and-bios.md) through
[09](09-troubleshooting.md); this page is the path only.

Assumes the box is `ai-box`, the user `ai-user`, the repo cloned to `~/ai-box`, and
`~/ai/models` for GGUFs. `sudo` is needed by exactly three scripts: `10`, `50`, `80`.

| # | Step | Command | Proof it worked |
|---|---|---|---|
| 0 | BIOS | — | 512 MB iGPU carve-out, USB first in boot order |
| 1 | OS | the `ai-box-autoinstall` USB | `ssh ai-user@192.168.150.40` |
| 2 | GPU memory | `sudo ./scripts/10-gpu-memory.sh 48` | `./scripts/00-preflight.sh` |
| 3 | llama.cpp | `./scripts/20-install-llama.sh rocm` | `llama-server --version` |
| 4 | Models | `hf download …` | `ls -lh ~/ai/models/*.gguf` |
| 5 | Services | `sudo ./scripts/50-install-services.sh` | `curl -s localhost:8080/health` |
| 6 | ComfyUI | `./scripts/30-install-comfyui.sh` | `./scripts/97-comfy-gen.sh "test"` |
| 7 | LAN access | `sudo ./scripts/80-lan-access.sh --lan 192.168.150.0/24` | `curl` from another machine |
| 8 | Bench | `./scripts/90-bench.sh` | `bench/YYYY-MM-DD.md` |

---

## 0. BIOS (30 min)

`F2` at boot: `Advanced` → `iGPU Memory Configuration` → `Custom` → **512 MB**. Change nothing
else. USB first in boot order. Details: [01](01-hardware-and-bios.md).

## 1. OS (45 min, then unattended)

Unattended, from the separate **`ai-box-autoinstall`** repository: it has the answer file
(hostname, user, SSH keys, toolchain, the 48 GiB `ttm.pages_limit`, `render,video` groups), the
`CIDATA` seed, and `seed-usb.ps1` for a single ISO-mode stick. Fill in the password hash and
your public key, run the helper, boot the stick, walk away.

It installs and powers off; pull the stick and turn it on. Then:

```bash
ssh ai-user@ai-box.local          # or the static address
uname -r                          # want >= 6.18.4 ; 7.x on 26.04
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update
git clone https://github.com/KpiclHU/ai-box ~/ai-box
```

Manual install instead: [02](02-os-install.md). Static address: [02](02-os-install.md#unattended-install).

## 2. GPU memory (20 min)

**Skip this if you installed from the answer file** — its `late-commands` already wrote the
same GRUB arguments (that is what `12582912` pages is). Verify instead:

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

It writes `llama-server.env`, `llama-router.env` and `comfyui.env` **only if they do not
exist**, so re-running it after later phases is safe. It enables llama-server (set to the first
GGUF over 1 GB it finds, by name — check `MODEL=` in the env file) and skips ComfyUI until
step 6 has built it.

Headless box: open one tunnel and leave it running for the rest of the build —

```bash
ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai-user@ai-box
```

`http://127.0.0.1:8080` is llama.cpp's own chat UI (admin/debug only), and
`http://127.0.0.1:8080/v1` is the OpenAI-compatible endpoint for Claude Code / opencode /
Continue / Cline / Aider ([04](04-llm-stack.md)).

**Keep `--tools` off.** Once the port is open to the subnet, `--tools` turns "use the model"
into "run commands as `ai-user`" for everyone on it. The image workflow does not need it —
ComfyUI is called directly.

## 5. ComfyUI (1–2 h, mostly downloads)

```bash
./scripts/30-install-comfyui.sh
./scripts/96-comfy-models.sh download stabilityai/stable-diffusion-xl-base-1.0 \
  'sd_xl_base_1.0.safetensors' checkpoints
sudo ./scripts/50-install-services.sh     # existing env files are left alone
./scripts/97-comfy-gen.sh "a corgi astronaut, cinematic lighting"
```

The PNG path it prints is the CLI path: proof that ComfyUI answers without any UI involved.
Model layout and the FP8 trap: [05](05-image-generation.md).

## 6. LAN access (5 min)

```bash
sudo ./scripts/80-lan-access.sh --lan 192.168.150.0/24
```

Firewall first, bind second: it adds `ufw allow from 192.168.150.0/24 to any port 8080` and
`8188`, then moves `HOST` to `0.0.0.0` and restarts only what changed. With ufw missing,
inactive or default-allow it **refuses** — the bind stays on loopback, the script exits non-zero
and it prints the four commands that fix it. Nothing is ever opened as a warning.

Then from another machine on that subnet:

```bash
curl -s http://192.168.150.40:8080/health
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.150.40:8188/system_stats
```

And on the box:

```bash
ss -ltnp | grep -E ':(8080|8188)\b'         # 0.0.0.0 on both
ufw status verbose                          # active, Default: deny (incoming)
sudo ufw status | grep -E '(8080|8188)/tcp' # both rules name 192.168.150.0/24
```

Both services are now raw HTTP APIs with no login. That is the design: the subnet is the
boundary. Do not port-forward either port. Undo: `sudo ./scripts/80-lan-access.sh --revert`.

## 7. Measure (10 min)

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
once. Model names are the `.gguf` file names. Clients keep working because the port and the
`/v1` path are the same.

## Checklist

- [ ] BIOS: 512 MB iGPU carve-out, USB first
- [ ] Install completes and powers off; SSH answers on the address in the answer file
- [ ] `00-preflight.sh` shows ~48 GiB GTT, `/dev/kfd`, render group
- [ ] `20-install-llama.sh rocm` finished without a CMake error
- [ ] `curl localhost:8080/health` is `ok`, `/props` n_ctx is 65536
- [ ] Your editor's model list shows `local` at `http://127.0.0.1:8080/v1`
- [ ] `97-comfy-gen.sh "test"` writes a PNG
- [ ] `80-lan-access.sh` published both ports and `ufw status verbose` names the subnet
- [ ] `curl` from another machine on `192.168.150.0/24` answers 200
- [ ] `curl` from a device on a different network does **not**
- [ ] `90-bench.sh` numbers recorded in `bench/`

## When a step fails

`00-preflight.sh` first, then [09](09-troubleshooting.md) — symptom → cause → fix, including
`HIP error: invalid device function` (wrong torch wheel index), a `netplan` crash during install,
model load failures from `--ctx-size`, ComfyUI holding GTT the LLM needs
(`96-comfy-models.sh free`), and a port that answers locally but not from the LAN.
