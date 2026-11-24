# ai-box — llama.cpp and ComfyUI on a 64 GB Strix Halo box

An install plan and working automation for turning a Framework Desktop (Ryzen AI Max+ 395,
64 GB) + a 2 TB NVMe SSD into a local model server:

- **llama.cpp** — one OpenAI-compatible endpoint on `:8080`, for Claude Code / opencode /
  Continue / Cline / Aider and anything else that speaks `/v1`.
- **ComfyUI** — SDXL and Flux on the same iGPU, driven headlessly over HTTP on `:8188`.

Both are published **to the LAN only**: `192.168.150.0/24`, enforced by ufw, after which they
are plain HTTP APIs with no accounts of their own. Nothing here faces the internet.

Everything is designed for **one 64 GB machine with no discrete GPU**. That constraint drives
almost every decision below.

Two pieces deliberately live elsewhere:

| Repository | What it does |
|---|---|
| `ai-box-autoinstall` | the unattended Ubuntu answer file and the Windows USB helper |
| `ai-box-docker` | a Docker VM on Proxmox with Open WebUI, Open Terminal and OpenClaw, each on its own LAN address |

---

## 1. What you have, and what that means

| Part | Detail | Consequence for this plan |
|---|---|---|
| Framework Desktop, Ryzen AI Max+ 395 | 16C/32T Zen 5, 120 W sustained / 140 W boost | Set the OS platform profile to `performance` for inference |
| Radeon 8060S iGPU | 40 RDNA 3.5 CUs, ROCm target **`gfx1151`** | Needs a recent kernel + ROCm; do **not** use `HSA_OVERRIDE_GFX_VERSION` |
| 64 GB LPDDR5X-8000 | 256-bit, 256 GB/s, **soldered** | Not upgradeable. Plan models around ~48 GB usable for GPU work |
| KingSpec 2 TB M.2 2280 NVMe Gen4x4 | Single drive | Both M.2 sockets are **PCIe 4.0 x4** — the Gen4x4 drive is a perfect match |
| 2× M.2 2280 sockets | SSD1 = `0000:00:03.1` (main), SSD2 = `0000:00:02.5` (rear) | Put the OS drive in the **main** socket; the rear socket is your expansion slot later |
| 400 W FlexATX PSU | 80+ Gold | Fine; the APU takes millisecond power spikes |

> **Correcting a common assumption:** the Ryzen AI Max+ 395 has no PCIe 5.0. The drive will
> run at Gen4 x4 (~7 GB/s) and that is its ceiling here. Nothing is being wasted.

**The one number that matters:** with a 64 GB machine you have roughly **48 GB of
GPU-addressable memory** to work with if you leave ~12–14 GB for the OS, desktop and file
cache. That fits:

- 30B-class Mixture-of-Experts coding models at Q6_K comfortably
- 70B dense models at Q4 only if you give up desktop headroom
- Flux.1 dev fp16 (~34 GB peak) or Flux GGUF much more comfortably
- SDXL with lots of room left over

It does **not** fit `gpt-oss-120b` (~59 GB of weights). Don't plan around it.

---

## 2. Decisions

| Question | Choice | Why |
|---|---|---|
| OS | **Ubuntu 26.04 LTS Server** (Desktop is fine too) | On AMD's ROCm compatibility matrix, kernel 7.0 (well past the 6.18.4 Strix Halo fix line), LTS support. Fedora 43 and Bazzite are the alternatives (see [docs/02](docs/02-os-install.md)) |
| iGPU memory | **512 MB BIOS carve-out + `ttm.pages_limit` ≈ 48 GiB** | AMD's own guidance: a static carve-out buys nothing on Strix Halo and permanently removes RAM from the OS. Large carve-outs also break USB ports after suspend on this board |
| LLM runtime | **llama.cpp `llama-server` (HIP/ROCm build)** | Best prompt-processing speed for agentic coding; one toolchain shared with ComfyUI. Vulkan build documented as the alternative for higher decode tok/s |
| Image stack | **ComfyUI in a venv**, PyTorch ROCm wheels | Most reliable path on `gfx1151`; scriptable over HTTP for any client |
| Orchestration | systemd units, no Docker on this box | Starts on boot, restarts on failure. The containers live on another VM, where they belong |
| Published surface | **ufw rule for `192.168.150.0/24`**, then `HOST=0.0.0.0` | One subnet, two ports, no proxy to keep running. The script refuses to bind before the rule exists |

Explicitly **not** used: Ollama/LM Studio as the primary runtime (fine for experiments, less
control over flags), FP8 model weights (no FP8 matmul on RDNA 3.5), Docker Desktop (cannot
see `/dev/kfd`), and large BIOS VRAM carve-outs.

---

## 3. The plan

Time estimates assume you have the parts in hand and a monitor + keyboard. If you only want the
commands in order — including the MCP setup — that is
[docs/00-workflow.md](docs/00-workflow.md).

### Phase 0 — Hardware and BIOS (30 min)

1. Open the case, fit the KingSpec into the **main** M.2 socket (the one nearest the
   front/`00:03.1`), remove the plastic on the thermal pad, screw the heat spreader down.
   It is 2280 only; do not force a 2242.
2. Optional but recommended for SSD temperatures: add an 80 mm fan in the front position.
   SSD temps above 100 °C are a known quirk on this chassis because the EC does not monitor
   them.
3. Boot, tap **F2** for BIOS, then:
   - Update the BIOS first if it is older than 3.06 (`fwupdmgr` after install also works).
   - `Advanced` → **`iGPU Memory Configuration`** → `Custom` → **`iGPU Memory Size` = 512 MB**.
   - Leave Above-4G / Re-Size BAR at defaults; this board's labels vary, and nothing in the
     plan depends on changing them.
4. Full details and the exact menu names: [docs/01-hardware-and-bios.md](docs/01-hardware-and-bios.md)

### Phase 1 — OS install (45 min)

Ubuntu 26.04 LTS, single ext4 root on the whole 2 TB, no big swap partition. **The Server
edition is the better fit here**: both services are HTTP, nothing needs X or Wayland, and you
get ~1–2 GB more RAM for models.

```bash
uname -r                      # want >= 6.18.4 ; 7.x on 26.04
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update
lspci -nn | grep -i vga       # Radeon 8060S, device id 1002:...
```

Step-by-step, including the ISO/USB, partitioning and first-boot checks:
[docs/02-os-install.md](docs/02-os-install.md)

**Install it unattended if you like.** The answer file, the `CIDATA` seed and a Windows helper
live in their own repository, `ai-box-autoinstall`: hostname, user, SSH keys, whole-disk ext4,
the toolchain and the GPU memory arguments already set, no keystrokes at boot. Its README is
the recipe; come back here once the box answers on SSH.

### Phase 2 — Give the GPU the memory (20 min)

```bash
sudo ./scripts/10-gpu-memory.sh 48      # GiB of GPU-addressable memory, writes GRUB args
sudo reboot
./scripts/00-preflight.sh               # verifies GTT/VRAM, ROCm, Vulkan, tools
```

This sets `ttm.pages_limit` / `ttm.page_pool_size` and leaves the BIOS carve-out where it
belongs. **Skip it if you used the autoinstall answer file** — it writes the same arguments —
and just verify. Background and the arithmetic: [docs/03-gpu-memory.md](docs/03-gpu-memory.md)

### Phase 3 — LLM (1–2 h, mostly compile time)

```bash
./scripts/20-install-llama.sh rocm               # or: vulkan (no sudo: it builds in your home)
hf download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
  --include '*Q6_K*' --local-dir ~/ai/models     # Qwen3-Coder-30B-A3B, ~25 GB
sudo ./scripts/50-install-services.sh            # llama-server on 127.0.0.1:8080
curl -s localhost:8080/health
```

Point a client at `http://127.0.0.1:8080/v1` on the box, or at
`http://192.168.150.40:8080/v1` once Phase 5 has run. Instructions for Claude Code, opencode,
Continue, Cline and Aider: [docs/04-llm-stack.md](docs/04-llm-stack.md). Model picks and
sizes: [docs/07-models.md](docs/07-models.md).

### Phase 4 — Image generation (1–2 h, mostly downloads)

```bash
./scripts/30-install-comfyui.sh                       # again, no sudo — the venv lives in your home
./scripts/96-comfy-models.sh download stabilityai/stable-diffusion-xl-base-1.0 \
  'sd_xl_base_1.0.safetensors' checkpoints            # 7 GB checkpoint
./scripts/96-comfy-models.sh                          # what is on disk, by folder, with sizes
sudo ./scripts/50-install-services.sh                 # ComfyUI on 127.0.0.1:8188
./scripts/97-comfy-gen.sh "a corgi astronaut"         # one image, no UI needed
```

Expect **~15–25 s per 1024² SDXL image**, ~15–30 s for Flux.1-schnell, 70–120 s for
Flux.1-dev. First generation is slow (kernel/MIOpen compilation) — wait it out, do not kill
it. Details, model layout and the FP8 trap: [docs/05-image-generation.md](docs/05-image-generation.md)

### Phase 5 — Publish to the LAN (5 min)

```bash
sudo ./scripts/80-lan-access.sh --lan 192.168.150.0/24
```

It adds `ufw allow from 192.168.150.0/24 to any port 8080` and `... 8188`, and **only then**
moves both services to `HOST=0.0.0.0`. With ufw missing, inactive or default-allow it refuses:
the bind stays on loopback and the script exits non-zero with the commands that fix it. A
wildcard bind with nothing in front of it is reachable by every device on the network, so the
order matters and the script does not trust a warning to be read.

After it:

```bash
curl -s http://192.168.150.40:8080/health
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.150.40:8188/system_stats
```

Both have **no login of their own** — the subnet is the boundary. Do not port-forward `8080`
or `8188` on the router, and keep guests on a different subnet. Undo with
`sudo ./scripts/80-lan-access.sh --revert`.

### Phase 6 — Operations (ongoing)

[docs/08-operations.md](docs/08-operations.md) covers systemd control, logs, updating ROCm and
ComfyUI, backup, and the memory-budget rules for running the LLM and image generation at the
same time. When something breaks: [docs/09-troubleshooting.md](docs/09-troubleshooting.md).

---

## 4. Expected performance (planning numbers, not promises)

Measured figures from comparable `gfx1151` systems; the 128 GB numbers are the better
documented ones, so treat 64 GB results as "same or slightly lower".

| Workload | Throughput | Notes |
|---|---|---|
| Qwen3-Coder-30B-A3B Q6_K | ~61–75 tok/s decode, ~1.1–1.25k tok/s prefill | HIP wins prefill, Vulkan wins decode on the same build |
| Qwen3-30B-A3B Q4_K_M | ~66–86 tok/s decode | The everyday chat model |
| Qwen3.8-27B Q6_K (dense hybrid) | ~8–9 tok/s plain, **~19 with MTP** | Its `nextn` draft head is off by default; one flag, ~2× — [docs/04](docs/04-llm-stack.md#speculative-decoding-the-one-flag-that-doubles-a-dense-model) |
| Llama-3.1-70B Q4_K_M | ~5 tok/s decode | Fits, but slow and leaves little room |
| gpt-oss-120b MXFP4 | ~51–55 tok/s | **Not viable on 64 GB** — listed to show what you are not missing |
| SDXL 1024², 25 steps | ~15–25 s/image | ~10 GB |
| Flux.1-schnell, 4 steps | ~15–30 s | GGUF Q8 recommended |
| Flux.1-dev fp16, 20 steps | ~70–120 s | ~34 GB peak with the fp16 T5 encoder |

Measure your own box rather than trusting a table: `./scripts/90-bench.sh` — stop
`llama-server` first, it already holds the model in GPU memory.

---

## 5. Repo layout

```
README.md                     this plan
docs/                         the deep-dive pages, in reading order
  00-workflow.md              the whole build on one page: every script, in order
  01-hardware-and-bios.md     sockets, BIOS, firmware, fans
  02-os-install.md            Ubuntu install, partitioning, first boot
  03-gpu-memory.md            carve-out vs GTT/TTM, the 64 GB budget
  04-llm-stack.md             llama.cpp build, server flags, coding-tool wiring
  05-image-generation.md      ComfyUI, ROCm wheels, models, FP8 trap
  07-models.md                what fits in 64 GB, with sizes
  08-operations.md            services, updates, backups, coexistence
  09-troubleshooting.md       symptom → cause → fix
scripts/
  00-preflight.sh             read-only health/report
  10-gpu-memory.sh            sets ttm.pages_limit via GRUB
  20-install-llama.sh         builds llama.cpp for HIP or Vulkan
  30-install-comfyui.sh       venv + ROCm torch + ComfyUI
  50-install-services.sh      renders + installs the three systemd units
  80-lan-access.sh            ufw rule for the subnet, then HOST=0.0.0.0
  90-bench.sh                 llama-bench, both backends if present
  96-comfy-models.sh          list/download/delete ComfyUI models, free its GTT
  97-comfy-gen.sh             one image through ComfyUI — also the "draw" tool for a model
  comfy-mcp.py                stdio MCP server: image generation as a model tool
systemd/
  llama-server.service        :8080, one model
  llama-router.service        :8080, every GGUF in ~/ai/models (alternatives to each other)
  comfyui.service             :8188
mcp.example.json              an MCP client config with the comfyui server in it
workflows/
  sdxl.api.json               API-format SDXL graph for 97-comfy-gen.sh and comfy-mcp.py
```

## 6. Quick reference

| Thing | Value |
|---|---|
| llama-server API | `http://192.168.150.40:8080/v1` — `/v1/chat/completions`, `/health`, `/props`, `/models` |
| llama-server UI | `http://192.168.150.40:8080` — admin/debug |
| ComfyUI | `http://192.168.150.40:8188` — `/prompt`, `/history/<id>`, `/view` |
| Local (before Phase 5) | `127.0.0.1:8080`, `127.0.0.1:8188`; tunnel with `ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai@ai-box` |
| Publish | `sudo ./scripts/80-lan-access.sh --lan 192.168.150.0/24` |
| Firewall | `ufw status verbose` — active, default deny incoming, two rules naming the subnet |
| State directory | `~/.config/ai-box/` (env files), `~/ai/` (binaries, models, venvs) |
| RAM budget | ~12–14 GB OS + ~48 GiB GPU-addressable |

## 7. Honest status of this repo

- The **scripts are written and syntax-checked offline**: every shell script passes `bash -n`,
  and the GRUB editor was tested for idempotency, replacement, removal and dry-run safety on a
  copy of a grub config.
- **Not** executed against real `gfx1151` hardware, a loaded model or a ComfyUI instance. Treat
  the first run of each script as a supervised run.
- The **LAN publish step is unrun**: `80-lan-access.sh` passes `bash -n` and prints the right
  plan for both `--dry-run` and a refused apply, but the ufw branch has never executed on a
  machine with ufw, and no client has connected from another host. Run it supervised, then
  check `ss -ltnp` and `ufw status verbose` yourself.
- The **version numbers and model figures come from published docs and benchmarks** as of
  November 2026; `gfx1151` support is moving fast, so re-check
  [AMD's Strix Halo page](https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html)
  before assuming a pin is still current.
- The default image workflow names `sd_xl_base_1.0.safetensors`; the checkpoint must exist
  under that name in ComfyUI's `checkpoints/` folder, or the workflow's Model field has to be
  changed with it.

## The other two repositories

This box is the model server only. The rest of the household setup is deliberately separate:

| Repository | Runs on | Contains |
|---|---|---|
| `ai-box-autoinstall` | a USB stick | the unattended Ubuntu answer file, the `CIDATA` seed, `seed-usb.ps1` |
| `ai-box-docker` | a Proxmox VM, `192.168.150.50` | Docker Engine + compose, then Open WebUI `:8080`, Open Terminal `:8000` and OpenClaw `:18789`, each on its own static LAN address (`.51`, `.52`, `.53`) |

They reach this box at `http://192.168.150.40:8080/v1` and `http://192.168.150.40:8188`, which
is exactly what Phase 5 opens.
