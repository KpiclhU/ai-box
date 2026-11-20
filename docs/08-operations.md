# 08 — Operations

## Services

Four units, all installed by `scripts/50-install-services.sh`:

| Unit | Port | Depends on |
|---|---|---|
| `llama-server.service` | 127.0.0.1:8080 | `MODEL=` in the env file |
| `llama-router.service` | 127.0.0.1:8080 | every GGUF in `MODELS_DIR`; `Conflicts=` llama-server |
| `comfyui.service` | 127.0.0.1:8188 | `~/ai/comfyui/.venv` |
| `ai-discord-bot.service` | — | both of the above, `./.env` |

```bash
sudo systemctl status llama-server comfyui ai-discord-bot
sudo systemctl restart comfyui
journalctl -u llama-server -f
journalctl -u ai-discord-bot -n 100 --no-pager
```

The LLM and ComfyUI units are `WantedBy=multi-user.target`, so the box comes back as an
appliance after a power cut. The bot unit has `After=` and `Wants=` on both, plus
`Restart=always` with a 5 s delay so a Discord outage does not leave it dead.

Configuration lives in environment files, not in the units:

```
~/.config/ai-box/llama-server.env     MODEL=..., HOST, PORT, LLAMA_EXTRA_ARGS=...
~/.config/ai-box/llama-router.env     MODELS_DIR, MODELS_MAX, HOST, PORT, LLAMA_EXTRA_ARGS=...
~/.config/ai-box/comfyui.env          HOST, PORT, COMFY_EXTRA_ARGS=...
./.env                                DISCORD_TOKEN, LLM_*, COMFY_*
```

To change models, edit `MODEL=` (an absolute path, no spaces) and
`systemctl restart llama-server`. `LLAMA_EXTRA_ARGS` is split on whitespace by systemd,
so it is the place for flags like `--ctx-size` and `--parallel`. Keep such values quoted
(`LLAMA_EXTRA_ARGS="--ctx-size 32768 ..."`, as the installer writes them): systemd strips
the quotes, while a shell that reads the file — `./scripts/90-bench.sh` used to source it —
would otherwise try to run `32768` as a command. Note that systemd does
**not** expand variables inside `EnvironmentFile` values — only `${VAR}` references in the
unit's `ExecStart` are expanded, which is why `MODEL` is referenced there.

Editing a unit file means editing `systemd/*.service` in the repo and re-running the install
script, so the repo stays the source of truth.

## Power profile

Default `balanced` caps the APU at ~100 W sustained. For inference:

```bash
sudo apt install -y power-profiles-daemon
powerprofilesctl set performance      # 140 W boost / 120 W sustained
powerprofilesctl get
```

`performance` is worth roughly 15–20 % on sustained loads. It is also louder. On a box that
sits in a room you work in, `balanced` is a defensible choice.

## Memory budget discipline

The machine has 64 GB total. Everything shares it:

| Consumer | Typical |
|---|---|
| OS + desktop + browser | 4–8 GB |
| `llama-server` with a 30B Q6_K at 32k | 25 GB weights + 4–6 GB KV/compute |
| ComfyUI idle | ~2 GB |
| ComfyUI running Flux fp16 | 30–34 GB peak |
| Page cache for model files | whatever is left (good, it speeds reloads) |

Rules:

- **Do not run a Flux fp16 job and a 70B model at the same time.** 30B + SDXL is fine.
  30B + Flux fp16 is tight. Anything + 70B is not.
- If a load fails with `SIGABRT` / OOM-kill, you are in swap, not out of VRAM. Lower the model
  size or the `-c` context; do not raise `ttm.pages_limit`.
- `zram` (Ubuntu default) is the right swap for this box. A large disk swapfile just makes
  the failure slower and weirder.

## Coexistence: images while chatting

ComfyUI and llama.cpp both allocate from the same GTT pool. They will share, badly, if you
let them. Practical policy, which the bot implements:

- LLM slots: 2 (continuous batching). Image slot: 1.
- Image jobs get queued, with a message saying so.
- After each image batch, `POST /free {"unload_models": true, "free_memory": true}` so the
  caching allocator does not hold memory between jobs. This alone fixes a measured ~2.4×
  slowdown on consecutive runs.

## Updates

Order matters: kernel/firmware → ROCm → torch → ComfyUI → llama.cpp.

```bash
# monthly, roughly
sudo apt update && sudo apt full-upgrade -y
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update
cd ~/ai/llama.cpp && git pull && cmake --build build -j"$(nproc)" && sudo systemctl restart llama-server

# ComfyUI: use ComfyUI-Manager, or
cd ~/ai/comfyui && git pull && . .venv/bin/activate && pip install -r requirements.txt
sudo systemctl restart comfyui
```

Do **not** blindly `pip install -U torch` in the ComfyUI venv — that is how the
torch/torchvision ABI mismatch happens. Pin with `constraints.txt` once you have a working
set.

Keep the previous `llama.cpp` build directory until the new one is benchmarked; a regression
in a nightly is a 20-minute rollback (`git checkout <old-sha>` + rebuild) rather than a
mystery.

## Backups

Worth keeping:

```
~/.config/ai-box/          # service env files
./.env                     # Discord token — treat as a secret
~/ai/data/bot.sqlite3      # conversation history
~/ai/comfyui/custom_nodes/ # anything you cloned
~/ai/comfyui/user/         # saved workflows
```

Not worth backing up: GGUF/checkpoints (re-downloadable), venvs, `build/` directories.

```bash
tar czf ~/ai-box-config-$(date +%F).tgz \
  ~/.config/ai-box ~/ai/data ~/ai/comfyui/user \
  ./.env ./systemd
```

## Monitoring

```bash
amdgpu_top                      # GTT/VRAM per process, GPU clocks
nvitop                          # no dGPU, mostly useless — use amdgpu_top
sensors                         # package temp
watch -n1 'curl -s localhost:8080/health; echo; curl -s localhost:8188/queue | jq ".queue_running|length"'
```

Things that indicate trouble before they indicate failure:

- Decode rate falling over a long session → context is huge; KV cache is spilling or the
  allocator is fragmenting. Restart the server.
- `amdgpu_top` showing GTT at 100 % with the model still loading → not enough `pages_limit`
  for that model + context.
- GPU at 100 % but no progress and no log output → the IRQ-stall bug; see
  [09-troubleshooting.md](09-troubleshooting.md).

## Security posture

- All services bind **loopback**. The only inbound path is the bot's outbound websocket to
  Discord.
- The Discord token is a secret: it is in `.env` (gitignored), never in a unit file.
- Anyone in the Discord server can burn your GPU time. If the server is not private, gate the
  bot's commands behind a role check (`bot.py` has a `ALLOWED_ROLE` hook).
- No telemetry leaves the box. Your prompts go to Discord and nowhere else.
