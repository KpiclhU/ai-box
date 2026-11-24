# 08 — Operations

## Services

Three units, all installed by `scripts/50-install-services.sh`:

| Unit | Port | Depends on |
|---|---|---|
| `llama-server.service` | loopback, then `0.0.0.0:8080` behind the ufw subnet rule | `MODEL=` in the env file |
| `llama-router.service` | the same port — the two are alternatives | every GGUF in `MODELS_DIR`; `Conflicts=` llama-server |
| `comfyui.service` | loopback, then `0.0.0.0:8188` behind the same rule | `~/ai/comfyui/.venv` |

The `0.0.0.0` half is `scripts/80-lan-access.sh`, which puts the firewall rule in first and
only then moves the bind. Until it has run, both services are loopback-only and a client on
another machine gets nothing — that is the default, not a fault.

```bash
sudo systemctl status llama-server comfyui
sudo systemctl restart comfyui
journalctl -u llama-server -f
journalctl -u comfyui -n 100 --no-pager
```

All three are `WantedBy=multi-user.target`, so the box comes back as an appliance after a power
cut. `llama-server` and `llama-router` conflict with each other on purpose: one port, one
process.

Configuration lives in environment files, not in the units:

```
~/.config/ai-box/llama-server.env     MODEL=..., HOST, PORT, LLAMA_EXTRA_ARGS=...
~/.config/ai-box/llama-router.env     MODELS_DIR, MODELS_MAX, HOST, PORT, LLAMA_EXTRA_ARGS=...
~/.config/ai-box/comfyui.env          HOST, PORT, COMFY_EXTRA_ARGS=...
```

To change models, edit `MODEL=` (an absolute path, no spaces) and
`systemctl restart llama-server`. `LLAMA_EXTRA_ARGS` is split on whitespace by systemd,
so it is the place for flags like `--ctx-size` and `--parallel`. Keep such values quoted
(`LLAMA_EXTRA_ARGS="--ctx-size 131072 ..."`, as the installer writes them): systemd strips
the quotes, while a shell that reads the file — `./scripts/90-bench.sh` used to source it —
would otherwise try to run `131072` as a command. Note that systemd does
**not** expand variables inside `EnvironmentFile` values — only `${VAR}` references in the
unit's `ExecStart` are expanded, which is why `MODEL` is referenced there.

Editing a unit file means editing `systemd/*.service` in the repo and re-running the install
script, so the repo stays the source of truth.

## Access

Nothing on this box has accounts. `llama-server` and ComfyUI are raw HTTP APIs, and the only
thing between them and the network is `ufw allow from 192.168.150.0/24`:

- Everyone on that subnet can use the model and drive ComfyUI — including a guest who joins
  the Wi-Fi. That is the trade for having no login to maintain. Keep the guest network on a
  different subnet, or accept it.
- **Never port-forward 8080 or 8188** on the router. The subnet rule is the whole control.
- `--tools` on `llama-server` turns "use the model" into "run commands as the service user" for
  every one of those clients. Leave it off unless that is what you want.
- Rotating access means changing the subnet argument, not a password:
  `sudo ./scripts/80-lan-access.sh --revert`, edit `ufw allow from …`, re-run.
- Chat history, per-person accounts and the image workspace belong to the Open WebUI on the
  `ai-box-docker` VM, which reaches this box over the LAN like any other client.

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
| OS + services (no desktop) | 4–8 GB |
| `llama-server` with a 30B Q6_K at 64k/slot (131072 total) | 25 GB weights + 6 GB KV + ~2 GB compute |
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

ComfyUI and llama.cpp both allocate from the same GTT pool, and nothing coordinates them: a
chat client queuing an image job does not unload the LLM for you.

- LLM slots: 2 (continuous batching). Image slot: 1 — ComfyUI runs one graph at a time.
- Every client shares that one ComfyUI queue; expect waits, not failures.
- After each image batch, `POST /free {"unload_models": true, "free_memory": true}` so the
  caching allocator does not hold memory between jobs. This alone fixes a measured ~2.4×
  slowdown on consecutive runs. `scripts/96-comfy-models.sh free` does it from the shell.

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
~/.config/ai-box/             # service env files
~/ai/comfyui/custom_nodes/    # anything you cloned
~/ai/comfyui/user/            # saved workflows
~/ai/comfyui/output/          # generated images, if you care about them
```

Not worth backing up: GGUF/checkpoints (re-downloadable), venvs, `build/` directories.

```bash
tar czf ~/ai-box-config-$(date +%F).tgz \
  ~/.config/ai-box ~/ai/comfyui/user ./systemd
```

## Monitoring

```bash
amdgpu_top                      # GTT/VRAM per process, GPU clocks
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

- **The subnet is the boundary.** Two ports, `8080` and `8188`, `allow from
  192.168.150.0/24`, incoming denied by default, and nothing port-forwarded upstream.
- **Neither service has authentication.** Not a missing feature — fits the same sentence as
  above, and the reason `80-lan-access.sh` refuses to bind before the firewall covers it.
- **`--tools` is remote command execution** for anyone on the subnet. Off by default; keep it
  that way.
- **The services run as your user.** Anything that reaches them reaches that account's files
  only through a llama.cpp tool, so with `--tools` off the exposure is compute, not the disk.
- No telemetry leaves the box.
