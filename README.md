# ai-box — Framework Desktop 64 GB

An install plan and working automation for turning a Framework Desktop (Ryzen AI Max+ 395,
64 GB) + a 2 TB NVMe SSD into a local AI machine:

- **Coding assistance** — a local model served over an OpenAI-compatible API, usable from
  Claude Code / opencode / Continue / Cline / Aider / Open WebUI.
- **Image generation** — ComfyUI on the same iGPU, driven headlessly over HTTP.
- **Discord chat** — a bot that streams LLM replies into your channels and generates images
  on command.

Everything here is designed for **one 64 GB machine with no discrete GPU**. That constraint
drives almost every decision below.

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
| Image stack | **ComfyUI in a venv**, PyTorch ROCm wheels | Most reliable path on `gfx1151`; scriptable over HTTP for the bot |
| Discord bot | **discord.py 2.7.1**, single async process | Slash commands + streaming edits; talks to llama-server and ComfyUI over loopback |
| Orchestration | systemd user-agnostic system units | Starts on boot, restarts on failure, no Docker-in-a-VM problems |

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
edition is the better fit here**: every service in this repo is HTTP on loopback, nothing
needs X or Wayland, and you get ~1–2 GB more RAM for models. Install Desktop instead only
if you also want a screen and a browser on the box itself. Then update firmware and verify
the kernel.

```bash
uname -r                      # want >= 6.18.4 ; 7.x on 26.04
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update
lspci -nn | grep -i vga       # Radeon 8060S, device id 1002:... 
```

Step-by-step, including the ISO/USB, partitioning and first-boot checks:
[docs/02-os-install.md](docs/02-os-install.md)

**Install it unattended if you like.** The Server installer reads a YAML answer file, and
`autoinstall/user-data` is one for this box — hostname, user, SSH keys, whole-disk ext4,
toolchain and the GPU memory args already set. The recipe is in
[docs/02](docs/02-os-install.md#unattended-install-autoinstall): one USB stick with the file
added to it and no keystrokes at all, or two sticks and one `e`-and-append at the GRUB menu.

### Phase 2 — Give the GPU the memory (20 min)

```bash
sudo ./scripts/10-gpu-memory.sh 48      # GiB of GPU-addressable memory, writes GRUB args
sudo reboot
./scripts/00-preflight.sh               # verifies GTT/VRAM, ROCm, Vulkan, tools
```

This sets `ttm.pages_limit` / `ttm.page_pool_size` and leaves the BIOS carve-out where it
belongs. Background and the arithmetic: [docs/03-gpu-memory.md](docs/03-gpu-memory.md)

### Phase 3 — LLM + coding assistant (1–2 h, mostly compile time)

```bash
./scripts/20-install-llama.sh rocm               # or: vulkan (no sudo: it builds in your home)
hf download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
  --include '*Q6_K*' --local-dir ~/ai/models     # Qwen3-Coder-30B-A3B, ~25 GB
sudo ./scripts/50-install-services.sh            # llama-server on 127.0.0.1:8080
curl -s localhost:8080/health
```

Then point your editor at `http://127.0.0.1:8080/v1` (OpenAI-compatible) — instructions for
Claude Code, opencode, Continue, Cline and Aider are in
[docs/04-llm-stack.md](docs/04-llm-stack.md). Model picks and sizes:
[docs/07-models.md](docs/07-models.md).

With a Server install the editor is on your laptop, so forward the port first (leave it
running):

```bash
ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai@ai-box
```

### Phase 4 — Image generation (1–2 h, mostly downloads)

```bash
./scripts/30-install-comfyui.sh                       # again, no sudo — the venv lives in your home
./scripts/96-comfy-models.sh download stabilityai/stable-diffusion-xl-base-1.0 \
  'sd_xl_base_1.0.safetensors' checkpoints            # 7 GB checkpoint
./scripts/96-comfy-models.sh                          # what is on disk, by folder, with sizes
sudo ./scripts/50-install-services.sh                 # ComfyUI on 127.0.0.1:8188
```

Expect **~15–25 s per 1024² SDXL image**, ~15–30 s for Flux.1-schnell, 70–120 s for
Flux.1-dev. First generation is slow (kernel/MIOpen compilation) — wait it out, do not kill
it. Details, model layout and the FP8 trap: [docs/05-image-generation.md](docs/05-image-generation.md)

### Phase 5 — Discord bot (30 min)

1. Create an application at <https://discord.com/developers/applications>, add a **Bot**,
   copy the token, invite it with the `bot` + `applications.commands` scopes.
2. `cp bot/.env.example .env`, set `DISCORD_TOKEN` and `DISCORD_GUILD_ID`.
3. ```bash
   ./scripts/40-install-bot.sh
   sudo ./scripts/50-install-services.sh      # ai-discord-bot.service
   ```
4. In Discord: `/chat`, `/image`, `/reset`, `/status`.

Commands, streaming behaviour, history and rate-limit handling:
[docs/06-discord-bot.md](docs/06-discord-bot.md)

### Phase 6 — Operations (ongoing)

[docs/08-operations.md](docs/08-operations.md) covers systemd control, logs, updating ROCm
and ComfyUI, backup of models/history, and the memory-budget rules for running the LLM and
image generation at the same time. When something breaks:
[docs/09-troubleshooting.md](docs/09-troubleshooting.md).

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
  06-discord-bot.md           the bot: commands, streaming, limits, ToS
  07-models.md                what fits in 64 GB, with sizes
  08-operations.md            services, updates, backups, coexistence
  09-troubleshooting.md       symptom → cause → fix
  10-webui-and-models.md      built-in chat UI, MCP connectors, router mode
autoinstall/
  user-data                   Ubuntu Server autoinstall answer file (unattended install)
  meta-data                   cloud-init meta-data for the CIDATA seed volume
scripts/
  00-preflight.sh             read-only health/report
  10-gpu-memory.sh            sets ttm.pages_limit via GRUB
  20-install-llama.sh         builds llama.cpp for HIP or Vulkan
  30-install-comfyui.sh       venv + ROCm torch + ComfyUI
  40-install-bot.sh           venv + bot deps
  50-install-services.sh      renders + installs systemd units
  80-lan-access.sh            serves both UIs to a Caddy running on another box
  90-bench.sh                 llama-bench, both backends if present
  96-comfy-models.sh          list/download/delete ComfyUI models, free its GTT
  97-comfy-gen.sh             one image through ComfyUI — also Llama Chat's "draw" tool
  comfy-mcp.py                stdio MCP server: image generation as a model tool
  windows-seed-usb.ps1        puts the answer file on an ISO-mode USB stick (Windows)
systemd/
  llama-server.service        :8080, one model
  llama-router.service        :8080, every GGUF in ~/ai/models (alternatives to each other)
  comfyui.service             :8188
  ai-discord-bot.service      the bot
bot/                          discord.py bot (bot.py, llm.py, comfy.py, store.py)
  workflows/sdxl.api.json     API-format ComfyUI graph with a valid default checkpoint
```

## 6. Quick reference

| Thing | Value |
|---|---|
| llama-server | `http://127.0.0.1:8080` — also the built-in chat UI, with MCP tools |
| llama-server API | `/v1/chat/completions`, `/health`, `/props`, `/tools` |
| ComfyUI | `http://127.0.0.1:8188` — `/prompt`, `/history/<id>`, `/view` |
| ComfyUI over MCP | `mcp.example.json` → `~/.config/ai-box/mcp.json`, then `--mcp-servers-config` in `LLAMA_EXTRA_ARGS` |
| SSH tunnel (headless box) | `ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai@ai-box` |
| Through your Caddy | `sudo ./scripts/80-lan-access.sh --proxy 192.168.1.10` → `~/.config/ai-box/caddy-ai-box.caddy` |
| State directory | `~/.config/ai-box/` (env files), `~/ai/` (binaries, models, venvs) |
| Bot data | `~/ai/data/bot.sqlite3` |
| RAM budget | ~12–14 GB OS + ~48 GiB GPU-addressable |

## 7. Honest status of this repo

- The **scripts and bot are written, syntax-checked and exercised offline**: shell scripts
  pass `bash -n`, the bot passes `py_compile` and an import-and-assert run against the real
  `discord.py`, and the GRUB editor was tested for idempotency, replacement, removal and
  dry-run safety on a copy of a grub config.
- **Not** executed against real `gfx1151` hardware, a loaded model, a ComfyUI instance or a
  live Discord token. Treat the first run of each script as a supervised run.
- The **version numbers and model figures come from published docs and benchmarks** as of
  November 2026; `gfx1151` support is moving fast, so re-check
  [AMD's Strix Halo page](https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html)
  before assuming a pin is still current.
- The SDXL workflow in `bot/workflows/sdxl.api.json` requires a checkpoint named in
  `.env` (`COMFY_CHECKPOINT`); the bot substitutes it at request time.

## Next steps if you want to go further

- A preset file plus router mode (see [docs/10](docs/10-webui-and-models.md)) if you want
  several models behind one port without a third-party switcher.
- A second 2 TB drive in the rear socket for a model library (both slots are Gen4 x4).
- Whisper or a TTS model on the NPU/GPU for voice in Discord — not wired up here.
