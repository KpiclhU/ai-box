# 05 — Image generation

## Stack decision

**ComfyUI, in a Python venv, with PyTorch ROCm wheels.** On `gfx1151` in late 2026 that is
the combination with real evidence behind it: AMD validated ROCm 7.2.1 + PyTorch 2.9.1 +
Python 3.12 with FP16, and the long-running "not supported on gfx1151" ComfyUI issue
concludes that it is fully working on a current stack with no overrides.

Alternatives, honestly:

| Option | Verdict |
|---|---|
| **ComfyUI + ROCm** | Reliable, scriptable over HTTP, what the bot drives. Use this |
| stable-diffusion.cpp + Vulkan | Bypasses ROCm entirely and is easy to build, but slow on iGPUs (reported ~12 s/it) and has its own Strix Halo buffer bugs. Emergency fallback |
| InvokeAI | Now pins `gfx1151` torch wheels; workable, historically needed `HSA_OVERRIDE_GFX_VERSION`. Second choice |
| SD.Next | `--use-rocm` exists; little primary evidence on this chip |
| Forge / Forge-neo | Only unmaintained community ports. Not a foundation |

## Install

```bash
sudo ./scripts/30-install-comfyui.sh
```

By hand, the important part is the wheel index:

```bash
git clone https://github.com/comfyanonymous/ComfyUI ~/ai/comfyui
cd ~/ai/comfyui
python3 -m venv .venv && . .venv/bin/activate
pip install --upgrade pip
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm7.2
pip install -r requirements.txt

python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

Expect `2.9.x True AMD Radeon 8060S` (or `gfx1151`).

Two traps:

- **`rocm6.x` wheels contain no `gfx1151` kernels.** That is the source of
  `HIP error: invalid device function` / `HSA_STATUS_ERROR_INVALID_ISA`. Use `rocm7.2` or newer.
- **Pin the three torch packages together.** The unpinned resolver has been observed
  installing a `torch`/`torchvision` pair built for different versions. Once it works:
  `pip freeze > constraints.txt`, and install with `-c constraints.txt` next time.

## Environment that matters

```bash
export TORCH_BLAS_PREFER_HIPBLASLT=1
export TORCH_ROCM_AOTRITON_ENABLE=1
export FLASH_ATTENTION_TRITON_AMD_ENABLE=1
export PYTORCH_ALLOC_CONF=expandable_segments:True
export MIOPEN_FIND_MODE=FAST
python main.py --use-pytorch-cross-attention --listen 127.0.0.1 --port 8188
```

- `--use-pytorch-cross-attention` is the biggest quality-neutral speedup on this chip: it
  routes into the AOTriton flash kernels.
- `MIOPEN_FIND_MODE=FAST` avoids long naive-convolution autotuning.
- **Do not** use `--disable-mmap` or `--high-ram` on unified memory. They pin weights in
  un-evictable RAM and cause swap thrash on a 64 GB box.

### What not to bother with

| Knob | Why not |
|---|---|
| `HSA_OVERRIDE_GFX_VERSION` | Not needed on a current stack. `11.0.0` actively selects the wrong kernels |
| `--force-fp32` | Old workaround; halves your speed for nothing |
| `COMFYUI_ENABLE_MIOPEN=1` | Measured 1.00× difference on this hardware |
| `PYTORCH_TUNABLEOP_ENABLED=1` | Costs a very slow first run for marginal gain |

## FP8 is a dead end here

RDNA 3.5 has **no FP8 matrix acceleration** (`torch._scaled_mm` is CDNA3+/MI300 only) and AMD
only validates FP16 on Ryzen APUs. Consequences seen in the wild: fp8 checkpoints segfaulting
on load, or loading and silently running slower.

Use **fp16/bf16** or **GGUF** instead. For Flux, GGUF Q8_0 is the pragmatic middle ground.
Avoid Q5_K GGUF on this chip (dequant instability reported); Q8_0 and Q4_K are fine.

## Memory: what things cost

| Model | Peak | Notes |
|---|---|---|
| SDXL 1024² | ~10 GB | Plenty of headroom; leave a batch queue running |
| Flux.1-dev **fp16** + fp16 T5 | ~34 GB | Full quality, fits in a 48 GiB GTT |
| Flux.1-dev GGUF Q8_0 + fp8 T5 | ~20 GB | Good quality, comfortable |
| Flux.1-dev GGUF Q4_K_S | ~10–14 GB | Visibly degraded, but very fast |
| Flux.1-schnell (4 steps) | as above | Apache-2.0, the best default for a bot |

## Performance you should expect

AMD's published numbers are **Windows**, so treat them as a ceiling:

- SDXL 1024², 25 steps: **1.43–1.48 it/s**, ~18 s steady / ~27 s cold
- Flux.1-dev fp16, 20 steps: **3.64 s/it**, ~78 s steady / ~104 s cold

Linux community figures land lower and vary. For planning on 64 GB:

| Workload | Per image |
|---|---|
| SDXL 1024², 25 steps | 15–25 s |
| Flux.1-schnell, 4 steps | 15–30 s |
| Flux.1-dev, 20 steps | 70–120 s |

**First generation after an install is slow** — kernel and MIOpen compilation. A documented
`gfx1151` Flux run spent 25 minutes on step 1, then 38 s on the next launch. Wait it out; the
cache makes it a one-time cost.

## Model files and layout

```
~/ai/comfyui/models/
  checkpoints/            SDXL checkpoints (sd_xl_base_1.0.safetensors, Juggernaut, RealVis)
  diffusion_models/       Flux transformer (flux1-dev.safetensors, flux1-schnell.safetensors)
  text_encoders/          clip_l.safetensors, t5xxl_fp16.safetensors
  vae/                    ae.safetensors
  unet/                   GGUF Flux (with ComfyUI-GGUF custom node)
  loras/
  upscale_models/
```

Sources:

- SDXL base 1.0 — Stability's `sd_xl_base_1.0.safetensors` (accept the licence on HF).
  Community fine-tunes (Juggernaut XL, RealVisXL) generally look better for photographs.
- Flux.1-schnell — Apache-2.0, `black-forest-labs/FLUX.1-schnell` or the Comfy repack
  `Comfy-Org/Flux-1-Schnell` (all-in-one fp8 file).
- Flux.1-dev — non-commercial licence, gated on HF (`hf auth login` first).
- Flux GGUF — `city96/FLUX.1-dev-gguf` plus the `ComfyUI-GGUF` custom node.

Custom nodes (optional, via ComfyUI-Manager):

```bash
cd ~/ai/comfyui/custom_nodes
git clone https://github.com/city96/ComfyUI-GGUF     # only if using Flux GGUF
```

## The API contract the bot uses

POST the workflow in **API format** (not the UI `nodes`/`links` file), then fetch results:

```
POST /prompt            {"prompt": {...}, "client_id": "<uuid>"}  -> {"prompt_id": "..."}
GET  /history/<id>      -> outputs.<node>.images[0] = {filename, subfolder, type}
GET  /view?filename=..&subfolder=..&type=output   -> image bytes
GET  /queue             -> pending/running counts
POST /free {"unload_models":true,"free_memory":true}
```

`bot/workflows/sdxl.api.json` is a working API-format graph. The bot **resolves nodes by
class type** rather than hard-coded ids: it finds the `KSampler`, follows its `positive`
link to the text node, sets the prompt, sets `seed`/`steps`/`cfg`, and follows
`latent_image` to set width/height. That means the graph still works if you re-export it from
a different workflow.

Two API gotchas worth knowing:

- Always send and filter on `client_id` if you attach to `/ws` — that socket is a broadcast
  firehose shared with the ComfyUI browser tab.
- If you queue many prompts, call `/free` between them. The caching allocator not being
  flushed between runs has been measured at ~2.4× slowdown on the second run.

## Verify

```bash
curl -s localhost:8188/system_stats | jq '.devices[0] | {name, vram_total, vram_free}'
```

Then use the bot's `/image` or the ComfyUI UI once, and watch `amdgpu_top` for GTT usage.
