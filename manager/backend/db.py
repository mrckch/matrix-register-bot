"""
SQLite-Persistenz fuer den Bot Manager.

Speichert:
  - Eine Registry der vom Manager verwalteten Bots (mxid, Anzeigename, ...).
    Damit unabhaengig vom Synapse-internen `user_type`-Flag (das auch
    versehentlich auf Nicht-Bots landen kann).
  - Pro Bot eine Liste der ausgestellten Access-Tokens — als KLARTEXT,
    damit man sie ueber die UI auch spaeter noch einsehen kann.

DB-Pfad kommt aus DB_PATH (Default /data/manager.db). Das Verzeichnis
sollte als Docker-Volume eingehangen sein, sonst sind alle Eintraege beim
naechsten `docker compose up --build` weg.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

import aiosqlite

DB_PATH = Path(os.environ.get("DB_PATH", "/data/manager.db"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS bots (
    mxid          TEXT PRIMARY KEY,
    localpart     TEXT NOT NULL,
    displayname   TEXT,
    created_at    INTEGER NOT NULL,
    deactivated   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS tokens (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    mxid            TEXT NOT NULL,
    device_id       TEXT NOT NULL,
    label           TEXT,
    access_token    TEXT NOT NULL,
    valid_until_ms  INTEGER,
    created_at      INTEGER NOT NULL,
    FOREIGN KEY (mxid) REFERENCES bots(mxid) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tokens_mxid ON tokens(mxid);

CREATE TABLE IF NOT EXISTS default_users (
    mxid           TEXT PRIMARY KEY,
    default_admin  INTEGER NOT NULL DEFAULT 0,
    created_at     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_log (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    ts      INTEGER NOT NULL,
    action  TEXT NOT NULL,
    target  TEXT,
    detail  TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts DESC);
"""


async def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript(SCHEMA)
        # Lightweight migrations: nur ALTER, wenn Spalte fehlt.
        async with db.execute("PRAGMA table_info(bots)") as cur:
            cols = {row[1] for row in await cur.fetchall()}
        if "tags" not in cols:
            await db.execute("ALTER TABLE bots ADD COLUMN tags TEXT NOT NULL DEFAULT ''")
        await db.commit()


def _now_ms() -> int:
    return int(time.time() * 1000)


# ---------------------------------------------------------------------------
# Bots
# ---------------------------------------------------------------------------

def _tags_to_list(s: str | None) -> list[str]:
    if not s:
        return []
    return [t for t in s.split(",") if t]


async def list_bots() -> list[dict[str, Any]]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            "SELECT mxid, localpart, displayname, created_at, deactivated, tags "
            "FROM bots ORDER BY created_at DESC"
        )
        out = []
        for r in rows:
            d = dict(r)
            d["tags"] = _tags_to_list(d.get("tags"))
            out.append(d)
        return out


async def get_bot(mxid: str) -> dict[str, Any] | None:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT mxid, localpart, displayname, created_at, deactivated, tags "
            "FROM bots WHERE mxid = ?", (mxid,),
        ) as cur:
            row = await cur.fetchone()
            if not row:
                return None
            d = dict(row)
            d["tags"] = _tags_to_list(d.get("tags"))
            return d


async def add_bot(mxid: str, localpart: str, displayname: str | None) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT OR IGNORE INTO bots (mxid, localpart, displayname, created_at) "
            "VALUES (?, ?, ?, ?)",
            (mxid, localpart, displayname, _now_ms()),
        )
        await db.commit()


async def update_bot(mxid: str, **fields: Any) -> None:
    allowed = {"displayname", "deactivated", "tags"}
    sets = {k: v for k, v in fields.items() if k in allowed}
    if not sets:
        return
    # tags kommt als Liste rein, intern als CSV speichern.
    if "tags" in sets and isinstance(sets["tags"], list):
        cleaned = [t.strip() for t in sets["tags"] if t and t.strip()]
        sets["tags"] = ",".join(sorted(set(cleaned)))
    keys = ", ".join(f"{k} = ?" for k in sets)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            f"UPDATE bots SET {keys} WHERE mxid = ?",
            (*sets.values(), mxid),
        )
        await db.commit()


async def remove_bot(mxid: str) -> None:
    """Entfernt nur den Registry-Eintrag — der Synapse-User bleibt bestehen."""
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM tokens WHERE mxid = ?", (mxid,))
        await db.execute("DELETE FROM bots WHERE mxid = ?", (mxid,))
        await db.commit()


# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------

async def list_tokens(mxid: str) -> list[dict[str, Any]]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            "SELECT id, device_id, label, access_token, valid_until_ms, created_at "
            "FROM tokens WHERE mxid = ? ORDER BY created_at DESC",
            (mxid,),
        )
        return [dict(r) for r in rows]


async def add_token(
    mxid: str,
    device_id: str,
    access_token: str,
    label: str | None,
    valid_until_ms: int | None,
) -> int:
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute(
            "INSERT INTO tokens (mxid, device_id, label, access_token, valid_until_ms, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (mxid, device_id, label, access_token, valid_until_ms, _now_ms()),
        )
        await db.commit()
        return cur.lastrowid


async def get_token(mxid: str, token_id: int) -> dict[str, Any] | None:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT id, device_id, label, access_token, valid_until_ms, created_at "
            "FROM tokens WHERE mxid = ? AND id = ?",
            (mxid, token_id),
        ) as cur:
            row = await cur.fetchone()
            return dict(row) if row else None


async def remove_token(mxid: str, token_id: int) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "DELETE FROM tokens WHERE mxid = ? AND id = ?", (mxid, token_id),
        )
        await db.commit()


# ---------------------------------------------------------------------------
# Default-User-Liste (vorausgewaehlte Invites in Raum-Anlage / Wizard)
# ---------------------------------------------------------------------------

async def list_default_users() -> list[dict[str, Any]]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            "SELECT mxid, default_admin, created_at FROM default_users "
            "ORDER BY created_at ASC"
        )
        return [{"mxid": r["mxid"], "default_admin": bool(r["default_admin"])} for r in rows]


async def upsert_default_user(mxid: str, default_admin: bool) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO default_users (mxid, default_admin, created_at) VALUES (?, ?, ?) "
            "ON CONFLICT(mxid) DO UPDATE SET default_admin = excluded.default_admin",
            (mxid, 1 if default_admin else 0, _now_ms()),
        )
        await db.commit()


async def remove_default_user(mxid: str) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("DELETE FROM default_users WHERE mxid = ?", (mxid,))
        await db.commit()


# ---------------------------------------------------------------------------
# Audit-Log: Welche Aenderungen sind ueber den Manager passiert?
# Detail-Feld wird als JSON-String abgelegt.
# ---------------------------------------------------------------------------

async def log_audit(action: str, target: str | None = None,
                    detail: dict[str, Any] | None = None) -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO audit_log (ts, action, target, detail) VALUES (?, ?, ?, ?)",
            (_now_ms(), action, target, json.dumps(detail) if detail else None),
        )
        await db.commit()


async def list_audit(limit: int = 200, offset: int = 0) -> list[dict[str, Any]]:
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            "SELECT id, ts, action, target, detail FROM audit_log "
            "ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?",
            (limit, offset),
        )
        out: list[dict[str, Any]] = []
        for r in rows:
            row = dict(r)
            if row.get("detail"):
                try:
                    row["detail"] = json.loads(row["detail"])
                except json.JSONDecodeError:
                    pass
            out.append(row)
        return out


async def count_audit() -> int:
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute("SELECT COUNT(*) FROM audit_log") as cur:
            row = await cur.fetchone()
            return row[0] if row else 0
