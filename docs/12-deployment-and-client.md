# 12 — The front door: Open WebUI, Caddy on the VM, and Windows

**Status: built on 22 Nov 2026**, against the decisions below. Nothing here has been run on
`gfx1151` hardware yet — the first run of each script is a supervised run, same as the rest of
this repo ([README §7](../README.md#7-honest-status-of-this-repo)).

The question this page answers: *a 64 GB box with `llama-server` and ComfyUI, a Caddy VM on the
Proxmox host, and up to five people with Windows PCs — what do they run, and what is exposed?*

## 0. Decisions

| Question | Decision |
|---|---|
| Windows client | **Open WebUI** — open source, per-user accounts, ComfyUI image generation. Installed as a PWA/app window; no bespoke client |
| GPU stack | **`ai-box` owns it.** `llama-server` + ComfyUI. LU ([`lu-box/`](../lu-box/README.md)) is superseded and not installed |
| Chat ↔ images | **Both**: inline "draw this" in a conversation, plus the Images workspace |
| Caddy | VM on the Proxmox host, **192.168.150.13**, publishing **`https://ai.pilchlab.ca`** |
| Exposure | **LAN only** (`remote_ip` allowlist). Remote access later; no port-forwarding |
| Identity | **Up to 5 people**, separate Open WebUI accounts created by the admin |
| Install method | **Native** (`uv` + systemd), no Docker on the box |
| Image models | **SDXL** default, **Flux.1-schnell** as the second workflow (one active at a time) |
| Removed | `bot/` (Discord) and OpenClaw — accounts replaced the chat-bridge use case |

## 1. Why Open WebUI

It is the open-source tool that already does the whole Windows-side job:

| Requirement | How it is met |
|---|---|
| Chat with the local model | Add `http://127.0.0.1:8080/v1` as an OpenAI-compatible connection. Same `llama-server`, same 64k window, no second model |
| Images from a prompt | **Admin → Settings → Images → engine `ComfyUI`** with a workflow in **API format** |
| Draw inside a conversation | The **Image** toggle in the message-input *Integrations* menu; the result lands inline and is saved with the chat |
| A dedicated image workspace | The **Images** section in the sidebar: prompt, size, steps, gallery |
| Better prompts automatically | *Image Prompt Generation* asks the chat model to expand a short prompt first |
| Separate accounts | Roles, **groups** with additive permissions, per-user history in its own SQLite. MFA and OIDC/LDAP exist if wanted later |
| Windows | A browser tab, or **Edge/Chrome → Install this site as an app** for a real window and taskbar icon |

Cost: one Python process, ~1–2 GB of ordinary RAM, no GPU, no second copy of the weights.

**It also removes a hazard.** Open WebUI generates images itself through ComfyUI, so
`llama-server` no longer needs `--tools` or `--mcp-servers-config`. With tools off, "use the
model" no longer means "run shell commands as `ai-user`" — which matters now that several
people can reach it.

### The alternatives, and why not

| Tool | Why not here |
|---|---|
| **SillyTavern** | Excellent ComfyUI integration (URL + workflow JSON, `/sd` slash commands), but one user, character-card shaped, no account model |
| **Cherry Studio**, **Chatbox**, **Jan** | Good native Windows chat apps, single user per install; image generation is provider-oriented rather than your ComfyUI |
| **AnythingLLM** | MIT, desktop + Docker, `/img` in a thread. ComfyUI is not a first-class image provider |
| **LibreChat** | MIT, multi-user, agents and MCP — but a six-service stack for five people |
| **Locally Uncensored** | Owns the engine and installs its own ComfyUI — the collision that §0 resolves |
| **llama-server's Llama Chat** | Zero install, but one conversation list, no accounts, images only through shell/MCP tools |

## 2. Target architecture

```
  Windows PCs — browser tab, or the installed PWA
        │  https://ai.pilchlab.ca
        ▼
  Caddy VM  192.168.150.13   (Proxmox)
        │  tls internal + remote_ip allowlist
        ▼
  192.168.150.40:3000   ai-box (Ubuntu 26.04)
  ┌──────────────────────────────────────────┐
  │ open-webui       0.0.0.0:3000 (ufw)      │
  │   ├─► llama-server   127.0.0.1:8080 /v1  │
  │   └─► ComfyUI        127.0.0.1:8188      │
  └──────────────────────────────────────────┘
        ▲
        └── admin only: ssh -L 8188:127.0.0.1:8188  (the ComfyUI editor)
```

Three rules make it safe enough for a household:

1. **Only `:3000` leaves the box.** Open WebUI has to bind `0.0.0.0` because Caddy is on a
   different machine. `81-front-door.sh` installs the ufw rule for the Caddy VM's address *first*
   and only then moves the bind; with ufw missing, inactive or default-allow it leaves the bind on
   `127.0.0.1` and exits non-zero. A wildcard bind with nothing in front of it is a LAN-wide
   listener, so the script fails closed instead of printing a warning.
2. **`llama-server` and ComfyUI never bind the LAN.** ComfyUI has no authentication at all;
   llama-server's own UI is an admin/debug surface, reached over SSH.
3. **Caddy never proxies ComfyUI.** The node editor is one SSH tunnel away when it is needed.

## 3. Accounts

- **The first admin is created at startup, not through the sign-up page.**
  `50-install-services.sh` generates `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD` and prints
  them; Open WebUI creates that account while `ENABLE_SIGNUP=false`. (The first-sign-up
  exemption is recent and version-dependent; this path is not.) The password line is removed
  from `openwebui.env` once the account exists. Change the password after signing in, then
  create each person under *Admin → Users*.
- **Image generation is a group permission.** Permissions are additive, so keep the default
  role lean and put image generation in a `creators` group. Everyone chats; whoever should
  spend GPU time on images is in the group.
- **History is per account** in `~/ai/data/openwebui` — no shared transcript.
- **Per-user API keys** exist for an editor or script that wants `/api` instead of the web UI.
- **Later:** OIDC is built in, so moving to Authentik on the same Proxmox host is config, not a
  rebuild. Turn on MFA before any remote exposure.

## 4. Images through Open WebUI

`50-install-services.sh` writes this section into `openwebui.env` on the first run: Image
Generation **on**, engine **ComfyUI**, base URL `http://127.0.0.1:8188` (native install — no
`host.docker.internal`), `IMAGE_GENERATION_MODEL=sd_xl_base_1.0.safetensors`, `IMAGE_STEPS=28`,
and the shipped SDXL graph with its node map. A fresh install therefore needs only the
checkpoint on disk for the first image — no settings click-path.

If you start from an existing `openwebui.env`, set the same values in
**Admin → Settings → Images** and import `workflows/openwebui-sdxl.api.json` with **Import
Workflow**. It must be the **API format**; a normal ComfyUI *Save* is rejected as
`Invalid workflow`.

### SDXL, the default

| Field | Key | Node id |
|---|---|---|
| Prompt | `text` | `6` |
| Model | `ckpt_name` | `4` |
| Width / Height | `width` / `height` | `5` |
| Steps | `steps` | `3` |
| Seed | `seed` | `3` |

Checkpoint: `sd_xl_base_1.0.safetensors`. 28 steps, ~15–25 s, ~10 GB resident — coexists with
a 25 GB model in the 48 GiB pool.

**Do not map the negative prompt.** The inline chat path sends `negative_prompt: null`, and
ComfyUI rejects null for a string input, so the graph keeps its own negative prompt in node `7`.
If you want to edit it, edit the workflow JSON.

### Flux.1-schnell

| Field | Key | Node id |
|---|---|---|
| Prompt | `text` | `6` |
| Model | `unet_name` | `10` |
| Width / Height | `width` / `height` | `27` |
| Steps | `steps` | `3` |
| Seed | `seed` | `3` |

Needs `flux1-schnell-fp8-e4m3fn.safetensors`, `t5xxl_fp8_e4m3fn.safetensors`,
`clip_l.safetensors` and `ae.safetensors` in the ComfyUI model folders. Set **Steps = 4** when
this workflow is active (schnell is a 4-step distilled model) and the Model field to the
`unet_name` above.

**One workflow is active at a time** — that is how Open WebUI's image settings work. Switching
is: import the other JSON, adjust Model/Steps. Everything is reachable from `workflows/`, so
the switch is repeatable.

Only the mapped values are injected; everything else is baked into the JSON. Batch size, cfg,
sampler and scheduler stay as exported, which is why the two files use different samplers.

### The same mapping without the UI

Since Open WebUI v0.6.42 the node map can be an env value, and that is what
`50-install-services.sh` writes on a fresh install. The same map, if you prefer the UI:

```bash
COMFYUI_WORKFLOW_NODES='[{"type":"prompt","key":"text","node_ids":["6"]},
{"type":"model","key":"ckpt_name","node_ids":["4"]},
{"type":"width","key":"width","node_ids":["5"]},
{"type":"height","key":"height","node_ids":["5"]},
{"type":"steps","key":"steps","node_ids":["3"]},
{"type":"seed","key":"seed","node_ids":["3"]}]'
```

It has to be one line in `openwebui.env`. `COMFYUI_WORKFLOW` takes the workflow JSON itself,
which is why the files ship in `workflows/` rather than inlined into the env file.

### Two consequences worth stating

- **One GPU, one queue.** No per-user GPU quota: two people pressing Generate means ComfyUI
  runs them in sequence. SDXL is 15–25 s; a Flux job is shorter but evicts the LLM's room.
- **Flux still needs the model unloaded first** if it does not fit: ~34 GB peak for
  Flux.1-dev, and schnell fp8 is far smaller but the T5 encoder is not free. SDXL is the
  default for exactly this reason ([03](03-gpu-memory.md)).

## 5. Caddy on the Proxmox VM

`scripts/81-front-door.sh` writes the site block to
`~/.config/ai-box/caddy-ai-box.caddy` and opens `:3000` to the VM only.

```caddy
ai.pilchlab.ca {
	tls internal

	@lan remote_ip 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12
	handle @lan {
		reverse_proxy 192.168.150.40:3000 {
			flush_interval -1
		}
	}
	respond "Not on this network." 403
}
```

```
# /etc/caddy/Caddyfile on the VM — one added line
import /etc/caddy/caddy-ai-box.caddy
```

- **Why `tls internal`:** `192.168.150.13` is a private address, so a public ACME challenge
  cannot reach it. Caddy's local CA issues for `ai.pilchlab.ca` anyway; the only cost is
  trusting its root on each Windows PC:

  ```bash
  # on the VM
  sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt > root.crt
  # on each Windows PC, Administrator prompt
  certutil -addstore -f Root root.crt
  ```

  If you later have a public DNS name with DNS-01 (or a tunnel), `81-front-door.sh --tls acme`
  emits the ACME variant instead.
- **No `basic_auth`.** Open WebUI's accounts are the login; a shared password in front would be
  a second credential per person with no extra protection. `remote_ip` is the cheap network
  gate that survives a misconfigured signup setting.
- **The firewall is a precondition, not a follow-up.** `81` writes the ufw rule before it touches
  `HOST`, so `:3000` is never on the LAN unguarded — not even between two of its own steps. On a
  box where ufw is still inactive (Ubuntu's default) the first run stops with `HOST=127.0.0.1` and
  the commands to fix it; the second run publishes. `sudo AI_BOX_UNFIREWALLED=1` skips the gate for
  a box already covered by firewalld, nftables or a VLAN ACL.
- **`flush_interval -1`** keeps streaming replies and long generations from being buffered.
  Caddy upgrades WebSockets by itself; no extra directive.
- **`WEBUI_URL=https://ai.pilchlab.ca`** is set by `50-install-services.sh` (override with
  `AI_BOX_PUBLIC_URL`), so links and uploaded-file URLs point at the published origin.

### Remote access, when you want it

| Option | Shape |
|---|---|
| **Tailscale** (recommended) | `tailscale serve` on the VM, or Caddy listening on the tailnet only; `remote_ip` becomes the tailnet CIDR |
| **Cloudflare Tunnel** | `cloudflared` on the VM, Cloudflare Access in front. No inbound port, but the login page is public |

Turn on MFA for admin accounts before the first remote session.

## 6. What people run on Windows

1. Open `https://ai.pilchlab.ca`, sign in with the account you were given.
2. **Edge → Apps → Install this site as an app** (Chrome: *Cast, save and share → Install page
   as app*). It gets its own window and taskbar entry.
3. Chat in the main view; *Images* in the sidebar for the workspace; **Image** in the message
   bar's Integrations menu to draw inside a conversation.

Nothing to package and no per-user configuration to drift. A native `.exe` would be a thin
wrapper around the same URL — capability-wise a dead end.

## 7. Ports and firewall

| From | To | Port | Purpose |
|---|---|---|---|
| Caddy VM `192.168.150.13` | ai-box | **3000/tcp** | Open WebUI — the only published service |
| LAN users | Caddy VM | 443 | TLS |
| Admin laptop | ai-box | 22 | SSH, and the tunnel for ComfyUI (`8188`) / llama-server UI (`8080`) |
| ai-box | itself | 8080, 8188 | loopback only |
| LAN | ai-box | 3000 | blocked by ufw except from the Caddy VM — and the bind only happens after that rule exists |

`81-front-door.sh` also deletes every ufw allow rule for `8080`/`8188` left by the old layout,
whatever its source — it deletes by rule number, because `ufw delete allow 8080/tcp` does not match
a rule written as `from <cidr> to any port 8080`. `scripts/80-lan-access.sh` stays in
the repo as the **legacy** direct-UI path (no accounts) and fails closed the same way; do not run
it alongside the front door.

## 8. Files

| File | Role |
|---|---|
| `scripts/45-install-openwebui.sh` | `uv` + pinned Python, venv in `~/ai/openwebui`, no sudo |
| `systemd/open-webui.service` | `open-webui serve --host ${HOST} --port ${PORT}` from the env file, restart on failure |
| `scripts/50-install-services.sh` | writes `openwebui.env` (secret, bootstrap admin, signup off, ComfyUI engine + SDXL workflow, data dir) and installs the unit |
| `scripts/81-front-door.sh` | Caddy snippet, firewall-gated `:3000` bind, loopback enforcement, Windows trust steps |
| `workflows/openwebui-sdxl.api.json` | default image workflow |
| `workflows/openwebui-flux-schnell.api.json` | 4-step Flux alternative |
| `scripts/80-lan-access.sh` | legacy: raw UIs behind Caddy, no accounts |
| `scripts/97-comfy-gen.sh`, `scripts/comfy-mcp.py` | admin CLI image generation; not used by the front door |

## 9. Budget with one more service

| Consumer | Approx. |
|---|---|
| OS, no desktop, file cache | 12–14 GB |
| `llama-server`, 30B MoE at Q6_K + 64k KV | ~25 GB |
| ComfyUI with SDXL loaded | ~10 GB |
| **Open WebUI** | **1–2 GB** (ordinary RAM, not GTT) |
| `open-webui` + ComfyUI idle | a few hundred MB each |

It fits the ~48 GiB GPU-addressable plan with room to spare, because Open WebUI never touches
GTT. The first *image* after a model unload still pays ComfyUI's load time.

## 10. Operations

```bash
sudo systemctl status open-webui comfyui llama-server
journalctl -u open-webui -n 50 --no-pager
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/

# update
sudo systemctl stop open-webui
~/ai/openwebui/venv/bin/pip install --upgrade open-webui   # or: uv pip install -U open-webui
sudo systemctl start open-webui
```

Back up `~/ai/data/openwebui` (users, chats, settings) with `~/.config/ai-box`; the venv is
reproducible. Upstream's hardening guide is worth reading before the first remote exposure:
<https://docs.openwebui.com/getting-started/advanced-topics/hardening>.

## 11. Risks, stated plainly

- **Open WebUI's licence** is its own (BSD-3-derived with a branding clause): fine for a
  household, read it before stripping its name in a product.
- **The Caddy VM is a single point of failure** for the front door. `systemctl status caddy` on
  the VM is the first check when "the AI is down".
- **Internal CA trust is a per-PC step.** Skip it and people click through certificate warnings
  until someone ignores a real one.
- **Shared GPU, no isolation.** One person's Flux job can evict the model; that is the 64 GB
  plan in [03](03-gpu-memory.md), not something a web UI fixes.
- **Prompt injection still matters** if Open WebUI tools or document attachments are enabled.
  Leave `llama-server` without `--tools`, and add Open WebUI tools deliberately.

## 12. openGym as an MCP tool server

openGym is a separate stack — Docker Compose, two containers, plus an optional third — published
by the same Caddy as `gym.pilchlab.ca`. Run it on a host **other than `ai-box`**: its `WEB_PORT`
defaults to 8080, which is llama-server here. It ships its own MCP server, so connecting it is
configuration on both sides; there is nothing to write.

openGym's `.env` on the Docker host, then `docker compose up -d`:

```bash
COMPOSE_PROFILES=mcp   # starts the mcp container
MCP=on                 # shows the address under Settings -> Integrations
RP_ID=gym.pilchlab.ca
ORIGIN=gym.pilchlab.ca
WEB_PORT=8080
```

The web container already proxies `/mcp`, so Caddy needs only the app's site block — no extra
route and no new port. Create a token in **Settings → Integrations → API tokens**, tick only the
categories it may read (and *Change* only where it should write), and copy the `ogt_…` value: it is
shown once.

In Open WebUI (v0.6.31+, which this install is):

1. **Admin → Settings → Integrations → External Tool Servers → + Add Connection**.
2. Set **Type: MCP (Streamable HTTP)** — not OpenAPI, which crashes on an MCP payload.
3. URL `https://gym.pilchlab.ca/mcp`, **Auth: Bearer**, paste the `ogt_…` token.

Why the connection lives here and not on `llama-server`: Open WebUI is the MCP client, so the
token stays on `ai-box` and `llama-server` keeps `--tools` off — no shell or filesystem tools on
the model port. The model only needs native tool calling, which `--jinja` in
`LLAMA_EXTRA_ARGS` already provides.

Two caveats: an admin-configured tool server is shared by every Open WebUI account, so use a
read-only token unless everyone should be able to log sessions; and `ENABLE_TOOL_SERVERS` must
stay at its default `true`.
