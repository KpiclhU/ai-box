"""Per-channel conversation history in SQLite.

Kept deliberately boring: one table, one row per message, trimmed by turn count
when read. A restart therefore does not lose the thread, and threads (which have
their own channel ids) get their own history for free.
"""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER NOT NULL,
    role       TEXT    NOT NULL,
    content    TEXT    NOT NULL,
    created_at REAL    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages (channel_id, id);
"""


class HistoryStore:
    def __init__(self, path: Path | str) -> None:
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(self.path, check_same_thread=False)
        self._conn.executescript(SCHEMA)
        self._conn.commit()

    def get(self, channel_id: int, turns: int) -> list[dict[str, str]]:
        """Return the last ``turns`` exchanges as chat-completion messages."""
        limit = max(0, turns) * 2
        if limit == 0:
            return []
        rows = self._conn.execute(
            "SELECT role, content FROM messages WHERE channel_id = ? ORDER BY id DESC LIMIT ?",
            (channel_id, limit),
        ).fetchall()
        rows.reverse()
        return [{"role": role, "content": content} for role, content in rows]

    def append(self, channel_id: int, role: str, content: str) -> None:
        self._conn.execute(
            "INSERT INTO messages (channel_id, role, content, created_at) VALUES (?, ?, ?, ?)",
            (channel_id, role, content, time.time()),
        )
        self._conn.commit()

    def append_exchange(self, channel_id: int, user: str, assistant: str) -> None:
        now = time.time()
        self._conn.executemany(
            "INSERT INTO messages (channel_id, role, content, created_at) VALUES (?, ?, ?, ?)",
            [
                (channel_id, "user", user, now),
                (channel_id, "assistant", assistant, now),
            ],
        )
        self._conn.commit()

    def clear(self, channel_id: int) -> int:
        cursor = self._conn.execute("DELETE FROM messages WHERE channel_id = ?", (channel_id,))
        self._conn.commit()
        return cursor.rowcount

    def count(self, channel_id: int) -> int:
        row = self._conn.execute(
            "SELECT COUNT(*) FROM messages WHERE channel_id = ?", (channel_id,)
        ).fetchone()
        return int(row[0]) if row else 0

    def close(self) -> None:
        self._conn.close()
