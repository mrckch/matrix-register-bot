import { useState } from "react";
import { Icon } from "./Icon.jsx";
import { apiPost, apiDelete } from "../api.js";
import {
  labelStyle, inputStyle, btnPrimaryStyle, btnGhostStyle,
} from "../styles.js";

export function SettingsScreen({ config, onRefresh, onBack, addToast }) {
  const users = config.defaultUsers || [];
  const [newMxid, setNewMxid] = useState("");
  const [newAdmin, setNewAdmin] = useState(true);
  const [busy, setBusy] = useState(false);

  async function addUser() {
    const mxid = newMxid.trim();
    if (!mxid) return;
    if (!mxid.startsWith("@") || !mxid.includes(":")) {
      addToast("Matrix-ID muss Format @user:server haben", "error");
      return;
    }
    if (users.find(u => u.mxid === mxid)) {
      addToast("Dieser User ist schon in der Liste", "error");
      return;
    }
    setBusy(true);
    try {
      await apiPost("/default-users", { mxid, default_admin: newAdmin });
      await onRefresh();
      setNewMxid("");
      setNewAdmin(true);
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function removeUser(mxid) {
    setBusy(true);
    try {
      await apiDelete(`/default-users/${encodeURIComponent(mxid)}`);
      await onRefresh();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function toggleAdmin(u) {
    setBusy(true);
    try {
      await apiPost("/default-users", { mxid: u.mxid, default_admin: !u.default_admin });
      await onRefresh();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    } finally {
      setBusy(false);
    }
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
          Diese Nutzer werden beim Anlegen neuer Räume (Setup-Wizard und CreateRoom-Tab) vorausgewählt.
          Pro Nutzer kann ein Standard-Admin-Status hinterlegt werden. Speicherung server-seitig in der Manager-DB.
        </p>
      </div>

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
          <button onClick={addUser} disabled={!newMxid || busy} style={btnPrimaryStyle}>
            <Icon name="plus" size={14} /> Hinzufügen
          </button>
        </div>
      </div>

      {users.length === 0 ? (
        <div style={{ textAlign: "center", padding: 48, color: "var(--muted)" }}>
          <div style={{ marginBottom: 12, opacity: 0.3 }}><Icon name="users" size={40} /></div>
          <p style={{ fontFamily: "'Space Mono', monospace", fontSize: 13 }}>Noch keine Standard-Nutzer.</p>
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 8, marginBottom: 32 }}>
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
                onClick={() => toggleAdmin(u)}
                disabled={busy}
                style={{
                  ...btnGhostStyle,
                  background: u.default_admin ? "var(--accent-dim)" : "transparent",
                  color: u.default_admin ? "var(--accent)" : "var(--muted)",
                  borderColor: u.default_admin ? "rgba(0,200,150,0.3)" : "var(--border)",
                  padding: "6px 10px",
                }}
              >
                <Icon name="shield" size={12} /> Admin
              </button>
              <button onClick={() => removeUser(u.mxid)} disabled={busy} style={{ ...btnGhostStyle, padding: "6px 10px" }} title="Entfernen">
                <Icon name="trash" size={13} />
              </button>
            </div>
          ))}
        </div>
      )}

      <div style={{ marginTop: 32, paddingTop: 24, borderTop: "1px solid var(--border)" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
          <div style={{ color: "var(--accent)" }}><Icon name="download" size={18} /></div>
          <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, letterSpacing: 3, color: "var(--muted)", textTransform: "uppercase" }}>Backup</span>
        </div>
        <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 18, fontWeight: 700, margin: 0, color: "var(--text)" }}>Datenbank-Export</h2>
        <p style={{ color: "var(--muted)", fontSize: 12, marginTop: 8, fontFamily: "'Space Mono', monospace", lineHeight: 1.6 }}>
          SQLite-Snapshot der Manager-DB (Registry, Tokens im Klartext, Default-User, Audit-Log). Atomar konsistent via VACUUM INTO.
        </p>
        <a href="/api/admin/db-export" download
          style={{ ...btnPrimaryStyle, textDecoration: "none", marginTop: 12 }}>
          <Icon name="download" size={14} /> manager.db herunterladen
        </a>
      </div>
    </div>
  );
}
