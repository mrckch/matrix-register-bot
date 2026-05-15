import { useState, useEffect, useCallback } from "react";
import { health, apiGet, apiPost } from "./api.js";
import { Toast, useToast } from "./components/Toast.jsx";
import { SettingsScreen } from "./components/SettingsScreen.jsx";
import { BotList } from "./components/BotList.jsx";
import { BotDetail } from "./components/BotDetail.jsx";

const LEGACY_LS_KEY = "matrix_bot_manager_config_v2";

const GLOBAL_CSS = `
@import url('https://fonts.googleapis.com/css2?family=Syne:wght@400;700;800&family=Space+Mono:wght@400;700&family=IBM+Plex+Mono&display=swap');
:root {
  --bg: #0d0d12;
  --surface: #13131a;
  --border: #1e1e2e;
  --text: #e8e8f0;
  --muted: #5a5a7a;
  --accent: #00c896;
  --accent-dim: rgba(0,200,150,0.08);
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--text); }
input:focus { border-color: var(--accent) !important; }
button:disabled { opacity: 0.45; cursor: not-allowed; }
@keyframes slideIn {
  from { opacity: 0; transform: translateX(16px); }
  to   { opacity: 1; transform: translateX(0); }
}
::-webkit-scrollbar { width: 6px; }
::-webkit-scrollbar-track { background: var(--bg); }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
`;

// One-time-Migration: alte LocalStorage-Liste ins Backend kippen, dann
// LocalStorage leeren. Laeuft nur, wenn das Backend leer ist und die
// LocalStorage einen alten Stand hat.
async function migrateLegacyDefaultUsers(serverList) {
  if (serverList.length > 0) return;
  let legacy;
  try {
    legacy = JSON.parse(localStorage.getItem(LEGACY_LS_KEY) || "null");
  } catch {
    return;
  }
  const oldUsers = legacy?.defaultUsers;
  if (!Array.isArray(oldUsers) || oldUsers.length === 0) return;

  for (const u of oldUsers) {
    if (!u.mxid) continue;
    try {
      await apiPost("/default-users", { mxid: u.mxid, default_admin: !!u.defaultAdmin });
    } catch {
      // Schlucken — wenn ein einzelner User nicht migrierbar ist, weitermachen.
    }
  }
  localStorage.removeItem(LEGACY_LS_KEY);
}

export default function App() {
  const [config, setConfig] = useState(null);
  const [bootError, setBootError] = useState(null);
  const [selectedBot, setSelectedBot] = useState(null);
  const [showSettings, setShowSettings] = useState(false);
  const { toasts, addToast } = useToast();

  const refreshDefaultUsers = useCallback(async () => {
    const data = await apiGet("/default-users");
    setConfig(prev => prev ? { ...prev, defaultUsers: data.users || [] } : prev);
    return data.users || [];
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const info = await health();
        if (cancelled) return;
        const data = await apiGet("/default-users");
        if (cancelled) return;
        let users = data.users || [];
        await migrateLegacyDefaultUsers(users);
        if (users.length === 0) {
          // Nach Migration: nochmal lesen
          const after = await apiGet("/default-users");
          users = after.users || [];
        }
        if (cancelled) return;
        setConfig({
          serverName: info.server_name || "(unbekannt)",
          defaultUsers: users,
        });
      } catch (e) {
        if (cancelled) return;
        setBootError(e.message || String(e));
      }
    })();
    return () => { cancelled = true; };
  }, []);

  let screen;
  if (bootError) {
    screen = (
      <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", padding: 32 }}>
        <div style={{ maxWidth: 480, background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 16, padding: 32 }}>
          <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 22, fontWeight: 800, marginBottom: 12 }}>Backend nicht erreichbar</h1>
          <p style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 12, lineHeight: 1.6, marginBottom: 16 }}>
            Konnte <code>/api/health</code> nicht erreichen. Pruefe, ob der Container laeuft und ob die Env-Variablen
            <code> SYNAPSE_URL</code> und <code> SYNAPSE_ADMIN_TOKEN</code> gesetzt sind.
          </p>
          <pre style={{ background: "var(--bg)", padding: 12, borderRadius: 8, fontSize: 11, color: "#ff4d4d", overflowX: "auto" }}>{bootError}</pre>
        </div>
      </div>
    );
  } else if (!config) {
    screen = (
      <div style={{ minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13 }}>
        Verbinde mit Backend…
      </div>
    );
  } else if (showSettings) {
    screen = <SettingsScreen config={config} onRefresh={refreshDefaultUsers} onBack={() => setShowSettings(false)} addToast={addToast} />;
  } else if (selectedBot) {
    screen = <BotDetail bot={selectedBot} config={config} onBack={() => setSelectedBot(null)} addToast={addToast} />;
  } else {
    screen = (
      <BotList
        config={config}
        onSelectBot={setSelectedBot}
        onOpenSettings={() => setShowSettings(true)}
        addToast={addToast}
      />
    );
  }

  return (
    <>
      <style>{GLOBAL_CSS}</style>
      {screen}
      <Toast toasts={toasts} />
    </>
  );
}
