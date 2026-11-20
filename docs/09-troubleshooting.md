# 09 — Troubleshooting

Symptom first, cause second, fix third. Nearly everything on this platform fails in one of
five ways: kernel too old, memory limit not raised, wrong wheel index, FP8 weights, or an
old workaround applied to a new stack.

## `/dev/kfd` missing, or ROCm sees no GPU

```bash
ls -l /dev/kfd; dmesg | grep -i -E 'amdgpu|kfd' | tail -30
rocminfo | grep gfx
```

- Kernel older than 6.18.4 → upgrade. This is the single most common cause.
- `amdgpu` not binding at all → check the iGPU is enabled and the BIOS was not left in a
  weird state after a firmware update.
- User not in `render`/`video` → `sudo usermod -aG render,video $USER`, then log out.

## `HIP error: invalid device function` / `HSA_STATUS_ERROR_INVALID_ISA`

You installed `rocm6.x` PyTorch wheels. They contain no `gfx1151` kernels.

```bash
pip install --force-reinstall torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/rocm7.2
```

Then check `torch.cuda.get_device_name(0)` says Radeon 8060S.

## Model "doesn't fit" when it obviously should

```bash
cat /sys/module/ttm/parameters/pages_limit     # expect ~12582912 for 48 GiB
amd-ttm
```

Default GTT is 50 % of RAM. If `pages_limit` is still the default, the GRUB change did not
take: re-run `sudo ./scripts/10-gpu-memory.sh 48`, confirm the args are in
`/proc/cmdline`, reboot.

## Load fails with `SIGABRT`, or the box locks up during a big load

This is **host** RAM exhaustion, not VRAM. A large checkpoint is read into anonymous memory
and pushes the machine into swap.

- Lower `pages_limit` (48 → 44).
- Don't use `--no-mmap` or `--disable-mmap` on this box.
- Shrink context or model.

## First SDXL/Flux generation hangs for 10–25 minutes

Expected. Kernel/MIOpen compilation. UMA is slow at it. Do not kill it; the cache makes the
second run orders of magnitude faster. Adding `MIOPEN_FIND_MODE=FAST` shortens the tuning.

## Generation works, then hangs with the GPU at 100 %

A known ROCm issue where the runtime waits on a completion interrupt that never arrives.

```bash
# in the ComfyUI env file, then restart the service
HSA_ENABLE_INTERRUPT=0
```

That busy-wait workaround took a documented 0/16 success rate to 16/16.

## `hipErrorOutOfMemory` at 2.9 GB used

ComfyUI's Dynamic VRAM, not actual capacity. `--disable-dynamic-vram` fixes it. Related:
consecutive jobs slow down ~2.4× because the allocator is not flushed — call
`POST /free {"unload_models": true, "free_memory": true}` between batches.

## fp8 model segfaults on load, or runs slower than fp16

RDNA 3.5 has no FP8 matmul. Use fp16/bf16 or GGUF Q8_0. This is architectural, not a bug
that will be fixed.

## Huge context makes everything crawl

`-c 32768` is a deliberate default; `-c 131072` on a 30B model costs many GB of KV cache and
competes with the image stack. Raise it only when you have measured free GTT.

## `llama-bench` / `llama-server`: `cudaMalloc failed: out of memory` at 48 GiB

ROCm printing `Total VRAM: 49152 MiB` and then failing to allocate a 23 GB model means GTT is
already mapped, not that the limit is wrong. The usual cause is a second copy of the same
model: `llama-server.service` is running and holding ~24 GB of GTT plus its KV cache, so the
bench's allocation is exactly what does not fit.

```bash
sudo systemctl stop llama-server
./scripts/90-bench.sh
sudo systemctl start llama-server
```

`./scripts/90-bench.sh` now refuses to start while the unit is active (override with
`BENCH_ALLOW_BUSY=1`). To see who is using the memory: `amdgpu_top`, or as root
`grep mem_info_gtt /sys/kernel/debug/dri/0/amd_mem_info`. A live ComfyUI Flux job (30–34 GB)
is the other big consumer; page cache does not matter, it is reclaimable.

If GTT is genuinely idle and the allocation still fails, check that `pages_limit` survived
the reboot (`cat /sys/module/ttm/parameters/pages_limit`), then try a smaller quant
(Q4_K_M ≈ 17 GB) to separate "limit not applied" from "model too big".

## Decode is much slower than the numbers in the README

In order:

1. Check `-ngl` actually offloaded: read the load log, not the flags.
2. `powerprofilesctl get` → set `performance`.
3. Compare backends: `./scripts/90-bench.sh` (HIP vs Vulkan). Vulkan often wins decode.
4. Check GTT: a model partially in GTT and partially in RAM runs at RAM speed.
5. Check you are not running a second model or a Flux job at the same time.
6. Do the arithmetic before hunting a bug: ~220 GB/s ÷ model size in GB ≈ ceiling tok/s.
   A 24 GB Q6_K at 10 tok/s *is* the hardware — see the next section.

## A 27B dense model tops out near 10 tok/s — that is the bus, not a bug

Decode reads every weight the token touches, so 220 GB/s ÷ 24 GB ≈ 9 tok/s. Nothing is
disabled and unified memory has no setting to enable. What is usually missing is
**speculative decoding**, which many Qwen3.8-27B GGUFs can do with no second model:

```bash
head -c 64000000 ~/ai/models/model.gguf | strings -n 8 | grep -c nextn   # MTP head present?
~/ai/llama.cpp/build/bin/llama-server --help | grep -c spec-type         # build supports it?
```

If both are non-zero, add `--spec-type draft-mtp --spec-draft-n-max 3` to `LLAMA_EXTRA_ARGS`
and restart. Measured on this chip at Q6_K: **8.4 → 18.7 tok/s** at ~65 % draft acceptance,
for ~4–8 % prefill. Details and caveats: [04-llm-stack.md](04-llm-stack.md#speculative-decoding-the-one-flag-that-doubles-a-dense-model).

A repo's plain `-Q6_K` file usually has the head pruned while its `-MTP-Q6_K` sibling keeps it.
If `grep -c nextn` prints 0, take the flag back out: the server warns
`model doesn't contain MTP layers` and exits with `failed to create MTP context`.

Three things that look like speed levers and are not:

- **Bigger `-c`.** This hybrid keeps decode flat from 16k to 250k; more context only costs memory.
- **Bigger `-ub`.** Prefill only, and slightly worse with the MTP head loaded.
- **`--spec-draft-n-max` above 3.** n=4 reported halving throughput at the same acceptance,
  because the verification batch drops off the fast mat-vec path.

## Vulkan build: `vk::OutOfDeviceMemoryError`, or UMA reports 0 MB free

Known `gfx1150/gfx1151` UMA reporting bugs in some Vulkan paths. ROCm is the fallback for
image models; for llama.cpp, try a newer Vulkan SDK/driver or just use the HIP build.

## Download from the web UI / router fails: `model '…' resolves no file to download`

Not a disk-space or size problem. `llama-router` first asks huggingface.co for the repo's file
list and picks a file from it; this error means that step came back with nothing to download.
The reason is logged just above, because the resolution happens while the request is handled:

```bash
journalctl -u llama-router -n 80 --no-pager | grep -iE 'get_repo|hf_plan|https|gguf'
```

| Line in the log | Cause | Fix |
|---|---|---|
| `HTTPS is not supported. Please rebuild with …` | the build linked no OpenSSL, so every `https://` request fails before a socket is opened | `sudo apt install libssl-dev`, then `./scripts/20-install-llama.sh rocm` |
| `get_repo_commit: error: GET failed (429)` / `(404)` | Hugging Face throttled the anonymous lookup, or the repo name is not what you think | wait a minute and retry; for gated/rate-limited repos put `HF_TOKEN=…` in `~/.config/ai-box/llama-router.env` and restart |
| `no GGUF files found in repository …` + `Available GGUF files:` | the `:QUANT` tag matched no file name in that repo | use a tag from the printed list, or download the exact file with the CLI below |
| nothing at all | no route to huggingface.co, or a proxy between you and it | `curl -sS https://huggingface.co/api/models/<user>/<repo>/refs` — llama.cpp has no proxy support, so a machine that only reaches the internet through one cannot download |

Check the binary in one line:

```bash
ldd ~/ai/llama.cpp/build/bin/llama-server | grep -i ssl     # libssl.so* means HTTPS is compiled in
```

The CLI is the dependable path for anything unusual — it resolves the same repo through
`huggingface_hub` (own TLS, real HTTP errors) and drops the file into `~/ai/models`:

```bash
./scripts/60-download-models.sh <user>/<repo> '<glob>'
./scripts/95-models.sh reload
```

Quote the glob tightly when a repo ships two files per quant. Re-uploaders often put an `MTP`
variant next to the plain one, and `:Q8_0` resolves to whichever of the two comes first:

```bash
# DavidAU/…-MAX-MTP-GGUF carries …-MAX-Q8_0.gguf (~30 GB) and …-MAX-MTP-Q8_0.gguf (~30 GB)
./scripts/60-download-models.sh \
  DavidAU/Qwen3.8-27B-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX-MTP-GGUF \
  '*-MAX-Q8_0.gguf'
```

And a 27B at Q8_0 is ~30 GB of the ~48 GiB GTT before any KV cache — it leaves nothing for a
32k context next to ComfyUI. Q4_K_M or Q6_K is the sane pick here ([07-models.md](07-models.md)).

## Wi-Fi or Bluetooth disappears

MT7925. `rfkill list`, `sudo modprobe -r mt7925e && sudo modprobe mt7925e`, reboot. Reported
after some updates; usually a firmware/driver packaging issue, not hardware.

## Ethernet missing after cold boot

Community-reported on this board: the RTL8126 5 GbE sometimes does not appear on a cold
boot. Warm reboot once. If it persists, check `lspci -nn | grep -i ethernet` and
`dmesg | grep -i r8169`.

## USB ports dead after suspend/resume

Framework firmware issue linked to **large custom iGPU memory carve-outs**. Set BIOS
iGPU Memory Size back to 512 MB / Auto and rely on GTT instead
([03-gpu-memory.md](03-gpu-memory.md)). Also check the BIOS is ≥ 3.06.

## Discord bot: slash commands don't appear

- `DISCORD_GUILD_ID` set? Guild commands are instant; global ones are not.
- Invited with the `applications.commands` scope?
- You have hit **200 command creates/day/guild** — this resets on a rolling basis. Stop
  restarting the bot if `tree.sync()` runs on every start.
- The bot is `Restart=always`; a crash-looping bot can burn the daily create budget. Check
  `journalctl -u ai-discord-bot` for the crash first.

## Bot replies are empty, or never arrive

```bash
curl -s localhost:8080/health
curl -s localhost:8080/v1/models | jq
journalctl -u ai-discord-bot -n 50 --no-pager
```

- `503` from `/health` = model still loading.
- `LLM_MODEL` must match the `--alias` (or model id) that `/v1/models` reports.
- Empty replies from a reasoning model: it spent the whole budget on `reasoning_content`.
  Raise `LLM_MAX_TOKENS` or disable thinking.
- `400` about context length: the history plus prompt exceeded `-c`. `/reset` or raise `-c`.

## Bot stream stalls mid-reply

A short `httpx` read timeout. The bot sets `read=None` for exactly this reason; if you edited
it, put it back. Prompt processing on a large context can be silent for 30+ seconds.

## Discord rate limits / edits lag

`429`s in the log mean edits are too frequent. The bot gates at 1.2 s; do not lower it. Also
check you are not passing the same message to multiple bots.

## `fwupdmgr` finds nothing

`sudo fwupdmgr refresh --force`, and check the Framework release page — not every BIOS version
is on LVFS. USB/EFI update is the fallback. Always with the PSU connected.

## Where to look next

- AMD Strix Halo optimization: <https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html>
- Framework's Linux compatibility table: <https://frame.work/desktop?tab=linux>
- Framework firmware issues: <https://github.com/FrameworkComputer/SoftwareFirmwareIssueTracker>
- llama.cpp server docs: <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>
- ComfyUI API: <https://docs.comfy.org/development/comfyui-server/api-examples>
