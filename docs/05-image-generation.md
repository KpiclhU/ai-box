# 05 — Image generation

## Stack decision

**ComfyUI, in a Python venv, with PyTorch ROCm wheels.** On `gfx1151` in late 2026 that is
the combination with real evidence behind it: AMD validated ROCm 7.2.1 + PyTorch 2.9.1 +
Python 3.12 with FP16, and the long-running "not supported on gfx1151" ComfyUI issue
concludes that it is fully working on a current stack with no overrides.

Alternatives, honestly:

| Option | Verdict |
|---|---|
| **ComfyUI + ROCm** | Reliable, scriptable over HTTP, what the front door and scripts drive. Use this |
| stable-diffusion.cpp + Vulkan | Bypasses ROCm entirely and is easy to build, but slow on iGPUs (reported ~12 s/it) and has its own Strix Halo buffer bugs. Emergency fallback |
| InvokeAI | Now pins `gfx1151` torch wheels; workable, historically needed `HSA_OVERRIDE_GFX_VERSION`. Second choice |
| SD.Next | `--use-rocm` exists; little primary evidence on this chip |
| Forge / Forge-neo | Only unmaintained community ports. Not a foundation |

## Install

```bash
./scripts/30-install-comfyui.sh      # no sudo: the venv and models live in your home
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
| Flux.1-schnell (4 steps) | as above | Apache-2.0, the best default for chat images |

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

## Managing models from the command line

ComfyUI's Model Library (the **Models** entry in the left sidebar) only *browses* what is
already under `models/`: a self-hosted server has no download endpoint at all. `96-comfy-models.sh`
is the other half, and it works whether or not ComfyUI is running:

```bash
./scripts/96-comfy-models.sh                 # every model file, by folder, with sizes
./scripts/96-comfy-models.sh dirs            # the paths ComfyUI actually uses + free space
./scripts/96-comfy-models.sh download city96/FLUX.1-schnell-gguf '*Q8*' diffusion_models
./scripts/96-comfy-models.sh url https://civitai.com/api/download/models/12345 loras
./scripts/96-comfy-models.sh rm loras my_lora.safetensors     # -y to skip the prompt
./scripts/96-comfy-models.sh free            # POST /free: drop cached weights, keep the queue
```

Folder names are ComfyUI's own vocabulary, and picking the wrong one is the usual mistake:

| Folder | Holds |
|---|---|
| `checkpoints` | SDXL / SD1.5 all-in-one files — what `CheckpointLoaderSimple` lists |
| `diffusion_models` | Flux / SD3 / UNet-only weights (the new layout), with the encoders from `text_encoders/` |
| `text_encoders` | `clip_l.safetensors`, `t5xxl_fp16.safetensors` |
| `vae` | `ae.safetensors` for Flux, SDXL VAEs |
| `loras`, `controlnet`, `upscale_models`, `clip_vision`, `unet` | as named |

Gated Civitai files need a token: append `?token=<key>` to the download URL (the script reminds
you). Hugging Face gated repos need `hf auth login` first. `dirs` reads `extra_model_paths.yaml`
through ComfyUI, so models on the second NVMe are listed too; with ComfyUI stopped it falls back
to the checkout's `models/` tree.

If you would rather click: ComfyUI-Manager adds a model catalog and download dialog inside the
UI, and `comfy model download --url <url> --relative-path models/loras` is the official CLI for
the same job. Neither knows about this repo's presets; that is what the script is for.

## The ComfyUI HTTP contract

POST the workflow in **API format** (not the UI `nodes`/`links` file), then fetch results:

```
POST /prompt            {"prompt": {...}, "client_id": "<uuid>"}  -> {"prompt_id": "..."}
GET  /history/<id>      -> outputs.<node>.images[0] = {filename, subfolder, type}
GET  /view?filename=..&subfolder=..&type=output   -> image bytes
GET  /queue             -> pending/running counts
POST /free {"unload_models":true,"free_memory":true}
```

`workflows/openwebui-sdxl.api.json` is a working API-format graph. The CLI scripts
**resolve nodes by class type** rather than hard-coded ids: they find the `KSampler`, follow
its `positive` link to the text node, set the prompt, set `seed`/`steps`/`cfg`, and follow
`latent_image` to set width/height. That means the graph still works if you re-export it from
a different workflow. Open WebUI does the same job through an explicit node map, because it
only needs to target the fields it exposes ([12](12-deployment-and-client.md#sdxl-the-default)).

Two API gotchas worth knowing:

- Always send and filter on `client_id` if you attach to `/ws` — that socket is a broadcast
  firehose shared with the ComfyUI browser tab.
- If you queue many prompts, call `/free` between them. The caching allocator not being
  flushed between runs has been measured at ~2.4× slowdown on the second run.

## Getting an image out of the chat window

**The default is Open WebUI**, which drives ComfyUI directly: the Image toggle in a
conversation and the Images workspace both queue the workflow and render the result. That is
what household accounts use, and it needs no tools on `llama-server` at all
([12](12-deployment-and-client.md#4-images-through-open-webui)).

The rest of this section is the **admin path** — llama.cpp's own Llama Chat, which
**cannot generate images by itself**. The server has no image-generation tool and no
image-backend flag; its built-in tools are only `read_file`, `file_glob_search`,
`grep_search`, `exec_shell_command`, `write_file`, `edit_file` and `get_info`. Two ways to
close the loop for a one-off, and they are not exclusive:

**1. Give llama-server an MCP tool.** `scripts/comfy-mcp.py` is a stdio MCP server (stdlib
only, no SDK, no venv) that exposes `generate_image`, `list_models`, `status` and
`free_memory`. Point the unit at it and the model draws as a normal tool call, with no shell
access at all:

```
# ~/.config/ai-box/llama-router.env   (or llama-server.env for the single-model unit)
LLAMA_EXTRA_ARGS="... --parallel 2 --mcp-servers-config /home/ai-user/.config/ai-box/mcp.json"
```

```bash
cp mcp.example.json ~/.config/ai-box/mcp.json    # the comfyui entry is already in it
chmod +x ~/ai-box/scripts/comfy-mcp.py
sudo systemctl restart llama-router && curl -s localhost:8080/tools
```

Setup detail, the router gotchas and the timeouts:
[10-webui-and-models.md](10-webui-and-models.md#comfyui-let-the-router-draw).

**2. Let the model run the CLI.** Give the server the shell tool, and `97-comfy-gen.sh` becomes
the model's "draw" action:

```
# ~/.config/ai-box/llama-server.env  (or llama-router.env)
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --tools exec_shell_command"
```

```bash
./scripts/97-comfy-gen.sh "a corgi astronaut, cinematic lighting" --steps 28 -W 1024 -H 1024
# -> /home/ai-user/ai/images/comfy-20261120-143012-123456789.png
```

Then in the chat: *“generate an image of a corgi astronaut by running
/home/ai-user/ai-box/scripts/97-comfy-gen.sh with your prompt”*. The model calls the tool, the
script queues the graph on ComfyUI, and the reply carries the PNG path. Options: `-n` negative
prompt, `-W`/`-H` (rounded to multiples of 8), `--steps`, `-c` cfg, `--seed`, `-m` checkpoint,
`-o` output dir. It uses `COMFY_WORKFLOW` (default `workflows/openwebui-sdxl.api.json`) and resolves
nodes by class type, so a re-exported graph still works.

**3. Use Open WebUI** (the default, above). Its *Image Generation* supports ComfyUI
directly: admin → Settings → Images → engine `ComfyUI`, base URL `http://127.0.0.1:8188`,
and an **API-format** workflow (ComfyUI: gear → *Enable Dev mode Options* → *Save (API Format)*),
with node ids mapped for prompt, model, size, steps and seed. `workflows/` already contains
two such graphs.

Either way the generation competes with the LLM for GTT: unload the model first (router UI →
**Models** → unload, or `POST /models/unload`) if a Flux job needs the room, and keep SDXL
for when you want both.

## Verify

```bash
curl -s localhost:8188/system_stats | jq '.devices[0] | {name, vram_total, vram_free}'
```

Then generate one image (the ComfyUI UI, or `scripts/97-comfy-gen.sh`), and watch `amdgpu_top` for
the GTT usage.

The UI is at `http://127.0.0.1:8188`. On a Server install there is no browser on the box, so
forward the port from your laptop and open it there — same tunnel as in
[04-llm-stack.md](04-llm-stack.md):

```bash
ssh -N -L 8188:127.0.0.1:8188 ai@ai-box
```
