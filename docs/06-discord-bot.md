# 06 — The Discord bot

`bot/` is a single `discord.py` process that fronts both local services. No cloud APIs, no
keys beyond your Discord bot token.

## Commands

| Command | What it does |
|---|---|
| `/chat prompt:…` | Streams a reply from `llama-server` into the channel |
| `/image prompt:… [negative] [steps] [width] [height] [seed]` | Queues a ComfyUI graph, posts the PNG |
| `/reset` | Clears this channel's conversation history |
| `/status` | llama-server health, loaded model, ComfyUI queue, GPU memory |
| `@bot …` | Same as `/chat`, only if `REPLY_ON_MENTION=true` |

`/chat` keeps a rolling per-channel history in SQLite, so a restart does not lose the thread.
Threads get their own history because they are their own channel id.

## Setup

1. <https://discord.com/developers/applications> → **New Application** → **Bot** →
   **Reset Token** → copy it.
2. Under **Privileged Gateway Intents**, enable **Message Content** *only if* you set
   `REPLY_ON_MENTION=true`. Slash commands and replies to the bot work without it.
   Since mid-2026 the review is threshold-based: under 10,000 unique users you can just
   toggle it in the portal.
3. **OAuth2 → URL Generator**: scopes `bot` + `applications.commands`; permissions
   `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`,
   `Use Slash Commands`. Invite it to your server.
4. Configure and run:

   ```bash
   cp bot/.env.example .env
   $EDITOR .env                     # DISCORD_TOKEN, DISCORD_GUILD_ID
   ./scripts/40-install-bot.sh
   set -a; . ./.env; set +a; ./bot/.venv/bin/python bot/bot.py    # foreground test
   sudo ./scripts/50-install-services.sh                          # then run as a service
   ```

`DISCORD_GUILD_ID` makes commands appear **instantly** in that one server. Leave it empty for
global commands, which propagate more slowly. Slash-command registration is rate-limited to
**200 creates per day per guild** — do not put `tree.sync()` in a restart loop.

## How streaming works

Discord has no token streaming, so the bot fakes it:

1. `interaction.response.defer(thinking=True)` — answers inside the 3-second deadline.
2. Accumulate deltas from `llama-server`'s SSE stream.
3. Edit the placeholder at most **once per 1.2 s**, always showing the *tail* of the text
   (~1900 chars) inside a 2000-char budget, with code fences closed and reopened so the
   message never renders broken.
4. On completion, post the full text: the original message is edited with the first chunk and
   any remainder goes out as follow-ups.

Editing every token would get you rate-limited — Discord's per-channel edit limit is not
published, and the widely repeated "5 edits / 5 s" is folklore. One edit per ~1.2 s is the
safe envelope, and users cannot perceive the difference.

## Limits you have to design around

| Limit | Value | What the bot does |
|---|---|---|
| Message content | 2000 chars | Splits on paragraphs, hard-splits pathological lines |
| Request size | 25 MiB | Not a concern for one PNG |
| Per-file upload | 20 MiB (raised from 10 MiB in Sep 2026) | SDXL PNGs are ~1–2 MB; a 4-image batch could approach it |
| Interactions response | 3 s to first response | `defer()` immediately |
| Command creates | 200/day/guild | Guild-scoped sync, once |
| Global rate limit | ~50 req/s per bot | Edits are the only high-frequency call |

## Concurrency

```python
llm_slots = asyncio.Semaphore(2)      # must equal llama-server --parallel
channel_locks[channel_id]             # serialises one channel
```

- Keying on **channel** keeps one conversation coherent; the semaphore caps total in-flight
  generations so the server's two slots are not oversubscribed.
- Image jobs get their own semaphore of 1: ComfyUI queues internally, and letting users pile
  five Flux jobs onto a 64 GB box is how you get swap thrash. The bot reports queue position.

## Wiring details

**LLM** — `POST /v1/chat/completions` with `stream: true`, read with
`httpx.AsyncClient.stream()` + `aiter_lines()`, skip blank lines and `:` keep-alives, stop on
`data: [DONE]`. Use `httpx.Timeout(read=None)`: a long prompt can be silent for 30+ seconds
and a short read timeout kills healthy streams. Reasoning models emit `reasoning_content`
deltas separately — the bot ignores those rather than pasting chain-of-thought into Discord.

**ComfyUI** — `POST /prompt` then poll `/history/<id>` every 0.75 s (simpler than the
websocket, and one fewer dependency), then `GET /view` for the bytes. `COMFY_CHECKPOINT` in
`.env` is substituted into the graph at request time, so the workflow file never has to be
hand-edited.

## Discord policy notes

- **Do not** send unprompted DMs or automate messages to keep a channel active — the
  Developer Policy bans activity-farming outright.
- **Do not** log message content into a fine-tuning set. The policy forbids training on
  Discord data without express permission. Local inference on it is fine; hoarding it is not.
- Keep `AllowedMentions.none()` on so model output can never ping `@everyone`.

## Changing the model or persona

`SYSTEM_PROMPT` in `.env` controls persona; `LLM_MODEL` is the `/v1/models` alias the bot
asks for. Switching the *loaded* model means restarting `llama-server`, or putting
`llama-swap` in front of it ([04-llm-stack.md](04-llm-stack.md)).

## Logs

```bash
journalctl -u ai-discord-bot -f
```

The bot logs one line per request (channel, prompt chars, first-token latency, total time,
tok/s) which is enough to tell "the model is slow" from "Discord is rate-limiting".
