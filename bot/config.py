"""Configuration for the ai-box Discord bot.

Everything comes from the repo-root .env (loaded here) or the real environment,
so the same settings work under systemd's EnvironmentFile and a manual run.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")

DEFAULT_SYSTEM_PROMPT = (
    "You are a helpful, concise assistant in a Discord chat. Prefer short paragraphs "
    "and fenced code blocks with a language tag. Never claim to have run code you did "
    "not run."
)


def _str(name: str, default: str) -> str:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip()


def _bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _int(name: str, default: int) -> int:
    try:
        return int(_str(name, str(default)))
    except ValueError:
        return default


def _float(name: str, default: float) -> float:
    try:
        return float(_str(name, str(default)))
    except ValueError:
        return default


def _optional_int(name: str) -> int | None:
    raw = _str(name, "")
    try:
        return int(raw) if raw else None
    except ValueError:
        return None


def _path(name: str, default: str) -> Path:
    raw = _str(name, default)
    path = Path(raw).expanduser()
    return path if path.is_absolute() else (REPO_ROOT / path)


@dataclass(frozen=True)
class Config:
    token: str
    guild_id: int | None
    allowed_role_id: int | None
    reply_on_mention: bool

    llm_base_url: str
    llm_api_key: str
    llm_model: str
    llm_max_tokens: int
    llm_temperature: float
    llm_top_p: float
    llm_enable_thinking: bool
    llm_max_concurrent: int
    llm_connect_timeout: float
    history_turns: int
    system_prompt: str

    comfy_url: str
    comfy_workflow: Path
    comfy_checkpoint: str
    comfy_default_steps: int
    comfy_timeout_s: int

    stream_edit_interval: float
    db_path: Path
    log_level: str


def load() -> Config:
    return Config(
        token=_str("DISCORD_TOKEN", ""),
        guild_id=_optional_int("DISCORD_GUILD_ID"),
        allowed_role_id=_optional_int("ALLOWED_ROLE_ID"),
        reply_on_mention=_bool("REPLY_ON_MENTION", False),
        llm_base_url=_str("LLM_BASE_URL", "http://127.0.0.1:8080"),
        llm_api_key=_str("LLM_API_KEY", "local"),
        llm_model=_str("LLM_MODEL", "local"),
        llm_max_tokens=_int("LLM_MAX_TOKENS", 1024),
        llm_temperature=_float("LLM_TEMPERATURE", 0.7),
        llm_top_p=_float("LLM_TOP_P", 0.9),
        llm_enable_thinking=_bool("LLM_ENABLE_THINKING", False),
        llm_max_concurrent=max(1, _int("LLM_MAX_CONCURRENT", 2)),
        llm_connect_timeout=_float("LLM_CONNECT_TIMEOUT", 10.0),
        history_turns=_int("HISTORY_TURNS", 12),
        system_prompt=_str("SYSTEM_PROMPT", DEFAULT_SYSTEM_PROMPT),
        comfy_url=_str("COMFY_URL", "http://127.0.0.1:8188"),
        comfy_workflow=_path("COMFY_WORKFLOW", "bot/workflows/sdxl.api.json"),
        comfy_checkpoint=_str("COMFY_CHECKPOINT", "sd_xl_base_1.0.safetensors"),
        comfy_default_steps=_int("COMFY_DEFAULT_STEPS", 28),
        comfy_timeout_s=_int("COMFY_TIMEOUT_S", 900),
        stream_edit_interval=max(1.0, _float("STREAM_EDIT_INTERVAL", 1.2)),
        db_path=_path("DB_PATH", "~/ai/data/bot.sqlite3"),
        log_level=_str("LOG_LEVEL", "INFO").upper(),
    )
