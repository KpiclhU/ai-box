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
# AMD's repo method. The path segment is your distro codename, not "latest":
#   jammy = 22.04, noble = 24.04, resolute = 26.04
sudo apt install -y "linux-headers-$(uname -r)"
codename=$(. /etc/os-release; echo "$VERSION_CODENAME")
url=https://repo.radeon.com/amdgpu-install/latest/ubuntu/$codename
file=$(wget -qO- "$url/" | grep -o 'amdgpu-install_[0-9.]*-1_all\.deb' | head -1)
wget "$url/$file"
sudo apt install -y "./$file"
sudo amdgpu-install -y --usecase=rocm --no-dkms
sudo usermod -aG render,video "$(id -un)"     # log out and back in
```

Then verify:

```bash
rocminfo | grep -E 'Name:|gfx'      # expect gfx1151
rocm-smi                            # should list the iGPU
hipcc --version
```

Two things produce a `404` here, and most guides get both wrong:

- **The codename.** Ubuntu 26.04 is `resolute`. Copy-pasted instructions say `noble`
  (24.04) — that path exists, but it is the wrong release's packages.
- **`wget` does not expand wildcards.** `wget .../amdgpu-install_*_all.deb` fetches a literal
  `*` and 404s even on a correct path. Read the actual filename out of the listing, as above.

Check what is published at any time:

```bash
wget -qO- https://repo.radeon.com/amdgpu-install/latest/ubuntu/   # jammy/ noble/ resolute/
```

The compatibility matrix lists Ubuntu 26.04.1 with kernel 7.0 for `gfx1151` explicitly, under
current ROCm (10.x) as well as under the 7.x releases the PyTorch wheels use.

### ROCm 10.x split the layout

10.x puts the real tree in `/opt/rocm/core-<ver>/` and exposes `/opt/rocm/{bin,lib,llvm}` as
`update-alternatives`. So a build can fail like this:

```text
The ROCm root directory: /opt/rocm/core-10.2/lib/llvm/bin/../../..
does not contain the HIP runtime CMake package
```

That path is **correct**. The error means `hip-lang-config.cmake` is missing, and in 10.x it
ships in a development package separate from the runtime — `amdgpu-install --usecase=rocm`
does not always pull it:

```bash
apt-cache search '^amdrocm' | grep -E 'dev|devel'
sudo apt install amdrocm-core-dev10.2-gfx1151     # exact name/version from the search
ls /opt/rocm/core-10.2/lib/cmake/hip-lang/hip-lang-config.cmake
```

When both the runtime and the dev package are present, `/opt/rocm` itself is usually fine
(`hipconfig -R` reports the root). If an older ROCm is still installed, check that the
alternatives actually point at 10.x with `update-alternatives --display rocm-lib`, and pin the
root explicitly when building:

```bash
export ROCM_PATH=/opt/rocm/core-10.2 HIP_PATH=/opt/rocm/core-10.2
./scripts/20-install-llama.sh rocm     # detects core-<ver> and passes the root to CMake
```

This ROCm install is only needed for the **HIP `llama.cpp` build** (and for `rocminfo` /
`rocm-smi`). ComfyUI does not need it: the PyTorch `rocm7.2` wheels carry their own ROCm
user-space libraries and only want the kernel driver plus `/dev/kfd`. So if the ROCm repo is
fighting you on 26.04, `./scripts/20-install-llama.sh vulkan` plus a normal ComfyUI install
gives you a working box with no `amdgpu-install` at all — at the cost of some prefill speed.

## Build llama.cpp

```bash
./scripts/20-install-llama.sh rocm          # or: vulkan — no sudo, it builds into your home
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
  --ctx-size 131072 \
  --cache-type-k q8_0 --cache-type-v q8_0 \
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
| `-c 131072` | **Total** context for all slots — the window per request is this ÷ `-np` (below) |
| `-np 2` | Two concurrent slots, so 131072 / 2 = **64k per request** |
| `--cache-type-k/-v q8_0` | Halves the KV cache, which is what a big context actually costs. Needs `-fa on` |
| `--alias` | The model name clients see in `/v1/models` |
| `-ub`/`-b` | Micro-batch; tune for prefill. Try `-b 2048 -ub 512`, lower if allocations fail |
| `--no-mmap` | **Not** a blanket win. Try it only for slow huge-model loads on ROCm |

## `--ctx-size` is a total, not a per-request window

The one thing that surprises everybody on this box: `--ctx-size 32768 --parallel 2` does
**not** give two 32k conversations. llama.cpp allocates one KV cache of `--ctx-size` tokens
and splits it across the slots, so each request gets **16k** — and an agentic session (system
prompt + tool schemas + a few file reads) fills that in a handful of turns and starts
compacting or failing.

```text
window per request = --ctx-size / --parallel
```

Either raise the total or lower `--parallel`. Check what you actually got, once a model is
loaded — these report the **per-slot** window, not the flag:

```bash
curl -s localhost:8080/props | jq '.default_generation_settings.n_ctx'
curl -s localhost:8080/slots | jq '.[].n_ctx'
journalctl -u llama-router -n 200 --no-pager | grep -E 'n_ctx|KV self size'
```

KV cache is the only thing stopping you going higher. For a 30B-A3B that is 96 KiB/token at
f16, 48 KiB at `q8_0`:

| `--ctx-size` | window @ `-np 2` | KV f16 | KV q8_0 |
|---|---|---|---|
| 32768 | 16384 | 3 GB | 1.5 GB |
| 65536 | 32768 | 6 GB | 3 GB |
| **131072** | **65536** | 12 GB | **6 GB** |
| 262144 | 131072 | 24 GB | 12 GB |

`131072` is the repo default: 64k per request with two slots, and still inside the ~48 GiB
pool next to a 25 GB model and a 38 GB one. You can go to `262144` with `q8_0` KV on a 25 GB
model; you cannot next to Flux. Go **down** before you touch `ttm.pages_limit`.

Loopback only by default. If you want the box reachable from your LAN, put it behind a
reverse proxy with auth rather than binding `0.0.0.0`.

## Speculative decoding: the one flag that doubles a dense model

Decode is bandwidth bound: roughly 220 GB/s divided by the bytes of weights read per token.
A 27B at Q6_K is 24 GB, so **~9 tok/s is the ceiling**, not a misconfiguration — unified
memory has no toggle to turn on. What is often switched off is the model's own draft head.

Some Qwen3.8-27B GGUFs carry a **NextN / MTP head** — one extra block stored as
`blk.64.nextn.*` (`qwen35.nextn_predict_layers = 1` in the metadata). It guesses the next few
tokens so the full model can verify 3–4 of them in a single weight read. No second model, no
visible quality change: rejected guesses cost time, never correctness.

Check both halves before you bother:

```bash
head -c 64000000 ~/ai/models/model.gguf | strings -n 8 | grep -c nextn   # >0: head present
~/ai/llama.cpp/build/bin/llama-server --help | grep -c spec-type         # >0: build supports it
```

Then add the flags to `LLAMA_EXTRA_ARGS` and restart:

```bash
# ~/.config/ai-box/llama-server.env
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --alias local --spec-type draft-mtp --spec-draft-n-max 3"
```

Measured on `gfx1151`, single request, Qwen3.8-27B Q6 (~24 GB):

| Mode | decode | draft acceptance |
|---|---|---|
| plain | 8.4 tok/s | — |
| `--spec-type draft-mtp --spec-draft-n-max 3` | **18.7 tok/s** | 65 % |

Four caveats:

- **Version.** MTP landed in mid-2026; older builds do not have `--spec-type` at all. The
  hybrid Qwen3.8 family also wants a build from about `b10450` on, because earlier ones
  produced corrupted output around the Gated DeltaNet layers.
- **Prefill pays ~4–8 %** for the extra head, and it costs a fraction of a GB of GTT.
- **`n=3` is the sweet spot here.** `n=4` has been reported to halve throughput at unchanged
  acceptance on this chip. Do not raise it without measuring.
- **It only wins while the GPU is idle.** Each additional concurrent request reuses the same
  weight read, so plain throughput keeps climbing while MTP's stays flat: at four parallel
  requests MTP is ~22 % *slower*. Interactive use with `--parallel 2` is the good case.

If the file has no `nextn` tensors there is nothing to draft from: `llama-server` warns
`model doesn't contain MTP layers` and exits at load, so gate the flag on the check above.
That is the difference between a repo's `-MTP-` and plain files, which are often only a few
hundred MB apart ([07-models.md](07-models.md)).

Put these flags in `llama-server.env`, not `llama-router.env`: the router passes its
`LLAMA_EXTRA_ARGS` to **every** model it can load, so one MTP-less GGUF in `MODELS_DIR` would
take the whole router down.

## Wire up the coding tools

### Where the editor runs

On a Server install there is no desktop on the box, so the editor (VS Code, Claude Code,
opencode, Aider) runs on your laptop while the model runs on the ai-box. Keep the services on
loopback and forward the ports over SSH:

```bash
ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 ai@ai-box
```

Leave that running. `http://127.0.0.1:8080/v1` below then means "port 8080 on the ai-box",
and `http://127.0.0.1:8188` is ComfyUI in your laptop's browser. This is also why nothing
binds `0.0.0.0`: there is no port to expose and no auth to get wrong. If you installed the
Desktop edition and work at the console, skip the tunnel and use the addresses directly.

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

Long agentic sessions are limited by the per-request window, not by speed. At the default
(`--ctx-size 131072 --parallel 2`) each request gets 64k; `--parallel 1` turns the same
allocation into a single 128k request, at the cost of the bot's second slot. Raise the total
only after checking free GTT — the table above says exactly what it costs.

## Multiple models

`llama-server` loads one model. Options, in increasing order of effort:

1. Several unit files (`llama-server@coder.service`, `@chat.service`) on different ports —
   memory permitting, one at a time via `systemctl stop`/`start`.
2. [`llama-swap`](https://github.com/mostlygeek/llama-swap) in front of them: one endpoint,
   swaps the loaded model on demand. This is the good answer if you switch models often.
3. Separate machines. You have one.

See [07-models.md](07-models.md) for what to actually download.
