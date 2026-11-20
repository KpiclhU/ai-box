# 07 — Models for 64 GB

Budget: **~48 GiB GPU-addressable**, of which maybe 44 is comfortable alongside a desktop
and the KV cache. Weights + KV cache + compute buffers all come out of this.

Rule of thumb for a 32k-context Q4/Q6 model: **weights + 3–6 GB** of overhead.

## Coding (the reason the box exists)

| Model | Type | Q6_K / Q4 size | Expectation |
|---|---|---|---|
| **Qwen3-Coder-30B-A3B-Instruct** | MoE 30B, 3B active | ~25 GB / ~18 GB | **Default pick.** ~60–75 tok/s, strong at edits and tool calls |
| Qwen3-Coder-Next / newer siblings | MoE | check repo | Re-check quarterly; this family moves fast |
| Devstral-Small (24B) | dense | ~14 GB (Q4) | Good agentic behaviour, ~3–5× slower per token |
| gpt-oss-20b | MoE, MXFP4 | ~12 GB | Fast, decent general coding, less precise on big refactors |
| Qwen3-32B | dense | ~20 GB | Better reasoning per token, ~10 tok/s — for thinking, not iterating |
| Qwen3.8-27B (hybrid) | dense-ish 27B | ~24 GB (Q6_K) | ~8–9 tok/s plain, **~19 with MTP** — see below |

Why MoE: a 30B-A3B activates ~3B parameters per token, so it runs at dense-7B speeds while
carrying 30B knowledge. On a 256 GB/s memory bus that is the difference between a usable
assistant and a coffee break.

### Hybrid 27B quants are build- and file-sensitive

Qwen3.8-27B (and its 3.6/3.7 siblings) is a hybrid: 65 blocks, only 16 of them full attention,
with Gated DeltaNet/SSM layers between. Three things follow:

- **Use a current build.** Roughly pre-`b10450` builds corrupt output around the DeltaNet
  layers; the quant looks broken and is not.
- **Prefer the `-MTP-` file.** Re-uploaders ship `…-Q6_K.gguf` (23.6 GB) next to
  `…-MTP-Q6_K.gguf` (24 GB) and sometimes `…-LOW-MTP-…`. Only files carrying `blk.64.nextn.*`
  can do speculative decoding, which is worth ~2× decode on a single request
  ([04-llm-stack.md](04-llm-stack.md#speculative-decoding-the-one-flag-that-doubles-a-dense-model)).
- **Context is nearly free.** Decode does not degrade from 16k to 250k on this architecture, so
  size `-c` for the memory it costs, not for speed.

## Chat / general

| Model | Size | Notes |
|---|---|---|
| **Qwen3-30B-A3B-Instruct-2507** | ~18 GB (Q4_K_M) | The everyday Discord model; fast, good prose |
| gpt-oss-20b | ~12 GB | Fits alongside other things; chatty and quick |
| Qwen3-32B | ~20 GB | Slower, better at hard questions |

Use the same weights for Discord and coding if you want one loaded model. Two separate
servers cost two times the RAM; see [04-llm-stack.md](04-llm-stack.md).

## Images

| Model | Size | Use |
|---|---|---|
| SDXL base / Juggernaut XL / RealVisXL | 6–7 GB | Fast iteration, 15–25 s |
| **Flux.1-schnell** (4 steps) | fp16 ~23 GB, GGUF Q8 ~13 GB | Best speed/quality for a bot |
| Flux.1-dev (20 steps) | ~34 GB peak fp16 | Best quality; tight but fits |
| SD 1.5 | ~2 GB | Only if you need speed or old LoRAs |

Avoid fp8 weights on `gfx1151` (no FP8 matmul). Prefer fp16/bf16 or GGUF Q8_0.

## What does not fit

| Model | Why not |
|---|---|
| gpt-oss-120b (~59 GB) | No room for OS + KV cache on 64 GB |
| Llama-3.1/3.3 70B at Q6 | ~53 GB of weights alone |
| 70B dense Q4_K_M + 32k context | ~42 GB weights; technically loadable, but leaves ~2 GB and the loader gets OOM-killed. 8–16k context and no desktop, or don't |
| Mixtral-8x22B | Weights alone exceed the budget |
| Any fp32 model | Twice the size for no benefit here |

## Download

```bash
./scripts/60-download-models.sh --list
./scripts/60-download-models.sh coder-q6       # ~25 GB
./scripts/60-download-models.sh chat-q4        # ~18 GB
./scripts/60-download-models.sh sdxl           # ~7 GB
```

The presets use Hugging Face repo names and `--include` globs, because exact GGUF filenames
change between quant uploads. **Check the file list on the model page before a 25 GB pull** —
`hf download <repo> --include '*Q6_K*'` will fetch what exists and tell you if nothing
matched.

Gated models (Flux.1-dev) need `hf auth login` with a token that has accepted the licence.

## Quantisation cheat sheet

| Quant | Use |
|---|---|
| Q8_0 | When it fits; near-lossless. ~1.06× the fp16 size |
| **Q6_K** | Best quality/size balance for a 30B on 64 GB |
| Q4_K_M / UD-Q4_K_XL | When you want two models loaded or a huge context |
| Q4_K_S / Q3 | Only if you must; noticeable degradation |
| Q5_K | Skip on this chip (dequant instability reported for image models) |
| IQ-quants | Smaller for the same quality but slower on CPU-side dequant paths here |

## Disk planning

| Item | Size |
|---|---|
| OS + tools | ~40 GB |
| llama.cpp builds (ROCm + Vulkan) | ~10 GB |
| ComfyUI venv (torch ROCm is large) | ~15 GB |
| 2 LLM quants | 20–45 GB |
| SDXL checkpoint + Flux GGUF set | 20–40 GB |
| 2 TB drive after all of the above | ~1.8 TB free |

You will not run out of space on 2 TB. You *will* run out of RAM if you get greedy — that is
the only real budget.
