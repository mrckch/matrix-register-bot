"""
Matrix Bot Manager — Backend-Proxy + Bot-Registry.

Funktion:
  - /api/health           -> Info (server_name aus Synapse whoami)
  - /api/bots             -> CRUD auf der Manager-eigenen Bot-Registry (SQLite)
  - /api/bots/.../tokens  -> Access-Tokens pro Bot, Klartext in SQLite
  - /api/bots/.../rooms   -> beigetretene Raeume des Bots (Synapse Admin)
  - /api/discovery/*      -> Lookup gegen Synapse (z.B. user_type=bot fuer Import)
  - /api/synapse/*        -> direkter Admin-API-Proxy (Admin-Token serverseitig)
  - /api/client/*         -> direkter Client-API-Proxy (Bot-Token aus Request)
  - alles andere          -> Statisches Frontend (SPA-Fallback auf index.html)

Wichtige Architektur-Entscheidung:
  Der Admin-Token verlaesst diesen Container NIE. Das Frontend bekommt ihn
  nie zu sehen und der Browser hat ihn nicht im localStorage.

  Bots, die der Manager kennt, stehen in der SQLite-DB unter DB_PATH
  (Default /data/manager.db). Damit sind wir unabhaengig vom Synapse-eigenen
  user_type-Flag, das auch versehentlich auf Nicht-Bots landen kann.
"""

from __future__ import annotations

import os
import secrets
import string
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from db import (
    add_bot, add_token, get_bot, get_token,
    init_db, list_bots, list_default_users, list_tokens,
    remove_bot, remove_default_user, remove_token,
    update_bot, upsert_default_user,
)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SYNAPSE_URL = os.environ.get("SYNAPSE_URL", "").rstrip("/")
SYNAPSE_ADMIN_TOKEN = os.environ.get("SYNAPSE_ADMIN_TOKEN", "")
STATIC_DIR = Path(os.environ.get("STATIC_DIR", "/app/static"))

_FORWARD_REQUEST_BLOCKLIST = {
    "host", "connection", "content-length", "transfer-encoding",
    "accept-encoding",
}
_FORWARD_RESPONSE_BLOCKLIST = {
    "transfer-encoding", "content-encoding", "connection", "keep-alive",
}

ADMIN_HEADERS = {"Authorization": f"Bearer {SYNAPSE_ADMIN_TOKEN}"} if SYNAPSE_ADMIN_TOKEN else {}


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    if not SYNAPSE_URL:
        raise RuntimeError("SYNAPSE_URL is not set")
    if not SYNAPSE_ADMIN_TOKEN:
        raise RuntimeError("SYNAPSE_ADMIN_TOKEN is not set")
    timeout = httpx.Timeout(connect=10.0, read=30.0, write=30.0, pool=5.0)
    app.state.http = httpx.AsyncClient(timeout=timeout)
    await init_db()
    try:
        yield
    finally:
        await app.state.http.aclose()


app = FastAPI(lifespan=lifespan, title="Matrix Bot Manager")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _server_name_from_mxid(mxid: str) -> str:
    return mxid.split(":", 1)[1] if ":" in mxid else ""


def _localpart_from_mxid(mxid: str) -> str:
    return mxid.split(":", 1)[0].lstrip("@") if ":" in mxid else mxid


def _q(s: str) -> str:
    """URL-Path-Encoder, der auch '@' und ':' kodiert (in MXIDs noetig)."""
    return quote(s, safe="")


async def _admin_get(http: httpx.AsyncClient, path: str, params: dict | None = None) -> httpx.Response:
    return await http.get(f"{SYNAPSE_URL}{path}", headers=ADMIN_HEADERS, params=params)


async def _admin_put(http: httpx.AsyncClient, path: str, body: dict) -> httpx.Response:
    return await http.put(f"{SYNAPSE_URL}{path}", headers=ADMIN_HEADERS, json=body)


async def _admin_post(http: httpx.AsyncClient, path: str, body: dict | None = None) -> httpx.Response:
    return await http.post(f"{SYNAPSE_URL}{path}", headers=ADMIN_HEADERS, json=body or {})


def _gen_password(n: int = 32) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))


async def _resolve_server_name(http: httpx.AsyncClient) -> str:
    r = await http.get(
        f"{SYNAPSE_URL}/_matrix/client/v3/account/whoami",
        headers=ADMIN_HEADERS,
    )
    r.raise_for_status()
    return _server_name_from_mxid(r.json().get("user_id", ""))


# ---------------------------------------------------------------------------
# /api/health
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health(request: Request):
    try:
        server_name = await _resolve_server_name(request.app.state.http)
        return {"status": "ok", "server_name": server_name}
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"Synapse not reachable: {e}")


# ---------------------------------------------------------------------------
# /api/bots — Registry
# ---------------------------------------------------------------------------

class BotCreate(BaseModel):
    localpart: str = Field(..., min_length=1)
    displayname: str | None = None


class BotImport(BaseModel):
    mxid: str = Field(..., min_length=3)


class BotUpdate(BaseModel):
    displayname: str | None = None
    deactivated: bool | None = None


class TokenCreate(BaseModel):
    label: str | None = None
    # Lebensdauer in Millisekunden. None = "nie" (~ 100 Jahre).
    valid_for_ms: int | None = None


# Default-Lebensdauer fuer "nie" — ~100 Jahre in Millisekunden.
NEVER_EXPIRES_MS = 100 * 365 * 24 * 3600 * 1000


async def _enrich_bot(http: httpx.AsyncClient, bot: dict[str, Any]) -> dict[str, Any]:
    """Manager-Registry-Eintrag mit Live-Daten aus Synapse anreichern."""
    r = await _admin_get(http, f"/_synapse/admin/v2/users/{_q(bot['mxid'])}")
    if r.status_code == 200:
        synapse = r.json()
        bot["displayname"] = synapse.get("displayname") or bot.get("displayname")
        bot["deactivated"] = bool(synapse.get("deactivated"))
        bot["admin"] = bool(synapse.get("admin"))
        bot["creation_ts"] = synapse.get("creation_ts")
        bot["user_type"] = synapse.get("user_type")
        bot["exists_in_synapse"] = True
    else:
        bot["exists_in_synapse"] = False
    return bot


@app.get("/api/bots")
async def api_list_bots(request: Request):
    bots = await list_bots()
    enriched = []
    for b in bots:
        enriched.append(await _enrich_bot(request.app.state.http, b))
    return {"bots": enriched}


@app.post("/api/bots", status_code=201)
async def api_create_bot(payload: BotCreate, request: Request):
    http = request.app.state.http
    server_name = await _resolve_server_name(http)
    localpart = payload.localpart.strip().lstrip("@").lower()
    if not localpart:
        raise HTTPException(400, "localpart darf nicht leer sein")
    mxid = f"@{localpart}:{server_name}"

    if await get_bot(mxid):
        raise HTTPException(409, f"Bot {mxid} ist bereits in der Registry")

    r = await _admin_put(http, f"/_synapse/admin/v2/users/{_q(mxid)}", {
        "displayname": payload.displayname or localpart,
        "user_type": "bot",
        "password": _gen_password(),
    })
    if r.status_code not in (200, 201):
        raise HTTPException(r.status_code, f"Synapse: {r.text}")

    await add_bot(mxid, localpart, payload.displayname or localpart)
    bot = await get_bot(mxid)
    return await _enrich_bot(http, bot)


@app.post("/api/bots/import", status_code=201)
async def api_import_bot(payload: BotImport, request: Request):
    """Bestehenden Synapse-User in die Registry uebernehmen."""
    http = request.app.state.http
    mxid = payload.mxid.strip()
    if not mxid.startswith("@") or ":" not in mxid:
        raise HTTPException(400, "MXID muss im Format @localpart:server.tld sein")

    r = await _admin_get(http, f"/_synapse/admin/v2/users/{_q(mxid)}")
    if r.status_code != 200:
        raise HTTPException(404, f"User {mxid} existiert nicht in Synapse")
    syn = r.json()

    if await get_bot(mxid):
        raise HTTPException(409, f"Bot {mxid} ist bereits in der Registry")

    await add_bot(mxid, _localpart_from_mxid(mxid), syn.get("displayname"))
    bot = await get_bot(mxid)
    return await _enrich_bot(http, bot)


@app.get("/api/bots/{mxid}")
async def api_get_bot(mxid: str, request: Request):
    bot = await get_bot(mxid)
    if not bot:
        raise HTTPException(404, f"Bot {mxid} nicht in der Registry")
    return await _enrich_bot(request.app.state.http, bot)


@app.put("/api/bots/{mxid}")
async def api_update_bot(mxid: str, payload: BotUpdate, request: Request):
    http = request.app.state.http
    bot = await get_bot(mxid)
    if not bot:
        raise HTTPException(404, f"Bot {mxid} nicht in der Registry")

    synapse_patch: dict[str, Any] = {}
    if payload.displayname is not None:
        synapse_patch["displayname"] = payload.displayname
    if payload.deactivated is not None:
        synapse_patch["deactivated"] = payload.deactivated

    if synapse_patch:
        r = await _admin_put(http, f"/_synapse/admin/v2/users/{_q(mxid)}", synapse_patch)
        if r.status_code not in (200, 201):
            raise HTTPException(r.status_code, f"Synapse: {r.text}")

    db_patch: dict[str, Any] = {}
    if payload.displayname is not None:
        db_patch["displayname"] = payload.displayname
    if payload.deactivated is not None:
        db_patch["deactivated"] = 1 if payload.deactivated else 0
    if db_patch:
        await update_bot(mxid, **db_patch)

    return await _enrich_bot(http, await get_bot(mxid))


@app.delete("/api/bots/{mxid}")
async def api_remove_bot(mxid: str):
    """Entfernt den Bot NUR aus der Manager-Registry. Synapse-User bleibt."""
    if not await get_bot(mxid):
        raise HTTPException(404, f"Bot {mxid} nicht in der Registry")
    await remove_bot(mxid)
    return {"status": "removed-from-registry"}


@app.get("/api/bots/{mxid}/rooms")
async def api_bot_rooms(mxid: str, request: Request):
    """Beigetretene Raeume eines Bots."""
    if not await get_bot(mxid):
        raise HTTPException(404, f"Bot {mxid} nicht in der Registry")
    r = await _admin_get(request.app.state.http,
                         f"/_synapse/admin/v1/users/{_q(mxid)}/joined_rooms")
    if r.status_code != 200:
        raise HTTPException(r.status_code, f"Synapse: {r.text}")
    return r.json()


# ---------------------------------------------------------------------------
# /api/bots/{mxid}/tokens — Token-Verwaltung
# ---------------------------------------------------------------------------

async def _fetch_devices(http: httpx.AsyncClient, mxid: str) -> dict[str, dict]:
    """device_id -> device-Dict aus Synapse."""
    r = await _admin_get(http, f"/_synapse/admin/v2/users/{_q(mxid)}/devices")
    if r.status_code != 200:
        return {}
    return {d["device_id"]: d for d in r.json().get("devices", [])}


@app.get("/api/bots/{mxid}/tokens")
async def api_list_tokens(mxid: str, request: Request):
    """Alle vom Manager fuer diesen Bot ausgestellten Tokens (Klartext).

    Mit Synapse-Devices-Daten angereichert: last_seen_ts, last_seen_ip,
    und ein Flag, ob das zugehoerige Device in Synapse noch existiert.
    """
    if not await get_bot(mxid):
        raise HTTPException(404, f"Bot {mxid} nicht in der Registry")
    tokens = await list_tokens(mxid)
    devices = await _fetch_devices(request.app.state.http, mxid)
    for t in tokens:
        dev = devices.get(t["device_id"])
        t["last_seen_ts"] = dev.get("last_seen_ts") if dev else None
        t["last_seen_ip"] = dev.get("last_seen_ip") if dev else None
        t["device_present"] = dev is not None
    return {"tokens": tokens}


@app.post("/api/bots/{mxid}/tokens", status_code=201)
async def api_create_token(mxid: str, payload: TokenCreate, request: Request):
    """Erzeugt einen neuen Access-Token via Synapse-Admin-Login-as-User und
    speichert ihn Klartext in der SQLite-Registry.

    Ohne valid_for_ms wird die maximale Lebensdauer (~100 Jahre) gesetzt —
    der Synapse-Default waere sonst 1 Stunde.
    """
    http = request.app.state.http
    if not await get_bot(mxid):
        raise HTTPException(404, f"Bot {mxid} nicht in der Registry")

    valid_for_ms = payload.valid_for_ms if payload.valid_for_ms else NEVER_EXPIRES_MS
    valid_until_ms = int(time.time() * 1000) + valid_for_ms

    r = await _admin_post(http, f"/_synapse/admin/v1/users/{_q(mxid)}/login",
                          {"valid_until_ms": valid_until_ms})
    if r.status_code != 200:
        raise HTTPException(r.status_code, f"Synapse: {r.text}")
    access_token = r.json().get("access_token")
    if not access_token:
        raise HTTPException(502, "Synapse lieferte keinen access_token")

    # device_id via /whoami ermitteln — der Admin-Login-Endpoint gibt sie selbst nicht zurueck.
    w = await http.get(
        f"{SYNAPSE_URL}/_matrix/client/v3/account/whoami",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    if w.status_code != 200:
        raise HTTPException(502, "Konnte device_id nach Login nicht ermitteln")
    device_id = w.json().get("device_id", "")

    # Device-Display-Name auf das Label setzen, damit der Token in Element/Ketesa
    # auch erkennbar ist (nicht nur im Manager).
    if payload.label:
        await http.put(
            f"{SYNAPSE_URL}/_synapse/admin/v2/users/{_q(mxid)}/devices/{_q(device_id)}",
            headers=ADMIN_HEADERS,
            json={"display_name": payload.label},
        )

    token_id = await add_token(
        mxid=mxid,
        device_id=device_id,
        access_token=access_token,
        label=payload.label,
        valid_until_ms=valid_until_ms,
    )

    return {
        "id": token_id,
        "mxid": mxid,
        "device_id": device_id,
        "access_token": access_token,
        "label": payload.label,
        "valid_until_ms": valid_until_ms,
        "created_at": int(time.time() * 1000),
    }


@app.delete("/api/bots/{mxid}/tokens/{token_id}")
async def api_delete_token(mxid: str, token_id: int, request: Request):
    """Loescht das Synapse-Device (invalidiert den Token) und entfernt den
    Eintrag aus der Registry. Wenn das Device in Synapse schon weg ist
    (z.B. manuell ueber Ketesa geloescht), trotzdem aus der DB entfernen.
    """
    http = request.app.state.http
    tok = await get_token(mxid, token_id)
    if not tok:
        raise HTTPException(404, "Token nicht gefunden")

    r = await http.delete(
        f"{SYNAPSE_URL}/_synapse/admin/v2/users/{_q(mxid)}/devices/{_q(tok['device_id'])}",
        headers=ADMIN_HEADERS,
    )
    if r.status_code not in (200, 204, 404):
        raise HTTPException(r.status_code, f"Synapse: {r.text}")

    await remove_token(mxid, token_id)
    return {"status": "deleted"}


# ---------------------------------------------------------------------------
# /api/wizard/setup-bot — Bot + Token + Raum + Einladungen in einem Rutsch
# ---------------------------------------------------------------------------

class WizardInvite(BaseModel):
    mxid: str
    power_level: int = 0  # 0 = Standard, 100 = Admin


class WizardRoom(BaseModel):
    name: str
    topic: str | None = None
    encrypted: bool = False
    public: bool = False
    invites: list[WizardInvite] = []


class WizardSetup(BaseModel):
    localpart: str
    displayname: str | None = None
    token_label: str | None = None
    # None oder 0 = "nie" (~100 Jahre).
    token_valid_for_ms: int | None = None
    room: WizardRoom


@app.post("/api/wizard/setup-bot")
async def api_wizard_setup_bot(payload: WizardSetup, request: Request):
    """Orchestriert: Bot anlegen -> Token erzeugen -> Raum als Bot anlegen
    inkl. Invites und Power-Levels. Bei Fehler in einem Schritt werden
    nachfolgende Schritte uebersprungen; bereits Erstelltes bleibt bestehen,
    weil ein vollstaendiger Rollback (User loeschen) ueber die Admin-API
    nicht sauber atomar moeglich ist.
    """
    http = request.app.state.http
    steps: list[dict[str, Any]] = []
    result: dict[str, Any] = {
        "steps": steps, "bot": None, "token": None, "room": None,
    }

    def add_step(step_id: str, status: str, detail: str = "") -> None:
        steps.append({"id": step_id, "status": status, "detail": detail})

    def skip_remaining(remaining: list[str]) -> None:
        for step_id in remaining:
            add_step(step_id, "skipped", "vorheriger Schritt fehlgeschlagen")

    # ----- Step 1: Bot anlegen -----
    server_name = await _resolve_server_name(http)
    localpart = payload.localpart.strip().lstrip("@").lower()
    if not localpart:
        add_step("create_bot", "error", "localpart darf nicht leer sein")
        skip_remaining(["create_token", "create_room"])
        return result
    mxid = f"@{localpart}:{server_name}"

    if await get_bot(mxid):
        add_step("create_bot", "error", f"Bot {mxid} ist bereits in der Registry")
        skip_remaining(["create_token", "create_room"])
        return result

    r = await _admin_put(http, f"/_synapse/admin/v2/users/{_q(mxid)}", {
        "displayname": payload.displayname or localpart,
        "user_type": "bot",
        "password": _gen_password(),
    })
    if r.status_code not in (200, 201):
        add_step("create_bot", "error", f"Synapse: {r.text}")
        skip_remaining(["create_token", "create_room"])
        return result
    await add_bot(mxid, localpart, payload.displayname or localpart)
    result["bot"] = await _enrich_bot(http, await get_bot(mxid))
    add_step("create_bot", "ok", mxid)

    # ----- Step 2: Token erzeugen -----
    valid_for_ms = payload.token_valid_for_ms or NEVER_EXPIRES_MS
    valid_until_ms = int(time.time() * 1000) + valid_for_ms

    r = await _admin_post(http, f"/_synapse/admin/v1/users/{_q(mxid)}/login",
                          {"valid_until_ms": valid_until_ms})
    if r.status_code != 200:
        add_step("create_token", "error", f"Synapse: {r.text}")
        skip_remaining(["create_room"])
        return result
    access_token = r.json().get("access_token")
    if not access_token:
        add_step("create_token", "error", "Synapse lieferte keinen access_token")
        skip_remaining(["create_room"])
        return result

    w = await http.get(
        f"{SYNAPSE_URL}/_matrix/client/v3/account/whoami",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    if w.status_code != 200:
        add_step("create_token", "error", "device_id konnte nicht ermittelt werden")
        skip_remaining(["create_room"])
        return result
    device_id = w.json().get("device_id", "")

    if payload.token_label:
        # display_name-PUT ist Best-Effort: Fehler hier kippt nicht den ganzen Schritt.
        await http.put(
            f"{SYNAPSE_URL}/_synapse/admin/v2/users/{_q(mxid)}/devices/{_q(device_id)}",
            headers=ADMIN_HEADERS,
            json={"display_name": payload.token_label},
        )

    token_id = await add_token(
        mxid=mxid, device_id=device_id, access_token=access_token,
        label=payload.token_label, valid_until_ms=valid_until_ms,
    )
    result["token"] = {
        "id": token_id, "access_token": access_token,
        "label": payload.token_label, "valid_until_ms": valid_until_ms,
        "device_id": device_id,
    }
    add_step("create_token", "ok", f"Device {device_id}")

    # ----- Step 3: Raum anlegen (mit Invites und Power-Levels in einem Rutsch) -----
    initial_state: list[dict] = []
    if payload.room.encrypted:
        initial_state.append({
            "type": "m.room.encryption",
            "state_key": "",
            "content": {"algorithm": "m.megolm.v1.aes-sha2"},
        })

    user_pls: dict[str, int] = {mxid: 100}  # Bot ist Creator
    for inv in payload.room.invites:
        if inv.power_level > 0:
            user_pls[inv.mxid] = inv.power_level

    body: dict[str, Any] = {
        "name": payload.room.name,
        "invite": [inv.mxid for inv in payload.room.invites],
        "preset": "public_chat" if payload.room.public else "private_chat",
        "visibility": "public" if payload.room.public else "private",
        "initial_state": initial_state,
        "power_level_content_override": {"users": user_pls},
    }
    if payload.room.topic:
        body["topic"] = payload.room.topic

    r = await http.post(
        f"{SYNAPSE_URL}/_matrix/client/v3/createRoom",
        headers={"Authorization": f"Bearer {access_token}",
                 "Content-Type": "application/json"},
        json=body,
    )
    if r.status_code != 200:
        add_step("create_room", "error", f"Synapse: {r.text}")
        return result

    room_id = r.json().get("room_id")
    n_invites = len(payload.room.invites)
    n_admins = sum(1 for inv in payload.room.invites if inv.power_level >= 100)
    detail = f"{room_id} ({n_invites} eingeladen"
    if n_admins:
        detail += f", {n_admins} davon Admin"
    detail += ")"
    result["room"] = {
        "room_id": room_id,
        "matrix_to": f"https://matrix.to/#/{room_id}",
    }
    add_step("create_room", "ok", detail)

    return result


# ---------------------------------------------------------------------------
# /api/default-users — vorausgewaehlte Invite-Liste fuer Raum-Anlage / Wizard
# ---------------------------------------------------------------------------

class DefaultUserIn(BaseModel):
    mxid: str
    default_admin: bool = False


def _validate_mxid(mxid: str) -> str:
    mxid = mxid.strip()
    if not mxid.startswith("@") or ":" not in mxid:
        raise HTTPException(400, "MXID muss Format @localpart:server.tld haben")
    return mxid


@app.get("/api/default-users")
async def api_list_default_users():
    return {"users": await list_default_users()}


@app.post("/api/default-users", status_code=201)
async def api_upsert_default_user(payload: DefaultUserIn):
    mxid = _validate_mxid(payload.mxid)
    await upsert_default_user(mxid, payload.default_admin)
    return {"mxid": mxid, "default_admin": payload.default_admin}


@app.delete("/api/default-users/{mxid:path}")
async def api_remove_default_user(mxid: str):
    await remove_default_user(mxid)
    return {"status": "deleted"}


# ---------------------------------------------------------------------------
# /api/discovery — fuer Bot-Import-Modal
# ---------------------------------------------------------------------------

@app.get("/api/discovery/synapse-users")
async def api_discover_users(request: Request, user_type: str | None = None):
    """Liste aller Synapse-User; optional nach user_type gefiltert.

    Frontend nutzt das fuer den Import-Modal: zeigt alle Synapse-User mit
    user_type=bot, die noch nicht in der Manager-Registry sind.
    """
    params = {"limit": "500"}
    if user_type:
        params["user_type"] = user_type
    r = await _admin_get(request.app.state.http,
                         "/_synapse/admin/v2/users", params=params)
    if r.status_code != 200:
        raise HTTPException(r.status_code, f"Synapse: {r.text}")
    data = r.json()
    managed_mxids = {b["mxid"] for b in await list_bots()}
    for u in data.get("users", []):
        u["managed"] = u.get("name") in managed_mxids
    return data


# ---------------------------------------------------------------------------
# /api/synapse + /api/client — generische Proxies (Altbestand, weiterhin genutzt)
# ---------------------------------------------------------------------------

def _proxy_response(upstream: httpx.Response) -> Response:
    headers = {
        k: v for k, v in upstream.headers.items()
        if k.lower() not in _FORWARD_RESPONSE_BLOCKLIST
    }
    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        headers=headers,
        media_type=upstream.headers.get("content-type"),
    )


async def _proxy(request: Request, target_url: str, *, authorization: str) -> Response:
    body = await request.body()
    fwd_headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in _FORWARD_REQUEST_BLOCKLIST and k.lower() != "authorization"
    }
    fwd_headers["Authorization"] = authorization
    try:
        upstream = await request.app.state.http.request(
            method=request.method,
            url=target_url,
            content=body if body else None,
            headers=fwd_headers,
            params=dict(request.query_params),
        )
    except httpx.HTTPError as e:
        return JSONResponse(
            status_code=502,
            content={"errcode": "M_BAD_GATEWAY", "error": f"upstream error: {e}"},
        )
    return _proxy_response(upstream)


@app.api_route("/api/synapse/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy_synapse(path: str, request: Request):
    target = f"{SYNAPSE_URL}/_synapse/admin/{path}"
    return await _proxy(request, target, authorization=f"Bearer {SYNAPSE_ADMIN_TOKEN}")


@app.api_route("/api/client/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy_client(path: str, request: Request):
    incoming_auth = request.headers.get("authorization")
    if not incoming_auth:
        return JSONResponse(
            status_code=401,
            content={"errcode": "M_MISSING_TOKEN", "error": "Authorization header required"},
        )
    target = f"{SYNAPSE_URL}/_matrix/client/v3/{path}"
    return await _proxy(request, target, authorization=incoming_auth)


# ---------------------------------------------------------------------------
# Statische Files + SPA-Fallback
# ---------------------------------------------------------------------------

if STATIC_DIR.exists():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/{full_path:path}")
    async def spa_fallback(full_path: str):
        index = STATIC_DIR / "index.html"
        if not index.exists():
            raise HTTPException(status_code=404, detail="Frontend not built")
        return FileResponse(index)
else:
    @app.get("/")
    async def root_dev():
        return {
            "status": "ok",
            "note": "STATIC_DIR not present — running in dev mode, frontend served by Vite.",
        }
