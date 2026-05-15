import { useState, useEffect, useCallback } from "react";
import { Icon } from "./Icon.jsx";
import { synapseGet, synapsePut } from "../api.js";
import {
  labelStyle, inputStyle, btnPrimaryStyle, btnGhostStyle, badgeStyle,
  modalOverlayStyle, modalStyle,
} from "../styles.js";

export function BotList({ config, onSelectBot, onOpenSettings, addToast }) {
  const [bots, setBots] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showCreate, setShowCreate] = useState(false);
  const [newUsername, setNewUsername] = useState("");
  const [newDisplayname, setNewDisplayname] = useState("");
  const [creating, setCreating] = useState(false);

  const loadBots = useCallback(async () => {
    setLoading(true);
    try {
      const data = await synapseGet("/v2/users?user_type=bot&limit=100");
      setBots(data.users || []);
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
    const mxid = `@${newUsername}:${config.serverName}`;
    try {
      await synapsePut(`/v2/users/${encodeURIComponent(mxid)}`, {
        displayname: newDisplayname || newUsername,
        user_type: "bot",
        password: Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2),
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
      {/* Header */}
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
          <button onClick={onOpenSettings} style={btnGhostStyle} title="Standard-Nutzer">
            <Icon name="users" size={15} />
          </button>
          <button onClick={loadBots} style={btnGhostStyle} title="Neu laden">
            <Icon name="refresh" size={15} />
          </button>
          <button onClick={() => setShowCreate(true)} style={btnPrimaryStyle}>
            <Icon name="plus" size={15} /> Neuer Bot
          </button>
        </div>
      </div>

      {/* Create modal */}
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
                <input style={inputStyle} value={newUsername} onChange={e => setNewUsername(e.target.value.toLowerCase().replace(/\s/g, "_"))} placeholder="mein_bot" />
              </div>
              <div>
                <label style={labelStyle}>Anzeigename</label>
                <input style={inputStyle} value={newDisplayname} onChange={e => setNewDisplayname(e.target.value)} placeholder="Mein Bot" />
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

      {/* Bot grid */}
      {loading ? (
        <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 48 }}>Lade Bots…</div>
      ) : bots.length === 0 ? (
        <div style={{ textAlign: "center", padding: 64, color: "var(--muted)" }}>
          <div style={{ marginBottom: 12, opacity: 0.3 }}><Icon name="bot" size={48} /></div>
          <p style={{ fontFamily: "'Space Mono', monospace", fontSize: 13 }}>Noch keine Bots vorhanden.</p>
          <button onClick={() => setShowCreate(true)} style={{ ...btnPrimaryStyle, marginTop: 16 }}><Icon name="plus" size={14} /> Ersten Bot erstellen</button>
        </div>
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(230px, 1fr))", gap: 14 }}>
          {bots.map((bot) => (
            <BotCard key={bot.name} bot={bot} onClick={() => onSelectBot(bot)} />
          ))}
        </div>
      )}
    </div>
  );
}

function BotCard({ bot, onClick }) {
  const localpart = bot.name.split(":")[0].replace("@", "");
  const initial = (bot.displayname || localpart)[0]?.toUpperCase() || "B";

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
          flexShrink: 0,
        }}>
          {initial}
        </div>
        <div style={{ overflow: "hidden" }}>
          <div style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 15, color: "var(--text)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {bot.displayname || localpart}
          </div>
          <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, color: "var(--muted)", marginTop: 1 }}>@{localpart}</div>
        </div>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <span style={{ ...badgeStyle, background: bot.deactivated ? "rgba(255,77,77,0.15)" : "rgba(0,200,150,0.12)", color: bot.deactivated ? "#ff4d4d" : "var(--accent)", border: `1px solid ${bot.deactivated ? "rgba(255,77,77,0.3)" : "rgba(0,200,150,0.3)"}` }}>
          {bot.deactivated ? "deaktiviert" : "aktiv"}
        </span>
        <span style={{ ...badgeStyle }}>bot</span>
      </div>
    </div>
  );
}
