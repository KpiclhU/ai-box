#!/usr/bin/env python3
"""ai-box Discord bot: local LLM chat + ComfyUI image generation.

Run with:  bot/.venv/bin/python bot/bot.py
Configured entirely from the repo-root .env (see bot/.env.example).
"""

from __future__ import annotations

import asyncio
import io
import logging
import time
from pathlib import Path

import discord
from discord import app_commands
from discord.ext import commands

import llm
from comfy import ComfyClient, ComfyError
from config import load
from store import HistoryStore

log = logging.getLogger("ai-box.bot")

cfg = load()
store = HistoryStore(cfg.db_path)


def _build_comfy() -> ComfyClient | None:
    try:
        return ComfyClient(
            cfg.comfy_url,
            cfg.comfy_workflow,
            checkpoint=cfg.comfy_checkpoint,
            timeout_s=cfg.comfy_timeout_s,
        )
    except ComfyError as exc:
        log.warning("ComfyUI client unavailable (%s); /image will be disabled", exc)
        return None


comfy = _build_comfy()

intents = discord.Intents.default()
intents.message_content = cfg.reply_on_mention

bot = commands.Bot(
    command_prefix="!",
    intents=intents,
    allowed_mentions=discord.AllowedMentions.none(),
)

llm_slots = asyncio.Semaphore(cfg.llm_max_concurrent)
image_slot = asyncio.Semaphore(1)
_channel_locks: dict[int, asyncio.Lock] = {}


def channel_lock(channel_id: int) -> asyncio.Lock:
    lock = _channel_locks.get(channel_id)
    if lock is None:
        lock = asyncio.Lock()
        _channel_locks[channel_id] = lock
    return lock


def allowed(user: discord.abc.User) -> bool:
    if cfg.allowed_role_id is None:
        return True
    roles = getattr(user, "roles", ())
    return any(role.id == cfg.allowed_role_id for role in roles)


# --- text shaping ------------------------------------------------------------


def split_message(text: str, limit: int = 1990) -> list[str]:
    """Split on paragraph boundaries, hard-splitting any single oversized line."""
    text = text.strip() or "(empty response)"
    chunks: list[str] = []
    remaining = text
    while remaining:
        if len(remaining) <= limit:
            chunks.append(remaining)
            break
        window = remaining[:limit]
        cut = window.rfind("\n")
        if cut < limit // 2:
            cut = limit
        chunks.append(remaining[:cut].rstrip("\n"))
        remaining = remaining[cut:].lstrip("\n")
    return chunks


def tail_view(text: str, limit: int = 1900) -> str:
    """The live edit always shows the tail, never more than Discord accepts."""
    if len(text) <= limit:
        return text
    tail = text[-(limit - 8):]
    if tail.count("```") % 2:
        tail += "\n```"  # never render an unterminated code block
    return "…" + tail


def clip(text: str, limit: int = 180) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


async def stream_to_message(message, channel_id: int, prompt: str) -> str:
    """Stream a completion into an existing message, throttled to one edit / interval."""
    state = {"buf": "", "last": 0.0}

    async def on_delta(delta: str) -> None:
        state["buf"] += delta
        now = time.monotonic()
        if now - state["last"] < cfg.stream_edit_interval:
            return
        state["last"] = now
        try:
            await message.edit(content=tail_view(state["buf"]))
        except discord.HTTPException:
            pass  # a dropped intermediate edit is harmless; the final one matters

    history = await asyncio.to_thread(store.get, channel_id, cfg.history_turns)
    messages = [
        {"role": "system", "content": cfg.system_prompt},
        *history,
        {"role": "user", "content": prompt},
    ]

    parts: list[str] = []
    async with llm_slots:
        async for delta in llm.stream_chat(
            base_url=cfg.llm_base_url,
            api_key=cfg.llm_api_key,
            model=cfg.llm_model,
            messages=messages,
            max_tokens=cfg.llm_max_tokens,
            temperature=cfg.llm_temperature,
            top_p=cfg.llm_top_p,
            enable_thinking=cfg.llm_enable_thinking,
            connect_timeout=cfg.llm_connect_timeout,
        ):
            parts.append(delta)
            await on_delta(delta)
    return "".join(parts)


async def finish_interaction(interaction: discord.Interaction, message, text: str) -> None:
    chunks = split_message(text)
    await message.edit(content=chunks[0])
    for chunk in chunks[1:]:
        await interaction.followup.send(chunk)


async def finish_channel(message: discord.Message, text: str) -> None:
    chunks = split_message(text)
    await message.edit(content=chunks[0])
    for chunk in chunks[1:]:
        await message.channel.send(chunk)


def _meminfo() -> dict[str, int]:
    values: dict[str, int] = {}
    try:
        with open("/proc/meminfo", encoding="utf-8") as handle:
            for line in handle:
                key, _, rest = line.partition(":")
                values[key] = int(rest.split()[0]) // 1024  # MiB
    except OSError:
        pass
    return values


def _ttm_gib() -> float | None:
    try:
        pages = int(Path("/sys/module/ttm/parameters/pages_limit").read_text().strip())
        return pages * 4096 / 1024**3
    except (OSError, ValueError):
        return None


# --- commands ----------------------------------------------------------------


@bot.tree.command(name="chat", description="Ask the local model something")
@app_commands.describe(prompt="What you want to ask")
async def chat(interaction: discord.Interaction, prompt: str) -> None:
    if not allowed(interaction.user):
        await interaction.response.send_message("You do not have access to this bot.", ephemeral=True)
        return

    await interaction.response.defer(thinking=True)
    message = await interaction.original_response()
    channel_id = interaction.channel_id or 0
    started = time.monotonic()

    try:
        async with channel_lock(channel_id):
            text = await stream_to_message(message, channel_id, prompt)
    except llm.LLMError as exc:
        log.warning("llm error: %s", exc)
        await message.edit(content=f"⚠️ {exc}")
        return

    if not text.strip():
        await message.edit(
            content="⚠️ Empty response. The model may have spent its budget thinking — "
            "try again, or raise `LLM_MAX_TOKENS` in `.env`."
        )
        return

    await finish_interaction(interaction, message, text)
    store.append_exchange(channel_id, prompt, text)

    elapsed = max(time.monotonic() - started, 1e-6)
    log.info(
        "chat channel=%s prompt_chars=%d reply_chars=%d %.1fs ~%.1f tok/s",
        channel_id,
        len(prompt),
        len(text),
        elapsed,
        (len(text) / 4) / elapsed,
    )


@bot.tree.command(name="image", description="Generate an image with the local ComfyUI")
@app_commands.describe(
    prompt="What to draw",
    negative="What to avoid (optional)",
    steps="Sampling steps (default from .env)",
    width="Width in pixels, rounded to a multiple of 8",
    height="Height in pixels, rounded to a multiple of 8",
    seed="Seed for reproducibility (blank = random)",
)
async def image(
    interaction: discord.Interaction,
    prompt: str,
    negative: str | None = None,
    steps: int | None = None,
    width: int = 1024,
    height: int = 1024,
    seed: int | None = None,
) -> None:
    if not allowed(interaction.user):
        await interaction.response.send_message("You do not have access to this bot.", ephemeral=True)
        return
    if comfy is None:
        await interaction.response.send_message(
            "Image generation is not configured: the workflow file is missing. "
            "Check `COMFY_WORKFLOW` in `.env`.",
            ephemeral=True,
        )
        return

    await interaction.response.defer(thinking=True)
    message = await interaction.original_response()
    await message.edit(content=f"🎨 queued: `{clip(prompt)}`")
    started = time.monotonic()

    async with image_slot:
        try:
            result = await comfy.generate(
                prompt=prompt,
                negative=negative,
                steps=steps or cfg.comfy_default_steps,
                width=width,
                height=height,
                seed=seed,
            )
        except ComfyError as exc:
            log.warning("comfy error: %s", exc)
            await message.edit(content=f"⚠️ Image generation failed: {exc}")
            return

    elapsed = time.monotonic() - started
    file = discord.File(io.BytesIO(result["bytes"]), filename=result["filename"])
    await message.edit(
        content=(
            f"`{clip(prompt)}`\n"
            f"seed `{result['seed']}` · {result['steps']} steps · {elapsed:.1f}s"
        ),
        attachments=[file],
    )
    log.info("image channel=%s %.1fs %s", interaction.channel_id, elapsed, result["filename"])


@bot.tree.command(name="reset", description="Clear this channel's conversation history")
async def reset(interaction: discord.Interaction) -> None:
    removed = store.clear(interaction.channel_id or 0)
    await interaction.response.send_message(
        f"Cleared {removed} stored message(s) for this channel.", ephemeral=True
    )


@bot.tree.command(name="status", description="Health of the local AI stack")
async def status(interaction: discord.Interaction) -> None:
    await interaction.response.defer(thinking=True)

    health = await llm.health(cfg.llm_base_url, cfg.llm_api_key, cfg.llm_connect_timeout)
    model_ids = await llm.models(cfg.llm_base_url, cfg.llm_api_key, cfg.llm_connect_timeout)
    queue = await comfy.queue() if comfy else {"running": 0, "pending": 0}
    stats = await comfy.stats() if comfy else {}

    health_label = {
        200: "ready",
        503: "loading model",
        0: "unreachable",
    }.get(health.get("status_code", 0), f"http {health.get('status_code')}")

    embed = discord.Embed(title="ai-box status", colour=discord.Colour.dark_teal())
    embed.add_field(
        name="LLM",
        value=f"`{cfg.llm_base_url}` — {health_label}\nmodels: {', '.join(model_ids) or '—'}",
        inline=False,
    )
    if stats:
        total = stats.get("vram_total", 0) / 1024**3
        free = stats.get("vram_free", 0) / 1024**3
        embed.add_field(
            name="ComfyUI",
            value=(
                f"`{stats.get('device', '?')}`\n"
                f"queue: {queue['running']} running / {queue['pending']} pending\n"
                f"vram: {free:.1f} / {total:.1f} GiB free"
            ),
            inline=False,
        )
    else:
        embed.add_field(name="ComfyUI", value="unreachable", inline=False)

    mem = _meminfo()
    gtt = _ttm_gib()
    embed.add_field(
        name="Host RAM",
        value=(
            f"{mem.get('MemAvailable', 0) / 1024:.1f} GiB available "
            f"of {mem.get('MemTotal', 0) / 1024:.1f} GiB\n"
            f"GPU-addressable limit: {f'{gtt:.0f} GiB' if gtt else 'unknown'}"
        ),
        inline=False,
    )
    await interaction.followup.send(embed=embed)


# --- events ------------------------------------------------------------------


@bot.event
async def setup_hook() -> None:
    # Slash-command registration is a deployment action, not a start-up action:
    # it is rate-limited to 200 creates/day/guild, so do it once, not per restart.
    if cfg.guild_id:
        guild = discord.Object(id=cfg.guild_id)
        bot.tree.copy_global_to(guild=guild)
        await bot.tree.sync(guild=guild)
        log.info("synced application commands to guild %s", cfg.guild_id)
    else:
        await bot.tree.sync()
        log.info("synced global application commands (may take a while to appear)")


@bot.event
async def on_ready() -> None:
    user = bot.user
    log.info("logged in as %s (id=%s) in %d guild(s)", user, getattr(user, "id", "?"), len(bot.guilds))
    await bot.change_presence(
        activity=discord.Activity(type=discord.ActivityType.listening, name="/chat")
    )


@bot.event
async def on_message(message: discord.Message) -> None:
    if message.author.bot or bot.user is None:
        return
    if not cfg.reply_on_mention or bot.user not in message.mentions:
        return
    if not allowed(message.author):
        return

    prompt = message.content
    for mention in message.mentions:
        prompt = prompt.replace(f"<@{mention.id}>", " ").replace(f"<@!{mention.id}>", " ")
    prompt = prompt.strip()
    if not prompt:
        return

    placeholder = await message.reply("…", mention_author=False)
    channel_id = message.channel.id
    try:
        async with channel_lock(channel_id):
            text = await stream_to_message(placeholder, channel_id, prompt)
    except llm.LLMError as exc:
        await placeholder.edit(content=f"⚠️ {exc}")
        return

    if not text.strip():
        await placeholder.edit(content="⚠️ Empty response from the model.")
        return

    await finish_channel(placeholder, text)
    store.append_exchange(channel_id, prompt, text)


def main() -> int:
    logging.basicConfig(
        level=getattr(logging, cfg.log_level, logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    if not cfg.token or cfg.token.startswith("YOUR_"):
        log.error("DISCORD_TOKEN is not set. Copy bot/.env.example to .env and fill it in.")
        return 2
    log.info(
        "starting against llm=%s comfy=%s workflow=%s",
        cfg.llm_base_url,
        cfg.comfy_url,
        cfg.comfy_workflow,
    )
    bot.run(cfg.token, log_handler=None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
