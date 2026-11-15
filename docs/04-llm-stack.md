# 04 — LLM stack and the coding assistant

## Why llama.cpp

On `gfx1151` in late 2026, `llama.cpp` is the most predictable path:

- It has both a **HIP/ROCm** backend and a **Vulkan** backend, and you can A/B them on the
  same machine in an hour. On measured 128 GB systems: Vulkan wins token *generation*
  (e.g. Qwen3-Coder-30B-A3B Q6_K at ~75 vs ~61 tok/s), HIP wins *prompt processing*
  (~1250 vs ~1110 tok/s prefill).
- For agentic coding, prefill matters — every tool call and file read re-sends a context.
  That is why this repo defaults to **HIP**, with Vulkan one flag away.
- `llama-server` speaks the OpenAI chat-completions API with SSE streaming, which is what
  every coding tool already knows how to talk to.

Alternatives and where they stand: Ollama (works, less flag control, historically needed
workarounds on this chip — its GPU docs now list the 395), LM Studio (ROCm on Linux works,
mixed model-specific backend bugs reported), vLLM (possible on `gfx1151` but configuration-
specific; not the low-friction choice).

## ROCm

AMD lists `gfx1151` from **ROCm 7.1.1** onward and the Radeon 8060S in current releases.
Two rules:

1. **Do not set `HSA_OVERRIDE_GFX_VERSION`.** Current stacks know `gfx1151` natively. If you
   must, it is `11.5.1` — `11.0.0` (copied from RDNA 3 guides) makes it run the wrong kernels.
2. **Kernel ≥ 6.18.4**, which Ubuntu 26.04 satisfies.

Install the ROCm user-space toolchain (needed for `hipcc`, rocBLAS, hipBLASLt):

```bash
# AMD's repo method; the exact package set changes between releases, check the current
# ROCm install page for your distro if a step 404s.
sudo apt install -y "linux-headers-$(uname -r)"
wget https://repo.radeon.com/amdgpu-install/latest/ubuntu/noble/amdgpu-install_*_all.deb
sudo apt install -y ./amdgpu-install_*_all.deb
sudo amdgpu-install -y --usecase=rocm --no-dkms
sudo usermod -aG render,video "$USER"     # log out and back in
```

Then verify:

```bash
rocminfo | grep -E 'Name:|gfx'      # expect gfx1151
rocm-smi                            # should list the iGPU
hipcc --version
```

Ubuntu 26.04 may need the corresponding `ubuntu` repo path instead of `noble`; the ROCm
compatibility matrix lists 26.04.1 explicitly, so the matching path exists.

## Build llama.cpp

```bash
sudo ./scripts/20-install-llama.sh rocm     # or: vulkan
```

What it does, so you can do it by hand:

```bash
cd ~/ai && git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF \
      -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151
cmake --build build -j"$(nproc)"
```

Vulkan variant: replace `-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151` with `-DGGML_VULKAN=ON`.
Both binaries land in `build/bin/`; the script builds a second tree at `build-vulkan/` if you
ask for Vulkan after ROCm, so you can benchmark both.

Sanity check before serving:

```bash
~/ai/llama.cpp/build/bin/llama-cli -m ~/ai/models/<model>.gguf \
  -ngl 999 -fa on -p "Write a haiku about unified memory." -n 64
```

If it prints tokens at a plausible rate, you are done with the hard part.

## Server flags that matter

```bash
llama-server \
  --model ~/ai/models/Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf \
  --host 127.0.0.1 --port 8080 \
  --ctx-size 32768 \
  --n-gpu-layers 999 \
  --flash-attn on \
  --jinja \
  --parallel 2 \
  --alias coder
```

| Flag | Why |
|---|---|
| `-ngl 999` | Offload everything; check the load log to confirm, don't assume |
| `-fa on` | Flash attention; matters at long context |
| `--jinja` | Required for real tool/function calling — needed by coding agents |
| `-c 32768` | Context. Every doubling costs KV cache RAM; 32k is a sane coding default |
| `-np 2` | Two concurrent slots (the bot's semaphore should match) |
| `--alias` | The model name clients see in `/v1/models` |
| `-ub`/`-b` | Micro-batch; tune for prefill. Try `-b 2048 -ub 512`, lower if allocations fail |
| `--no-mmap` | **Not** a blanket win. Try it only for slow huge-model loads on ROCm |

Loopback only by default. If you want the box reachable from your LAN, put it behind a
reverse proxy with auth rather than binding `0.0.0.0`.

## Wire up the coding tools

All of these take an OpenAI-compatible base URL.

**Claude Code** (via the Anthropic-compatible shim, or use `opencode`/`aider` directly):

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=local            # llama-server ignores the value
```

**opencode** (`~/.config/opencode/opencode.json`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local (ai-box)",
      "options": { "baseURL": "http://127.0.0.1:8080/v1", "apiKey": "local" },
      "models": { "coder": { "name": "Qwen3-Coder-30B-A3B" } }
    }
  }
}
```

**Continue** (`~/.continue/config.yaml`):

```yaml
models:
  - name: ai-box
    provider: openai
    model: coder
    apiBase: http://127.0.0.1:8080/v1
    apiKey: local
```

**Aider**:

```bash
aider --openai-api-base http://127.0.0.1:8080/v1 --openai-api-key local \
      --model openai/coder
```

**Cline / Roo** (VS Code): provider "OpenAI Compatible", base URL
`http://127.0.0.1:8080/v1`, model `coder`.

**Open WebUI** for a browser chat UI (optional, Docker Engine not Desktop):

```bash
docker run -d --name open-webui -p 3000:8080 \
  -e OPENAI_API_BASE_URL=http://host.docker.internal:8080/v1 \
  -e OPENAI_API_KEY=local -v open-webui:/app/backend/data \
  --add-host=host.docker.internal:host-gateway --restart unless-stopped \
  ghcr.io/open-webui/open-webui:main
```

## Practical expectations

A 30B-A3B MoE at Q6_K is the sweet spot: ~25 GB of weights, ~60–75 tok/s decode, and enough
quality for real editing work. Dense models of the same size are 3–5× slower for the same
quality — on this hardware, **MoE wins**.

Long agentic sessions are limited by context, not speed: at 32k context, a big refactor will
push against the window. Raise `-c` only after checking free RAM.

## Multiple models

`llama-server` loads one model. Options, in increasing order of effort:

1. Several unit files (`llama-server@coder.service`, `@chat.service`) on different ports —
   memory permitting, one at a time via `systemctl stop`/`start`.
2. [`llama-swap`](https://github.com/mostlygeek/llama-swap) in front of them: one endpoint,
   swaps the loaded model on demand. This is the good answer if you switch models often.
3. Separate machines. You have one.

See [07-models.md](07-models.md) for what to actually download.
