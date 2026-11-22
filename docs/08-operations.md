# 08 — Operations

## Services

Four units, all installed by `scripts/50-install-services.sh`:

| Unit | Port | Depends on |
|---|---|---|
| `llama-server.service` | 127.0.0.1:8080 | `MODEL=` in the env file |
| `llama-router.service` | 127.0.0.1:8080 | every GGUF in `MODELS_DIR`; `Conflicts=` llama-server |
| `comfyui.service` | 127.0.0.1:8188 | `~/ai/comfyui/.venv` |
| `open-webui.service` | 127.0.0.1:3000 until `81-front-door.sh`; then 0.0.0.0:3000 (ufw: Caddy VM only) | `~/ai/openwebui/venv`, `~/ai/data/openwebui` |

```bash
sudo systemctl status llama-server comfyui open-webui
sudo systemctl restart comfyui
journalctl -u llama-server -f
journalctl -u open-webui -n 100 --no-pager
```

All four are `WantedBy=multi-user.target`, so the box comes back as an appliance after a power
cut. `open-webui` deliberately does **not** depend on `llama-server`: it starts fine while the
model is loading, and `llama-server`/`llama-router` conflict with each other.

Configuration lives in environment files, not in the units:

```
~/.config/ai-box/llama-server.env     MODEL=..., HOST, PORT, LLAMA_EXTRA_ARGS=...
~/.config/ai-box/llama-router.env     MODELS_DIR, MODELS_MAX, HOST, PORT, LLAMA_EXTRA_ARGS=...
~/.config/ai-box/comfyui.env          HOST, PORT, COMFY_EXTRA_ARGS=...
~/.config/ai-box/openwebui.env        HOST, PORT, WEBUI_SECRET_KEY, WEBUI_URL, DATA_DIR,
                                      WEBUI_ADMIN_*, ENABLE_IMAGE_GENERATION,
                                      COMFYUI_BASE_URL, COMFYUI_WORKFLOW(_NODES)
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

## Accounts

Open WebUI is the only place identity exists. `50-install-services.sh` writes a generated
`WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD`, and Open WebUI creates that account at startup
while `ENABLE_SIGNUP=false` — no sign-up page and no dependence on the recent first-user
exemption. The password line is deleted from `openwebui.env` once the account exists. Create
people under *Admin → Users*, and grant image generation through a group rather than by making
everyone an admin.

- Lost admin password: there is no CLI reset. Restore `~/ai/data/openwebui/webui.db` from
  backup, or delete the database, put `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` back into
  `openwebui.env`, and restart.
- To remove someone: *Admin → Users → delete*. Their chats go with the account.
- `WEBUI_SECRET_KEY` must not change casually — it invalidates every session.

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
| Open WebUI | 1–2 GB (ordinary RAM) |
| Page cache for model files | whatever is left (good, it speeds reloads) |

Rules:

- **Do not run a Flux fp16 job and a 70B model at the same time.** 30B + SDXL is fine.
  30B + Flux fp16 is tight. Anything + 70B is not.
- If a load fails with `SIGABRT` / OOM-kill, you are in swap, not out of VRAM. Lower the model
  size or the `-c` context; do not raise `ttm.pages_limit`.
- `zram` (Ubuntu default) is the right swap for this box. A large disk swapfile just makes
  the failure slower and weirder.

## Coexistence: images while chatting

ComfyUI and llama.cpp both allocate from the same GTT pool. Open WebUI queues image jobs per
request; it does **not** unload the LLM for you.

- LLM slots: 2 (continuous batching). Image slot: 1 — ComfyUI runs one graph at a time.
- People sharing five accounts share that one queue; expect waits, not failures.
- After each image batch, `POST /free {"unload_models": true, "free_memory": true}` so the
  caching allocator does not hold memory between jobs. This alone fixes a measured ~2.4×
  slowdown on consecutive runs. `scripts/96-comfy-models.sh free` does it from the shell.

## Updates

Order matters: kernel/firmware → ROCm → torch → ComfyUI → Open WebUI → llama.cpp.

```bash
# monthly, roughly
sudo apt update && sudo apt full-upgrade -y
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates && sudo fwupdmgr update
cd ~/ai/llama.cpp && git pull && cmake --build build -j"$(nproc)" && sudo systemctl restart llama-server

# ComfyUI: use ComfyUI-Manager, or
cd ~/ai/comfyui && git pull && . .venv/bin/activate && pip install -r requirements.txt
sudo systemctl restart comfyui

# Open WebUI: stop it first so the SQLite schema is not migrated under a live process
sudo systemctl stop open-webui
sudo -u "$USER" ~/ai/openwebui/venv/bin/pip install --upgrade open-webui
sudo systemctl start open-webui
```

Do **not** blindly `pip install -U torch` in the ComfyUI venv — that is how the
torch/torchvision ABI mismatch happens. Pin with `constraints.txt` once you have a working
set. Read Open WebUI's release notes before a jump: a migration is one-way for the DB.

Keep the previous `llama.cpp` build directory until the new one is benchmarked; a regression
in a nightly is a 20-minute rollback (`git checkout <old-sha>` + rebuild) rather than a
mystery.

## Backups

Worth keeping:

```
~/.config/ai-box/             # service env files, Caddy snippet
~/ai/data/openwebui/          # users, chats, uploaded files, settings
~/ai/comfyui/custom_nodes/    # anything you cloned
~/ai/comfyui/user/            # saved workflows
```

Not worth backing up: GGUF/checkpoints (re-downloadable), venvs, `build/` directories.

```bash
tar czf ~/ai-box-config-$(date +%F).tgz \
  ~/.config/ai-box ~/ai/data/openwebui ~/ai/comfyui/user ./systemd
```

The Open WebUI data directory contains password hashes and per-user history: treat the archive
as a secret (`chmod 600`).

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
- `open-webui` restarting repeatedly → usually a data-directory permission problem
  (`~/ai/data/openwebui` must be owned by the service user) or a failed DB migration.

## Security posture

- **One published surface:** `:3000` (wildcard bind, because Caddy is on another host) → ufw
  allows only the Caddy VM, then Caddy's LAN allowlist, then the Open WebUI login. Nothing else
  leaves the box.
- **ComfyUI has no authentication.** It stays on loopback; the node editor is reached over an
  SSH tunnel. Never add it to the Caddy site.
- **`llama-server` has no authentication either**, and with `--tools` it is remote command
  execution. Keep `--tools` off; Open WebUI draws through ComfyUI without it.
- **`WEBUI_SECRET_KEY` and the Open WebUI DB are secrets.** The DB holds password hashes;
  the env file is `chmod 600`.
- **Per-person accounts, not a shared login.** That is what makes history, permissions and an
  audit trail possible at all.
- No telemetry leaves the box (`ENABLE_VERSION_UPDATE_CHECK=false`).
