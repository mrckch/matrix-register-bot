import { useState } from "react";
import { Icon } from "./Icon.jsx";
import {
  labelStyle, inputStyle, btnPrimaryStyle, btnGhostStyle,
} from "../styles.js";

export function SettingsScreen({ config, onSave, onBack, addToast }) {
  const [users, setUsers] = useState(config.defaultUsers || []);
  const [newMxid, setNewMxid] = useState("");
  const [newAdmin, setNewAdmin] = useState(true);

  function addUser() {
    if (!newMxid.trim()) return;
    const mxid = newMxid.trim();
    if (!mxid.startsWith("@")) {
      addToast("Matrix-ID muss mit @ beginnen, z.B. @marc:server.de", "error");
      return;
    }
    if (!mxid.includes(":")) {
      addToast("Matrix-ID braucht einen Server-Teil, z.B. @marc:server.de", "error");
      return;
    }
    if (users.find(u => u.mxid === mxid)) {
      addToast("Dieser User ist schon in der Liste", "error");
      return;
    }
    const next = [...users, { mxid, defaultAdmin: newAdmin }];
    setUsers(next);
    onSave({ ...config, defaultUsers: next });
    setNewMxid("");
    setNewAdmin(true);
  }

  function removeUser(mxid) {
    const next = users.filter(u => u.mxid !== mxid);
    setUsers(next);
    onSave({ ...config, defaultUsers: next });
  }

  function toggleAdmin(mxid) {
    const next = users.map(u => u.mxid === mxid ? { ...u, defaultAdmin: !u.defaultAdmin } : u);
    setUsers(next);
    onSave({ ...config, defaultUsers: next });
  }

  return (
    <div style={{ padding: "32px", maxWidth: 800, margin: "0 auto" }}>
      <button onClick={onBack} style={{ ...btnGhostStyle, marginBottom: 24 }}>
        <Icon name="back" size={15} /> Zurück
      </button>

      <div style={{ marginBottom: 28 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
          <div style={{ color: "var(--accent)" }}><Icon name="users" size={18} /></div>
          <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, letterSpacing: 3, color: "var(--muted)", textTransform: "uppercase" }}>Standard-Nutzer</span>
        </div>
        <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 26, fontWeight: 800, margin: 0, color: "var(--text)" }}>Einladungs-Liste</h1>
        <p style={{ color: "var(--muted)", fontSize: 13, marginTop: 8, fontFamily: "'Space Mono', monospace", lineHeight: 1.6 }}>
          Diese Nutzer werden beim Anlegen neuer Räume vorausgewählt. Pro Nutzer kann ein Standard-Admin-Status hinterlegt werden.
        </p>
      </div>

      {/* Add user */}
      <div style={{ background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 12, padding: 20, marginBottom: 20 }}>
        <label style={labelStyle}>Neuer Standard-Nutzer</label>
        <div style={{ display: "flex", gap: 10, alignItems: "stretch" }}>
          <input
            style={{ ...inputStyle, flex: 1 }}
            value={newMxid}
            onChange={e => setNewMxid(e.target.value)}
            onKeyDown={e => e.key === "Enter" && addUser()}
            placeholder="@marc:matrix.example.com"
          />
          <button
            onClick={() => setNewAdmin(!newAdmin)}
            style={{
              ...btnGhostStyle,
              background: newAdmin ? "var(--accent-dim)" : "transparent",
              color: newAdmin ? "var(--accent)" : "var(--muted)",
              borderColor: newAdmin ? "rgba(0,200,150,0.3)" : "var(--border)",
            }}
            title="Standard-Admin-Status"
          >
            <Icon name="shield" size={13} /> Admin
          </button>
          <button onClick={addUser} disabled={!newMxid} style={btnPrimaryStyle}>
            <Icon name="plus" size={14} /> Hinzufügen
          </button>
        </div>
      </div>

      {/* List */}
      {users.length === 0 ? (
        <div style={{ textAlign: "center", padding: 48, color: "var(--muted)" }}>
          <div style={{ marginBottom: 12, opacity: 0.3 }}><Icon name="users" size={40} /></div>
          <p style={{ fontFamily: "'Space Mono', monospace", fontSize: 13 }}>Noch keine Standard-Nutzer.</p>
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {users.map(u => (
            <div key={u.mxid} style={{
              display: "flex", alignItems: "center", gap: 12,
              padding: "14px 18px", background: "var(--surface)",
              border: "1px solid var(--border)", borderRadius: 10,
            }}>
              <div style={{
                width: 32, height: 32, borderRadius: 8, background: "var(--accent-dim)",
                display: "flex", alignItems: "center", justifyContent: "center",
                fontFamily: "'Syne', sans-serif", fontWeight: 800, fontSize: 14, color: "var(--accent)", flexShrink: 0,
              }}>
                {u.mxid[1]?.toUpperCase() || "?"}
              </div>
              <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 12, color: "var(--text)", flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {u.mxid}
              </span>
              <button
                onClick={() => toggleAdmin(u.mxid)}
                style={{
                  ...btnGhostStyle,
                  background: u.defaultAdmin ? "var(--accent-dim)" : "transparent",
                  color: u.defaultAdmin ? "var(--accent)" : "var(--muted)",
                  borderColor: u.defaultAdmin ? "rgba(0,200,150,0.3)" : "var(--border)",
                  padding: "6px 10px",
                }}
              >
                <Icon name="shield" size={12} /> Admin
              </button>
              <button onClick={() => removeUser(u.mxid)} style={{ ...btnGhostStyle, padding: "6px 10px" }} title="Entfernen">
                <Icon name="trash" size={13} />
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
