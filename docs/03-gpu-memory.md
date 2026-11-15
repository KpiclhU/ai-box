# 03 — GPU memory on a unified-memory APU

This is the step that decides whether the machine feels like a 48 GB GPU or a 32 GB one.
Get it right and everything else is downloads.

## Two different "VRAM" numbers

On a normal GPU, VRAM is a separate pool. On Strix Halo, the GPU has no memory of its own:

| Concept | What it is | Where it comes from |
|---|---|---|
| **VRAM (carve-out)** | Memory the BIOS reserves at boot for the GPU | `Advanced → iGPU Memory Configuration`, 512 MB–56 GB |
| **GTT** | System RAM the GPU can *map* on demand | Limited by the `ttm` kernel module's `pages_limit` |
| **Total GPU-addressable** | carve-out + GTT | What your model has to fit into |

By default GTT is about **50 % of RAM** — which is exactly why a 64 GB machine looks like it
has ~32 GB of usable GPU memory, and why half the "it OOMs" reports on the internet exist.

**A tool showing a small "VRAM total" is not telling you the truth about this machine.**
`rocm-smi` reports the carve-out. `amdgpu_top` shows both. Only GTT + carve-out is real.

## What AMD recommends (and what most guides get wrong)

1. Keep the BIOS carve-out **small** — 512 MB is the documented recommendation.
2. Raise the shared limit from the OS with the `ttm` module parameters.
3. There is **no performance difference** between a large static carve-out and a GTT-backed
   mapping on Strix Halo, so a big carve-out is pure loss: it removes RAM from the OS and
   has been linked to USB ports dying after resume on this board.

`amdgpu.gttsize` is deprecated in current kernels and logs a warning telling you to use
`ttm.pages_limit`. Don't mix the two.

## The numbers for 64 GB

`ttm.pages_limit` is a count of **4 KiB pages**: `GiB × 262144`.

| GPU-addressable | `pages_limit` / `page_pool_size` | Leaves for OS | Use when |
|---|---|---|---|
| 40 GiB | `10485760` | ~24 GB | Conservative; Flux fp16 plus a desktop |
| 44 GiB | `11534336` | ~20 GB | Balanced default |
| **48 GiB** | **`12582912`** | **~16 GB** | **Recommended start** — 30B Q6_K, Flux fp16, SDXL with room |
| 52 GiB | `13631488` | ~12 GB | 70B dense Q4 experiments, headless |
| 56 GiB | `14680064` | ~8 GB | Framework's documented max; only with no desktop apps |
| 64 GiB | `16777216` | ~0 | **Do not.** The OS has nothing left and large model loads get OOM-killed |

The failure mode when you overdo it is not a clean "out of memory": a 44 GB checkpoint gets
read into host RAM and pushes the box into swap → swap thrash → `SIGABRT` from the loader.
Leave real RAM for the kernel.

## Apply it

```bash
sudo ./scripts/10-gpu-memory.sh 48      # GiB; 44 is more conservative, 52 more aggressive
sudo reboot
./scripts/00-preflight.sh
```

The script appends to `GRUB_CMDLINE_LINUX_DEFAULT` (backing up `/etc/default/grub`), runs
`update-grub`, and refuses to duplicate an existing setting. Equivalent by hand:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash ttm.pages_limit=12582912 ttm.page_pool_size=12582912"
```

> **Note on `page_pool_size`:** it caps the TTM page pool that caches pages for reuse. Some
> guides leave it unset; setting it equal to `pages_limit` is the common
> Strix-Halo configuration and is what the script writes.

## Verify

```bash
cat /sys/module/ttm/parameters/pages_limit          # 12582912
cat /sys/module/ttm/parameters/page_pool_size
sudo apt install -y pipx && pipx install amd-debug-tools
amd-ttm                                             # e.g. "12582912 pages (48.00 GB)"
```

Runtime view of what is actually mapped:

```bash
# GTT and VRAM usage, per-process, live
amdgpu_top

# or without extra tooling
grep -E 'mem_info_(gtt|vram)' /sys/kernel/debug/dri/0/amd_mem_info
```

A model that "should" fit but does not usually means: GTT not applied (check
`pages_limit`), or the launcher is capping itself at the carve-out figure.

## Interaction with the BIOS carve-out

Keep it at 512 MB unless you hit a specific application that refuses to allocate without a
minimum VRAM size. Setting the BIOS to 2 GB is harmless if some game or app demands it; it
just costs 1.5 GB of system RAM. Setting it to 32 GB to "make the GPU faster" is a mistake
on this platform.

## What about the NPU?

The XDNA 2 NPU (50 TOPS) is not used by llama.cpp or ComfyUI today in a way that helps
here. Ignore it; it is not part of this plan.
