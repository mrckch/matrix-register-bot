import { useState, useEffect, useCallback } from "react";
import { Icon } from "./Icon.jsx";
import { apiGet, apiPost } from "../api.js";
import { SetupWizard } from "./SetupWizard.jsx";
import {
  labelStyle, inputStyle, btnPrimaryStyle, btnGhostStyle, badgeStyle,
  modalOverlayStyle, modalStyle,
} from "../styles.js";

export function BotList({ config, onSelectBot, onOpenSettings, onOpenAudit, addToast }) {
  const [bots, setBots] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showCreate, setShowCreate] = useState(false);
  const [showImport, setShowImport] = useState(false);
  const [showWizard, setShowWizard] = useState(false);
  const [newUsername, setNewUsername] = useState("");
  const [newDisplayname, setNewDisplayname] = useState("");
  const [creating, setCreating] = useState(false);

  const loadBots = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiGet("/bots");
      setBots(data.bots || []);
    } catch (e) {
      addToast("Fehler beim Laden: " + e.message, "error");
    } finally {
      setLoading(false);
    }
  }, [addToast]);

  useEffect(() => { loadBots(); }, [loadBots]);

  async function createBot() {
    if (!newUsername) return;
    setCreating(true);
    try {
      await apiPost("/bots", {
        localpart: newUsername,
        displayname: newDisplayname || newUsername,
      });
      addToast(`Bot @${newUsername} erstellt!`, "success");
      setShowCreate(false);
      setNewUsername("");
      setNewDisplayname("");
      loadBots();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    } finally {
      setCreating(false);
    }
  }

  return (
    <div style={{ padding: "32px 32px 32px", maxWidth: 800, margin: "0 auto" }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 32 }}>
        <div>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
            <div style={{ color: "var(--accent)" }}><Icon name="bot" size={18} /></div>
            <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, letterSpacing: 3, color: "var(--muted)", textTransform: "uppercase" }}>
              {config.serverName}
            </span>
          </div>
          <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 26, fontWeight: 800, margin: 0, color: "var(--text)" }}>Bots</h1>
        </div>
        <div style={{ display: "flex", gap: 10 }}>
          <button onClick={onOpenAudit} style={btnGhostStyle} title="Audit-Log">
            <Icon name="activity" size={15} />
          </button>
          <button onClick={onOpenSettings} style={btnGhostStyle} title="Standard-Nutzer">
            <Icon name="users" size={15} />
          </button>
          <button onClick={loadBots} style={btnGhostStyle} title="Neu laden">
            <Icon name="refresh" size={15} />
          </button>
          <button onClick={() => setShowImport(true)} style={btnGhostStyle} title="Bestehenden Bot importieren">
            <Icon name="download" size={15} /> Importieren
          </button>
          <button onClick={() => setShowCreate(true)} style={btnGhostStyle} title="Nur Bot anlegen, ohne Token/Raum">
            <Icon name="plus" size={15} /> Neuer Bot
          </button>
          <button onClick={() => setShowWizard(true)} style={btnPrimaryStyle} title="Bot + Token + Raum + Einladungen in einem Rutsch">
            <Icon name="bot" size={15} /> Bot + Raum
          </button>
        </div>
      </div>

      {showCreate && (
        <div style={modalOverlayStyle}>
          <div style={modalStyle}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 24 }}>
              <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 20, fontWeight: 700, margin: 0, color: "var(--text)" }}>Bot erstellen</h2>
              <button onClick={() => setShowCreate(false)} style={btnGhostStyle}><Icon name="x" size={16} /></button>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
              <div>
                <label style={labelStyle}>Username (ohne @domain)</label>
                <input style={inputStyle} value={newUsername}
                  onChange={e => setNewUsername(e.target.value.toLowerCase().replace(/\s/g, "_"))}
                  placeholder="mein_bot" autoFocus />
              </div>
              <div>
                <label style={labelStyle}>Anzeigename</label>
                <input style={inputStyle} value={newDisplayname}
                  onChange={e => setNewDisplayname(e.target.value)}
                  placeholder="Mein Bot" />
              </div>
              <div style={{ display: "flex", gap: 10, marginTop: 4 }}>
                <button onClick={() => setShowCreate(false)} style={{ ...btnGhostStyle, flex: 1, justifyContent: "center" }}>Abbrechen</button>
                <button onClick={createBot} disabled={creating || !newUsername} style={{ ...btnPrimaryStyle, flex: 2, justifyContent: "center" }}>
                  {creating ? "Erstelle…" : "Bot erstellen"}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {showImport && (
        <ImportModal
          onClose={() => setShowImport(false)}
          onImported={() => { setShowImport(false); loadBots(); }}
          addToast={addToast}
        />
      )}

      {showWizard && (
        <SetupWizard
          config={config}
          onClose={() => setShowWizard(false)}
          onDone={loadBots}
          addToast={addToast}
        />
      )}

      {loading ? (
        <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 48 }}>Lade Bots…</div>
      ) : bots.length === 0 ? (
        <div style={{ textAlign: "center", padding: 64, color: "var(--muted)" }}>
          <div style={{ marginBottom: 12, opacity: 0.3 }}><Icon name="bot" size={48} /></div>
          <p style={{ fontFamily: "'Space Mono', monospace", fontSize: 13 }}>
            Noch keine Bots in der Registry. „Importieren" für bestehende Bots, „Neuer Bot" für neue.
          </p>
          <div style={{ display: "flex", gap: 10, justifyContent: "center", marginTop: 16 }}>
            <button onClick={() => setShowImport(true)} style={btnGhostStyle}>
              <Icon name="download" size={14} /> Importieren
            </button>
            <button onClick={() => setShowCreate(true)} style={btnPrimaryStyle}>
              <Icon name="plus" size={14} /> Neuer Bot
            </button>
          </div>
        </div>
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(230px, 1fr))", gap: 14 }}>
          {bots.map((bot) => (
            <BotCard key={bot.mxid} bot={bot} onClick={() => onSelectBot(bot)} />
          ))}
        </div>
      )}
    </div>
  );
}

function BotCard({ bot, onClick }) {
  const localpart = bot.localpart || bot.mxid.split(":")[0].replace("@", "");
  const initial = (bot.displayname || localpart)[0]?.toUpperCase() || "B";
  const deactivated = bot.deactivated || !bot.exists_in_synapse;

  return (
    <div onClick={onClick} style={{
      background: "var(--surface)",
      border: "1px solid var(--border)",
      borderRadius: 12,
      padding: "18px 20px",
      cursor: "pointer",
      transition: "border-color 0.15s, transform 0.15s, box-shadow 0.15s",
    }}
      onMouseEnter={e => { e.currentTarget.style.borderColor = "var(--accent)"; e.currentTarget.style.transform = "translateY(-2px)"; e.currentTarget.style.boxShadow = "0 8px 32px rgba(0,200,150,0.1)"; }}
      onMouseLeave={e => { e.currentTarget.style.borderColor = "var(--border)"; e.currentTarget.style.transform = "translateY(0)"; e.currentTarget.style.boxShadow = "none"; }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
        <div style={{
          width: 40, height: 40, borderRadius: 10, background: "var(--accent-dim)",
          display: "flex", alignItems: "center", justifyContent: "center",
          fontFamily: "'Syne', sans-serif", fontWeight: 800, fontSize: 18, color: "var(--accent)",
          flexShrink: 0, overflow: "hidden",
        }}>
          {bot.avatar_url ? (
            <img
              src={`/api/media-thumbnail?mxc=${encodeURIComponent(bot.avatar_url)}&size=80`}
              alt=""
              style={{ width: "100%", height: "100%", objectFit: "cover" }}
              onError={e => { e.currentTarget.style.display = "none"; }}
            />
          ) : initial}
        </div>
        <div style={{ overflow: "hidden" }}>
          <div style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 15, color: "var(--text)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {bot.displayname || localpart}
          </div>
          <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, color: "var(--muted)", marginTop: 1 }}>@{localpart}</div>
        </div>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap" }}>
        <span style={{ ...badgeStyle, background: deactivated ? "rgba(255,77,77,0.15)" : "rgba(0,200,150,0.12)", color: deactivated ? "#ff4d4d" : "var(--accent)", border: `1px solid ${deactivated ? "rgba(255,77,77,0.3)" : "rgba(0,200,150,0.3)"}` }}>
          {!bot.exists_in_synapse ? "verwaist" : bot.deactivated ? "deaktiviert" : "aktiv"}
        </span>
        <span style={{ ...badgeStyle }}>bot</span>
      </div>
    </div>
  );
}

function ImportModal({ onClose, onImported, addToast }) {
  const [candidates, setCandidates] = useState(null);
  const [busy, setBusy] = useState(null);
  const [filter, setFilter] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const data = await apiGet("/discovery/synapse-users?user_type=bot");
        const unmanaged = (data.users || []).filter(u => !u.managed);
        setCandidates(unmanaged);
      } catch (e) {
        addToast("Discovery fehlgeschlagen: " + e.message, "error");
        setCandidates([]);
      }
    })();
  }, [addToast]);

  async function importBot(mxid) {
    setBusy(mxid);
    try {
      await apiPost("/bots/import", { mxid });
      addToast(`${mxid} importiert`, "success");
      onImported();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    } finally {
      setBusy(null);
    }
  }

  const filtered = (candidates || []).filter(u =>
    !filter || (u.name + " " + (u.displayname || "")).toLowerCase().includes(filter.toLowerCase())
  );

  return (
    <div style={modalOverlayStyle}>
      <div style={{ ...modalStyle, maxWidth: 560 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
          <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 20, fontWeight: 700, margin: 0, color: "var(--text)" }}>Bestehende Bots importieren</h2>
          <button onClick={onClose} style={btnGhostStyle}><Icon name="x" size={16} /></button>
        </div>
        <p style={{ color: "var(--muted)", fontSize: 12, marginBottom: 16, fontFamily: "'Space Mono', monospace", lineHeight: 1.6 }}>
          Synapse-User mit <code>user_type=bot</code>, die noch nicht in der Manager-Registry sind.
          Per Klick auf „Importieren" landen sie in der Bot-Liste.
        </p>
        <input
          style={{ ...inputStyle, marginBottom: 12 }}
          placeholder="Filter (Username oder Anzeigename)"
          value={filter}
          onChange={e => setFilter(e.target.value)}
        />
        {candidates === null ? (
          <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 12, padding: 24, textAlign: "center" }}>
            Lade Kandidaten…
          </div>
        ) : filtered.length === 0 ? (
          <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 12, padding: 24, textAlign: "center" }}>
            Keine importierbaren Bots gefunden.
          </div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 8, maxHeight: 360, overflowY: "auto" }}>
            {filtered.map(u => (
              <div key={u.name} style={{
                display: "flex", alignItems: "center", gap: 12,
                padding: "10px 14px", background: "var(--bg)", border: "1px solid var(--border)", borderRadius: 8,
              }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 13, color: "var(--text)" }}>
                    {u.displayname || u.name.split(":")[0].replace("@", "")}
                  </div>
                  <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, color: "var(--muted)" }}>{u.name}</div>
                </div>
                <button
                  onClick={() => importBot(u.name)}
                  disabled={busy === u.name}
                  style={{ ...btnPrimaryStyle, padding: "6px 12px", fontSize: 12 }}
                >
                  {busy === u.name ? "…" : "Importieren"}
                </button>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
