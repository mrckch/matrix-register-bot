"""
Matrix Bot Manager — Backend-Proxy.

Funktion:
  - /api/synapse/*  -> {SYNAPSE_URL}/_synapse/admin/*  (Admin-Token serverseitig)
  - /api/client/*   -> {SYNAPSE_URL}/_matrix/client/v3/*  (Bot-Token aus Request)
  - /api/health     -> Info (server_name aus Synapse whoami)
  - alles andere    -> Statisches Frontend (SPA-Fallback auf index.html)

Wichtige Architektur-Entscheidung:
  Der Admin-Token verlaesst diesen Container NIE. Das Frontend bekommt ihn
  nie zu sehen und der Browser hat ihn nicht im localStorage. Damit kann
  Synapse auf das interne Docker-Netz beschraenkt bleiben.
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SYNAPSE_URL = os.environ.get("SYNAPSE_URL", "").rstrip("/")
SYNAPSE_ADMIN_TOKEN = os.environ.get("SYNAPSE_ADMIN_TOKEN", "")
STATIC_DIR = Path(os.environ.get("STATIC_DIR", "/app/static"))

# Header, die wir aus dem Client-Request NICHT weiterreichen — bestimmte
# hop-by-hop-Header bzw. Header, die den Backend-Call kaputt machen wuerden.
_FORWARD_REQUEST_BLOCKLIST = {
    "host", "connection", "content-length", "transfer-encoding",
    "accept-encoding",  # uvicorn/httpx setzen das selbst
}
# Header, die wir aus der Synapse-Response NICHT zurueckgeben (hop-by-hop).
_FORWARD_RESPONSE_BLOCKLIST = {
    "transfer-encoding", "content-encoding", "connection", "keep-alive",
}


# ---------------------------------------------------------------------------
# Lifecycle: gemeinsamer httpx-Client pro App-Instanz
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    if not SYNAPSE_URL:
        raise RuntimeError("SYNAPSE_URL is not set")
    if not SYNAPSE_ADMIN_TOKEN:
        raise RuntimeError("SYNAPSE_ADMIN_TOKEN is not set")
    timeout = httpx.Timeout(connect=10.0, read=30.0, write=30.0, pool=5.0)
    app.state.http = httpx.AsyncClient(timeout=timeout)
    try:
        yield
    finally:
        await app.state.http.aclose()


app = FastAPI(lifespan=lifespan, title="Matrix Bot Manager")


# ---------------------------------------------------------------------------
# Health / Info
# ---------------------------------------------------------------------------

async def _resolve_server_name(http: httpx.AsyncClient) -> str:
    """Frage Synapse selbst nach dem server_name (aus whoami des Admin-Tokens)."""
    r = await http.get(
        f"{SYNAPSE_URL}/_matrix/client/v3/account/whoami",
        headers={"Authorization": f"Bearer {SYNAPSE_ADMIN_TOKEN}"},
    )
    r.raise_for_status()
    user_id = r.json().get("user_id", "")
    # @admin:matrix.example.com -> matrix.example.com
    if ":" in user_id:
        return user_id.split(":", 1)[1]
    return ""


@app.get("/api/health")
async def health(request: Request):
    try:
        server_name = await _resolve_server_name(request.app.state.http)
        return {"status": "ok", "server_name": server_name}
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"Synapse not reachable: {e}")


# ---------------------------------------------------------------------------
# Proxy-Routen
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

    # Original-Request-Header weitergeben, ausser Blockliste und Authorization.
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


@app.api_route(
    "/api/synapse/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
)
async def proxy_synapse(path: str, request: Request):
    """Admin-API-Proxy: Admin-Token serverseitig anhaengen."""
    target = f"{SYNAPSE_URL}/_synapse/admin/{path}"
    return await _proxy(request, target, authorization=f"Bearer {SYNAPSE_ADMIN_TOKEN}")


@app.api_route(
    "/api/client/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH"],
)
async def proxy_client(path: str, request: Request):
    """Client-API-Proxy: Bot-Token kommt aus dem Request-Authorization-Header.

    Frontend hat den Bot-Token vorher via /api/synapse/v1/users/{mxid}/login
    geholt und reicht ihn beim createRoom-Call durch.
    """
    incoming_auth = request.headers.get("authorization")
    if not incoming_auth:
        return JSONResponse(
            status_code=401,
            content={"errcode": "M_MISSING_TOKEN", "error": "Authorization header required"},
        )
    target = f"{SYNAPSE_URL}/_matrix/client/v3/{path}"
    return await _proxy(request, target, authorization=incoming_auth)


# ---------------------------------------------------------------------------
# Statische Files (gebautes Frontend) + SPA-Fallback
# ---------------------------------------------------------------------------

if STATIC_DIR.exists():
    # StaticFiles mit html=True liefert / -> index.html
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/{full_path:path}")
    async def spa_fallback(full_path: str):
        # /api/* wird bereits weiter oben behandelt. Hier landet alles andere.
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
