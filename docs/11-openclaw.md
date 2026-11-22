# 11 — OpenClaw: chat from anywhere

Everything in [00](00-workflow.md) through [10](10-webui-and-models.md) reaches the model from
something *you* operate: an editor, a browser through a tunnel, a Discord slash command. This
page adds the other half — a gateway that keeps a persistent connection to a messaging app and
turns a message into an agent turn against the model already running on this box.

OpenClaw is that gateway: a Node process, MIT licensed, self-hosted, which bridges Telegram,
Discord, Slack, WhatsApp, Signal, Matrix, Teams and others to an AI agent. It is **not** a
second model and not a second copy of llama.cpp. It speaks HTTP to `127.0.0.1:8080/v1` exactly
like `bot/` does, so the model, the context window and the memory budget from
[04](04-llm-stack.md) and [07](07-models.md) all still apply unchanged.

| | What it is here |
|---|---|
| Adds | one Node process on `127.0.0.1:18789`, plus a chat channel |
| Costs | a few hundred MB of RAM, no GPU, no second GGUF, no extra model load |
| Talks to | `http://127.0.0.1:8080/v1` — the same endpoint your editor uses |
| Does not replace | `llama-server`/`llama-router`, ComfyUI, or `ai-discord-bot` |
| Changes | nothing in `~/ai`; its state lives in `~/.openclaw` |

The reason this belongs on this box rather than on a laptop: the box is already on 24/7 with
the model resident, which is the one thing a chat bridge needs and a laptop cannot provide.
The hardware is otherwise irrelevant to OpenClaw — it never touches `gfx1151`, and it does not
care that there is no discrete GPU.

---

## What it costs

- **RAM.** One Node gateway process — hundreds of megabytes, not gigabytes. On a box with
  ~12–14 GB outside the GTT pool ([03](03-gpu-memory.md)) it is noise.
- **CPU.** Idle is effectively nothing (long-polling and WebSockets). A turn costs what a turn
  costs in [04](04-llm-stack.md), because the prompt processing happens on `llama-server`.
- **Disk.** The npm package plus `~/.openclaw` (sessions, memory, channel credentials, logs).
  Plan on a few GB of the 2 TB, dominated by session history, not by code.
- **A port.** `18789`, loopback, separate from `8080` and `8188`.
- **Nothing on the GPU.** Do not expect a second set of weights to appear: it never loads one.

That last point is the design decision worth stating plainly. OpenClaw *can* install and run
its own managed llama.cpp server ("Managed local server" in onboarding). **Do not use that
here.** This box already has a tuned `llama-server` with a 131072-token context, q8_0 KV cache
and `--alias local`; a second server would download its own GGUF and compete for the same
48 GiB of GTT. Choose **Existing llama-server** and point it at `127.0.0.1:8080`.

---

## Install (20 min)

OpenClaw needs **Node 24.16+ on 24.x, or 26.1+** (26.12.1+/24.22.1+ recommended — those are
the security-patched lines). Ubuntu 26.04's packaged Node may be older than that; the official
installer provisions Node on Linux when it is missing.

Two supported paths:

```bash
# 1. Official installer: provisions Node if needed, then runs onboarding.
curl -fsSL https://openclaw.ai/install.sh | bash
#    or, without onboarding:
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
```

```bash
# 2. You already manage Node: this is what scripts/60-install-openclaw.sh does.
npm install -g openclaw@latest --allow-scripts=openclaw
openclaw --version
openclaw doctor
```

The npm flag is not optional decoration. npm 12 blocks package lifecycle scripts by default and
reports them as `blocked because they are not covered by allowScripts`; `--allow-scripts=openclaw`
is the documented opt-in. On npm 11.15 and earlier the flag does not exist and must be omitted
(11.16+ accepts it). `npm approve-scripts openclaw` does **not** work for a global install, so it
has to be on the install command. `60-install-openclaw.sh` reads your npm version and picks the
right form.

```bash
./scripts/60-install-openclaw.sh          # install + write the provider patch, print the rest
./scripts/60-install-openclaw.sh --check  # report only, change nothing
```

The script does not sudo. If npm's global prefix is root-owned it prints the `sudo npm install …`
line and stops, which is the same posture as the rest of this repo: three scripts need root, and
this is not one of them.

If `openclaw` is not found afterwards, it is almost always PATH: `npm prefix -g` prints the
prefix, and its `bin` directory has to be on your `PATH`. The systemd unit below sets it
explicitly, because systemd's default `PATH` is `/usr/bin:/bin` — the same trap that makes MCP
servers in [10](10-webui-and-models.md#connectors-mcp-tools) need absolute paths.

---

## Point it at llama-server

The model has a different id depending on which unit owns `:8080`:

| Unit on `:8080` | Model id OpenClaw must use | Where it comes from |
|---|---|---|
| `llama-server` (default) | `local` | `--alias local` in `~/.config/ai-box/llama-server.env` |
| `llama-router` | the `.gguf` file name | `MODELS_DIR` listing, e.g. `Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf` |

Ask the server rather than guessing:

```bash
curl -s localhost:8080/v1/models | jq -r '.data[].id'
curl -s localhost:8080/health                  # {"status":"ok"} once the model has loaded
```

OpenClaw's discovery reads `/health`, `/models` (falling back to `/v1/models`) and `/props`.
**HTTP 503 means the model is still loading**, not that the address is wrong — wait for
`ok` before onboarding, or discovery records an empty inventory.

With that, onboarding:

```bash
openclaw onboard        # choose "Existing llama-server", enter http://127.0.0.1:8080/v1
```

The wizard is the recommended path because it verifies discovery and saves the context and
tool-support facts it can prove from live `/props`:

```bash
# the same thing, non-interactive
openclaw onboard --non-interactive --accept-risk --skip-health \
  --auth-choice llama-cpp-existing-server \
  --custom-base-url http://127.0.0.1:8080/v1 \
  --custom-model-id local

openclaw models set llama-cpp/local
openclaw models list --provider llama-cpp
```

No API key: this server does not want one (`HOST=127.0.0.1`, no `--api-key` in
`LLAMA_EXTRA_ARGS`). If you ever add `--api-key` to the unit, add `--llama-server-api-key`
here and keep the value in `~/.openclaw/.env`, not in a repo file.

### Two settings that are wrong by default on this box

The wizard gets you connected; these two it cannot know. `60-install-openclaw.sh` writes the
patch file, and you apply it while the gateway is stopped:

```bash
openclaw config patch --file ~/.config/ai-box/openclaw-provider.patch.json5
```

```json5
{
  models: {
    mode: "merge",
    providers: {
      "llama-cpp": {
        baseUrl: "http://127.0.0.1:8080/v1",
        api: "openai-completions",
        request: { allowPrivateNetwork: true },
        timeoutSeconds: 300,
        models: [
          {
            id: "local",
            name: "ai-box llama-server",
            reasoning: false,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 65536,
            maxTokens: 8192,
          },
        ],
      },
    },
  },
}
```

- **`contextWindow: 65536`, not 128000.** `LLAMA_EXTRA_ARGS` runs `--ctx-size 131072` with
  `--parallel 2`, which is a **64k window per request** ([00](00-workflow.md#4-services--llama-server-5-min)
  checks this with `/props`). When discovery cannot prove a window, OpenClaw falls back to
  128,000 and will assemble prompts this server cannot hold — the symptoms are truncated
  replies, or a one-token answer near the limit. If you raise `--ctx-size` or drop
  `--parallel`, change this number with it.
- **`timeoutSeconds: 300`.** Prefill here is ~1.1–1.25k tok/s ([04](04-llm-stack.md#practical-expectations)).
  A 20k-token system prompt plus tool schemas is roughly 20 s before the first token, and an
  agent turn makes several requests. The default is tuned for hosted APIs. Raise
  `agents.defaults.timeoutSeconds` too if a turn still dies: a provider timeout cannot extend
  the run's own budget.

Arrays replace on `config patch`, so list every model you want in that one file. `mode: "merge"`
keeps OpenClaw's built-in provider catalog alongside this one, which is what you want if you
ever add a hosted fallback.

---

## Run it as a service, like everything else

```bash
sudo ./scripts/50-install-services.sh          # renders openclaw-gateway.service + openclaw.env
systemctl status openclaw-gateway --no-pager
journalctl -u openclaw-gateway -f
```

`50-install-services.sh` writes `~/.config/ai-box/openclaw.env` with `PORT=18789` and a generated
`OPENCLAW_GATEWAY_TOKEN`, substitutes the resolved path to the `openclaw` binary, and only
enables the unit once `~/.openclaw/openclaw.json` exists — before onboarding there is nothing to
run.

**Skip `openclaw onboard --install-daemon` and `openclaw gateway install` on this box.** They
write a systemd *user* unit, which on a headless install needs a lingering session to survive
logout (`loginctl enable-linger`). The repo's own unit is a system unit with `User=ai-user`,
starts at boot, and matches how `llama-server`, `comfyui` and the bot are managed. Two units
would also fight over port 18789.

The unit depends on the network, not on `llama-server`, deliberately: `Wants=llama-server` would
start the single-model unit on a box that runs `llama-router` instead, and those two `Conflicts=`
each other. A message sent while the model is loading fails that turn and works on the next one.

---

## Reaching it from anywhere

Same three doors as [10](10-webui-and-models.md#access-from-the-lan), same reasoning: the
gateway is loopback-only by default, and everything else is a deliberate exception.

| Door | How | Auth |
|---|---|---|
| **SSH tunnel** (default) | `ssh -N -L 18789:127.0.0.1:18789 ai-user@ai-box`, open `http://127.0.0.1:18789` | gateway token from `openclaw.env` |
| **Tailscale Serve** | `openclaw gateway --tailscale serve`, open `https://<magicdns>/` | tailnet identity, with `gateway.auth.allowTailscale: true` |
| **A chat channel** | message the bot from your phone | per channel |

**The third row is the one you actually want.** You do not need to reach the Control UI from
anywhere to use the agent from anywhere — the point of a chat bridge is that the phone app you
already have is the client, and no inbound port is opened on this box.

- **Telegram is the least friction on a headless box.** Long polling: no webhook, no DNS, no
  certificate, no open port. `openclaw channels add --channel telegram`, token from @BotFather.
- **Discord needs care because this box already has a bot.** `ai-discord-bot.service` holds one
  token and answers `/chat` and `/image`. Two gateways on the same application token reply
  twice to everything. Either register a **separate** Discord application for OpenClaw and keep
  them in different channels, or move the use case to OpenClaw and
  `sudo systemctl disable --now ai-discord-bot`. They are alternative front ends for the same
  model, not complementary ones.
- **Slack/Matrix/Teams** are token or homeserver config, no inbound ports. **WhatsApp/Signal**
  need device pairing — the QR or linking code wants a terminal and a phone at the same time,
  which is fine over SSH.
- **iMessage cannot run here.** It needs macOS; the option is a paired Mac acting as a node.

If you must expose the Control UI itself, keep the loopback bind and put something
identity-aware in front: Tailscale Serve, or Cloudflare Tunnel + Access with
`gateway.auth.mode: "trusted-proxy"`. A `lan`/`tailnet` bind requires
`gateway.auth.token` or `gateway.auth.password`; a public host must use `wss://`, not `ws://`.
**Do not port-forward 18789** — the same rule as 8080 and 8188, for a stronger reason below.

---

## Security: this is an agent, not a chat UI

This is the largest difference from everything else in this repo, and it is the section to read
before the first channel is connected.

The Discord bot in `bot/` can chat and draw. **OpenClaw can read files, run commands and use
tools as `ai-user`, triggered by a message anyone in a channel can send.** It is the same
hazard [10](10-webui-and-models.md#server-tools-files-shell-and-the-internet) describes for
`--tools all` and MCP, with a friendlier front door and more capability behind it.

- **Pairing and allowlists first.** Keep DMs off unless you need them, keep
  `groupPolicy`/`requireMention` tight, and connect the agent to a channel with the people you
  would give a shell on this box — not a public server.
- **Approvals are the control, not the sandbox.** OpenClaw's sandboxing is off by default; exec
  approvals and per-agent allowlists are what bound the damage. This repo already leans on this
  idea with llama.cpp's tools; OpenClaw's surface is larger.
- **Prompt injection is the real risk.** Any web page it fetches, any file it reads, is
  attacker-controlled text that can ask for another command. A chat channel makes that text
  arrive from a person.
- **It inherits `ai-user`.** SSH keys, `~/ai-box/.env` (the Discord token), the ComfyUI venv,
  and the ability to stop services. Separate OS users for separate trust boundaries; never one
  gateway shared between people who do not trust each other.
- **`~/.openclaw` holds credentials.** Channel tokens, sessions and memory. `chmod 700`, keep it
  out of any repo, and back it up like `~/ai/data/bot.sqlite3` in
  [08](08-operations.md#backups).
- **Keep `HOST=127.0.0.1` in `llama-server.env`.** OpenClaw reaches the model over loopback; the
  model port never needs to leave the box for this to work.

---

## Images, and the memory budget

No image plugin is needed. The agent can run this repo's own script through its shell tool:

```bash
~/ai-box/scripts/97-comfy-gen.sh "a corgi astronaut, cinematic lighting"
```

It prints the PNG path, so the reply carries a real file the same way `/image` does in
[06](06-discord-bot.md). Same rule as everywhere else in this repo ([10](10-webui-and-models.md#comfyui-let-the-router-draw)):
SDXL (~10 GB) fits beside a 25 GB model in the 48 GiB pool; Flux.1-dev (~34 GB) does not, so
unload the model first (`POST /models/unload`) or let SDXL be the default.

The budget with OpenClaw running, all of it on this one machine:

| Consumer | Approx. |
|---|---|
| OS, desktop-less services, file cache | 12–14 GB |
| `llama-server`, one 30B MoE at Q6_K | ~25 GB (+ KV cache) |
| ComfyUI with SDXL loaded | ~10 GB |
| `ai-discord-bot`, `openclaw-gateway` | a few hundred MB each |

OpenClaw is the cheap one in that table. If a Flux job OOMs or the model gets evicted, the
answer is still [03](03-gpu-memory.md) and
[08](08-operations.md#coexistence-images-while-chatting), never "give OpenClaw less".

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `openclaw: command not found` | npm global `bin` not on `PATH` | `npm prefix -g`; the unit already sets `PATH`, your shell may not |
| `blocked because they are not covered by allowScripts` | npm 12 policy | reinstall with `--allow-scripts=openclaw` (npm ≤11.15: no flag) |
| discovery finds nothing | model still loading | `curl localhost:8080/health` → `ok`, then `openclaw models list --provider llama-cpp --refresh` |
| one-token or truncated replies | `contextWindow` above the server's 64k | set `65536` in the provider patch |
| every turn times out | hosted-API default timeouts | `timeoutSeconds: 300` + `agents.defaults.timeoutSeconds` |
| gateway will not start, port busy | another gateway, or an old user unit | `ss -ltnp \| grep 18789`; `systemctl --user disable --now openclaw-gateway` |
| dashboard says 401/unauthorized | token mismatch | `sudo grep OPENCLAW_GATEWAY_TOKEN ~/.config/ai-box/openclaw.env` |
| model id rejected after switching to router mode | id is now the `.gguf` file name | `openclaw models set llama-cpp/<file>.gguf`, restart the gateway |
| config edits vanish | gateway rewrites `openclaw.json` and drops comments | stop the unit before `config patch`, or accept JSON output |

`openclaw doctor` covers most of the above in one shot, and `openclaw doctor --fix` repairs the
common config problems. `openclaw logs --follow` is the gateway log; `journalctl -u
openclaw-gateway -f` is the unit's.

---

## Honest status

Same caveat as the rest of this repo ([§7](../README.md#7-honest-status-of-this-repo)): the
script passes `bash -n`, the patch file is plain JSON5, and the unit follows the same template
as the other three. **None of it has been run against this hardware**, because OpenClaw is not
installed here — the CLI flags, `--auth-choice llama-cpp-existing-server` and the
`llama-cpp` provider keys are taken from OpenClaw's documentation as of November 2026. Run
`openclaw --version` and `openclaw doctor` before trusting a flag, and treat the first channel
connection as a supervised run.

- <https://docs.openclaw.ai/plugins/llama-cpp> — the provider this page configures
- <https://docs.openclaw.ai/gateway/remote> — tunnels, Tailscale, remote access
- <https://docs.openclaw.ai/channels> — the channel catalogue
- <https://docs.openclaw.ai/gateway/security> — the trust model in full
