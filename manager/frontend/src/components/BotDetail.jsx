import { useState, useEffect } from "react";
import { Icon } from "./Icon.jsx";
import { apiGet, apiPut } from "../api.js";
import { CreateRoomTab } from "./CreateRoomTab.jsx";
import { TokenTab } from "./TokenTab.jsx";
import {
  inputStyle, btnPrimaryStyle, btnGhostStyle, badgeStyle,
} from "../styles.js";

export function BotDetail({ bot: initialBot, config, onBack, addToast }) {
  const [bot, setBot] = useState(initialBot);
  const [rooms, setRooms] = useState(null);
  const [loadingRooms, setLoadingRooms] = useState(false);
  const [editing, setEditing] = useState(false);
  const [editDisplayname, setEditDisplayname] = useState(bot.displayname || "");
  const [saving, setSaving] = useState(false);
  const [togglingActive, setTogglingActive] = useState(false);
  const [activeTab, setActiveTab] = useState("overview");

  const mxid = bot.mxid || bot.name;
  const localpart = bot.localpart || mxid.split(":")[0].replace("@", "");
  const initial = (bot.displayname || localpart)[0]?.toUpperCase() || "B";

  async function fetchRooms() {
    setLoadingRooms(true);
    try {
      const data = await apiGet(`/bots/${encodeURIComponent(mxid)}/rooms`);
      setRooms(data.joined_rooms || []);
    } catch (e) {
      addToast("Fehler beim Laden der Räume: " + e.message, "error");
    } finally {
      setLoadingRooms(false);
    }
  }

  useEffect(() => {
    if (activeTab === "rooms" && rooms === null) fetchRooms();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeTab]);

  async function saveDisplayname() {
    setSaving(true);
    try {
      const updated = await apiPut(`/bots/${encodeURIComponent(mxid)}`, {
        displayname: editDisplayname,
      });
      setBot(updated);
      setEditing(false);
      addToast("Anzeigename gespeichert!", "success");
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    } finally {
      setSaving(false);
    }
  }

  async function toggleDeactivated() {
    const wantDeactivate = !bot.deactivated;
    const verb = wantDeactivate ? "deaktivieren" : "reaktivieren";
    if (wantDeactivate) {
      if (!confirm(
        `Bot „${bot.displayname || localpart}" deaktivieren?\n\n` +
        `Alle Räume werden verlassen, alle Tokens invalidiert. Der Synapse-User ` +
        `bleibt erhalten, kann später reaktiviert werden (neues Passwort).`
      )) return;
    } else {
      if (!confirm(
        `Bot „${bot.displayname || localpart}" reaktivieren?\n\n` +
        `Synapse vergibt einen neuen zufälligen Account-Status. Tokens müssen ` +
        `neu erzeugt werden — alte sind weg.`
      )) return;
    }
    setTogglingActive(true);
    try {
      const updated = await apiPut(`/bots/${encodeURIComponent(mxid)}`, {
        deactivated: wantDeactivate,
      });
      setBot(updated);
      addToast(`Bot ${wantDeactivate ? "deaktiviert" : "reaktiviert"}`, "success");
    } catch (e) {
      addToast(`Konnte nicht ${verb}: ` + e.message, "error");
    } finally {
      setTogglingActive(false);
    }
  }

  const tabs = [
    { id: "overview", label: "Übersicht", icon: "bot" },
    { id: "token", label: "Tokens", icon: "key" },
    { id: "rooms", label: "Räume", icon: "rooms" },
    { id: "create-room", label: "Raum erstellen", icon: "plus" },
  ];

  return (
    <div style={{ padding: "32px", maxWidth: 800, margin: "0 auto" }}>
      <button onClick={onBack} style={{ ...btnGhostStyle, marginBottom: 24 }}>
        <Icon name="back" size={15} /> Alle Bots
      </button>

      <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 16, padding: "28px 28px 0", marginBottom: 0 }}>
        <div style={{ display: "flex", alignItems: "flex-start", gap: 18, paddingBottom: 24, borderBottom: "1px solid var(--border)" }}>
          <div style={{
            width: 56, height: 56, borderRadius: 14, background: "var(--accent-dim)",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontFamily: "'Syne', sans-serif", fontWeight: 800, fontSize: 24, color: "var(--accent)", flexShrink: 0,
          }}>
            {initial}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            {editing ? (
              <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                <input style={{ ...inputStyle, margin: 0, flex: 1 }} value={editDisplayname} onChange={e => setEditDisplayname(e.target.value)} autoFocus />
                <button onClick={saveDisplayname} disabled={saving} style={btnPrimaryStyle}><Icon name="check" size={14} /></button>
                <button onClick={() => setEditing(false)} style={btnGhostStyle}><Icon name="x" size={14} /></button>
              </div>
            ) : (
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 22, fontWeight: 800, margin: 0, color: "var(--text)" }}>{bot.displayname || localpart}</h2>
                <button onClick={() => setEditing(true)} style={{ ...btnGhostStyle, padding: "4px 8px" }}><Icon name="edit" size={13} /></button>
              </div>
            )}
            <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)", marginTop: 4 }}>{mxid}</div>
            <div style={{ display: "flex", gap: 6, marginTop: 10, flexWrap: "wrap" }}>
              <span style={{ ...badgeStyle, background: bot.deactivated ? "rgba(255,77,77,0.15)" : "rgba(0,200,150,0.12)", color: bot.deactivated ? "#ff4d4d" : "var(--accent)", border: `1px solid ${bot.deactivated ? "rgba(255,77,77,0.3)" : "rgba(0,200,150,0.3)"}` }}>
                {bot.deactivated ? "deaktiviert" : "aktiv"}
              </span>
              <span style={badgeStyle}>bot</span>
              {!bot.exists_in_synapse && (
                <span style={{ ...badgeStyle, color: "#ffa94d", border: "1px solid rgba(255,169,77,0.3)" }}>verwaist</span>
              )}
            </div>
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 6, alignSelf: "stretch" }}>
            <button
              onClick={toggleDeactivated}
              disabled={togglingActive || !bot.exists_in_synapse}
              style={{
                ...btnGhostStyle,
                color: bot.deactivated ? "var(--accent)" : "#ff4d4d",
                borderColor: bot.deactivated ? "rgba(0,200,150,0.3)" : "rgba(255,77,77,0.3)",
                fontSize: 12,
              }}
              title={bot.deactivated ? "Bot reaktivieren" : "Bot deaktivieren"}
            >
              <Icon name="power" size={13} />
              {togglingActive ? "…" : (bot.deactivated ? "Reaktivieren" : "Deaktivieren")}
            </button>
          </div>
        </div>

        <div style={{ display: "flex", gap: 0 }}>
          {tabs.map(t => (
            <button key={t.id} onClick={() => setActiveTab(t.id)} style={{
              background: "none", border: "none", cursor: "pointer",
              padding: "14px 20px", display: "flex", alignItems: "center", gap: 7,
              fontFamily: "'Space Mono', monospace", fontSize: 12, fontWeight: 400,
              color: activeTab === t.id ? "var(--accent)" : "var(--muted)",
              borderBottom: activeTab === t.id ? "2px solid var(--accent)" : "2px solid transparent",
              transition: "color 0.15s",
            }}>
              <Icon name={t.icon} size={13} /> {t.label}
            </button>
          ))}
        </div>
      </div>

      <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderTop: "none", borderRadius: "0 0 16px 16px", padding: 28 }}>
        {activeTab === "overview" && (
          <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
            {[
              ["Matrix-ID", mxid],
              ["Erstellt", bot.creation_ts ? new Date(bot.creation_ts).toLocaleString("de-DE") : "—"],
              ["Letzter Login", bot.last_seen_ts ? new Date(bot.last_seen_ts).toLocaleString("de-DE") : "—"],
              ["Admin", bot.admin ? "Ja" : "Nein"],
              ["Synapse-Account", bot.exists_in_synapse ? (bot.deactivated ? "deaktiviert" : "aktiv") : "fehlt (verwaist)"],
            ].map(([k, v]) => (
              <div key={k} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 0", borderBottom: "1px solid var(--border)" }}>
                <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)", textTransform: "uppercase", letterSpacing: 1 }}>{k}</span>
                <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 12, color: "var(--text)" }}>{v}</span>
              </div>
            ))}
          </div>
        )}

        {activeTab === "token" && (
          <TokenTab mxid={mxid} addToast={addToast} />
        )}

        {activeTab === "rooms" && (
          <div>
            {loadingRooms ? (
              <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 32 }}>Lade Räume…</div>
            ) : rooms === null ? (
              <button onClick={fetchRooms} style={{ ...btnPrimaryStyle, width: "100%", justifyContent: "center" }}>
                <Icon name="rooms" size={15} /> Räume laden
              </button>
            ) : rooms.length === 0 ? (
              <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 32 }}>
                Dieser Bot ist in keinen Räumen.
              </div>
            ) : (
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)", marginBottom: 8 }}>
                  {rooms.length} {rooms.length === 1 ? "Raum" : "Räume"}
                </div>
                {rooms.map((roomId) => (
                  <div key={roomId} style={{
                    display: "flex", alignItems: "center", gap: 12,
                    padding: "12px 14px", background: "var(--bg)", borderRadius: 8, border: "1px solid var(--border)",
                  }}>
                    <div style={{ color: "var(--accent)", opacity: 0.7 }}><Icon name="rooms" size={14} /></div>
                    <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--text)" }}>{roomId}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
        {activeTab === "create-room" && (
          <CreateRoomTab bot={bot} config={config} addToast={addToast} onRoomCreated={() => { setRooms(null); setActiveTab("rooms"); }} />
        )}
      </div>
    </div>
  );
}
