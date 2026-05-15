// API-Helfer fuer das Frontend.
//
// Architektur: Das Frontend spricht NICHT mehr direkt mit Synapse, sondern mit
// einem schlanken Backend-Proxy unter /api/*. Der Proxy haengt den Admin-Token
// serverseitig dran (kommt aus einer Env-Variable). Damit liegt der Token nie
// im Browser und Synapse muss auch nicht oeffentlich erreichbar sein.
//
//   /api/synapse/...   ->   {SYNAPSE_URL}/_synapse/admin/...   (Admin-Token)
//   /api/client/...    ->   {SYNAPSE_URL}/_matrix/client/v3/... (Bot-Token aus Header)

async function readError(response) {
  try {
    const data = await response.json();
    return data.error || data.errcode || `${response.status} ${response.statusText}`;
  } catch {
    return `${response.status} ${response.statusText}`;
  }
}

export async function synapseGet(path) {
  const r = await fetch(`/api/synapse${path}`);
  if (!r.ok) throw new Error(await readError(r));
  return r.json();
}

export async function synapsePost(path, body = {}) {
  const r = await fetch(`/api/synapse${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(await readError(r));
  return r.json();
}

export async function synapsePut(path, body = {}) {
  const r = await fetch(`/api/synapse${path}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(await readError(r));
  return r.json();
}

// Client-API Call als Bot: Token wird hier im Header gesetzt, das Backend
// reicht ihn 1:1 durch (anstatt den Admin-Token zu nutzen).
export async function clientPost(userToken, path, body = {}) {
  const r = await fetch(`/api/client${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${userToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(await readError(r));
  return r.json();
}

// Health-Check zum Aufstart — zeigt, ob das Backend die Synapse-URL erreichen kann.
export async function health() {
  const r = await fetch("/api/health");
  if (!r.ok) throw new Error(await readError(r));
  return r.json();
}
