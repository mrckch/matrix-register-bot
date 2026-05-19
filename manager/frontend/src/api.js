// API-Helfer fuer das Frontend.
//
// Architektur: Das Frontend spricht NICHT mehr direkt mit Synapse, sondern mit
// einem schlanken Backend-Proxy unter /api/*. Der Proxy haengt den Admin-Token
// serverseitig dran (kommt aus einer Env-Variable). Damit liegt der Token nie
// im Browser und Synapse muss auch nicht oeffentlich erreichbar sein.
//
//   /api/bots/...        ->   Manager-Registry (SQLite) + Synapse-Daten gemischt
//   /api/discovery/...   ->   Lookup gegen Synapse (z.B. user_type=bot fuer Import)
//   /api/synapse/...     ->   {SYNAPSE_URL}/_synapse/admin/...   (Admin-Token)
//   /api/client/...      ->   {SYNAPSE_URL}/_matrix/client/v3/... (Bot-Token aus Header)

async function readError(response) {
  try {
    const data = await response.json();
    if (typeof data.detail === "string") return data.detail;
    // FastAPI-Validierungsfehler: detail = Array of {loc, msg, type}
    if (Array.isArray(data.detail) && data.detail.length > 0) {
      return data.detail
        .map(d => `${(d.loc || []).slice(1).join(".") || "body"}: ${d.msg}`)
        .join(" · ");
    }
    return data.error || data.errcode || `${response.status} ${response.statusText}`;
  } catch {
    return `${response.status} ${response.statusText}`;
  }
}

async function asJson(r) {
  if (!r.ok) throw new Error(await readError(r));
  if (r.status === 204) return null;
  return r.json();
}

export async function apiGet(path) {
  return asJson(await fetch(`/api${path}`));
}

export async function apiPost(path, body = {}) {
  return asJson(await fetch(`/api${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }));
}

export async function apiPut(path, body = {}) {
  return asJson(await fetch(`/api${path}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }));
}

export async function apiDelete(path) {
  return asJson(await fetch(`/api${path}`, { method: "DELETE" }));
}

export async function apiUpload(path, file, fieldName = "file") {
  const fd = new FormData();
  fd.append(fieldName, file);
  return asJson(await fetch(`/api${path}`, { method: "POST", body: fd }));
}

// Legacy: direkter Admin-Proxy fuer Calls, die noch nicht ueber /api/bots laufen.
export async function synapseGet(path) {
  return asJson(await fetch(`/api/synapse${path}`));
}

export async function synapsePost(path, body = {}) {
  return asJson(await fetch(`/api/synapse${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }));
}

export async function synapsePut(path, body = {}) {
  return asJson(await fetch(`/api/synapse${path}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }));
}

// Client-API Call als Bot: Token im Header, das Backend reicht ihn 1:1 durch.
export async function clientPost(userToken, path, body = {}) {
  return asJson(await fetch(`/api/client${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${userToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  }));
}

export async function health() {
  return asJson(await fetch("/api/health"));
}
