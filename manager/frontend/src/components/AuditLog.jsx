import { useState, useEffect, useCallback } from "react";
import { Icon } from "./Icon.jsx";
import { apiGet } from "../api.js";
import { btnGhostStyle, badgeStyle } from "../styles.js";

const PAGE_SIZE = 100;

const ACTION_LABELS = {
  create_bot: "Bot angelegt",
  import_bot: "Bot importiert",
  rename_bot: "Bot umbenannt",
  deactivate_bot: "Bot deaktiviert",
  reactivate_bot: "Bot reaktiviert",
  remove_bot_from_registry: "Bot aus Registry entfernt",
  erase_bot: "Bot dauerhaft gelöscht",
  set_avatar: "Avatar gesetzt",
  create_token: "Token erzeugt",
  delete_token: "Token gelöscht",
  upsert_default_user: "Standard-User gesetzt",
  remove_default_user: "Standard-User entfernt",
  create_room: "Raum erstellt",
  wizard_setup: "Wizard-Setup",
};

function fmtTs(ms) {
  if (!ms) return "—";
  return new Date(ms).toLocaleString("de-DE");
}

function fmtDetail(detail) {
  if (!detail) return null;
  if (typeof detail !== "object") return String(detail);
  return Object.entries(detail).map(([k, v]) => (
    <span key={k} style={{ display: "inline-block", marginRight: 12 }}>
      <span style={{ color: "var(--muted)" }}>{k}:</span> {String(v)}
    </span>
  ));
}

export function AuditLog({ onBack, addToast }) {
  const [entries, setEntries] = useState([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async (off) => {
    setLoading(true);
    try {
      const data = await apiGet(`/audit?limit=${PAGE_SIZE}&offset=${off}`);
      setEntries(data.entries || []);
      setTotal(data.total || 0);
      setOffset(off);
    } catch (e) {
      addToast("Fehler beim Laden: " + e.message, "error");
    } finally {
      setLoading(false);
    }
  }, [addToast]);

  useEffect(() => { load(0); }, [load]);

  const hasPrev = offset > 0;
  const hasNext = offset + PAGE_SIZE < total;

  return (
    <div style={{ padding: "32px", maxWidth: 900, margin: "0 auto" }}>
      <button onClick={onBack} style={{ ...btnGhostStyle, marginBottom: 24 }}>
        <Icon name="back" size={15} /> Zurück
      </button>

      <div style={{ marginBottom: 24 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
          <div style={{ color: "var(--accent)" }}><Icon name="activity" size={18} /></div>
          <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, letterSpacing: 3, color: "var(--muted)", textTransform: "uppercase" }}>Aktivität</span>
        </div>
        <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 26, fontWeight: 800, margin: 0, color: "var(--text)" }}>Audit-Log</h1>
        <p style={{ color: "var(--muted)", fontSize: 12, marginTop: 8, fontFamily: "'Space Mono', monospace", lineHeight: 1.6 }}>
          Jede schreibende Aktion über den Manager — Bot-Anlage, Token-Erzeugung, Wizard-Setup, Standard-User-Pflege.
          Persistent in der Manager-DB.
        </p>
      </div>

      {loading && entries.length === 0 ? (
        <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 48 }}>Lade…</div>
      ) : entries.length === 0 ? (
        <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 48 }}>
          Noch keine Einträge.
        </div>
      ) : (
        <>
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            {entries.map(e => <AuditRow key={e.id} entry={e} />)}
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 16, fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)" }}>
            <span>{offset + 1}–{Math.min(offset + entries.length, total)} von {total}</span>
            <div style={{ display: "flex", gap: 8 }}>
              <button onClick={() => load(Math.max(0, offset - PAGE_SIZE))}
                disabled={!hasPrev || loading}
                style={btnGhostStyle}>← Älter</button>
              <button onClick={() => load(offset + PAGE_SIZE)}
                disabled={!hasNext || loading}
                style={btnGhostStyle}>Neuer →</button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

function AuditRow({ entry }) {
  const label = ACTION_LABELS[entry.action] || entry.action;
  return (
    <div style={{
      display: "grid",
      gridTemplateColumns: "180px 200px 1fr",
      gap: 12,
      padding: "10px 14px",
      background: "var(--surface)",
      border: "1px solid var(--border)",
      borderRadius: 8,
      alignItems: "center",
      fontFamily: "'Space Mono', monospace",
      fontSize: 11,
    }}>
      <span style={{ color: "var(--muted)" }}>{fmtTs(entry.ts)}</span>
      <span style={{ ...badgeStyle, justifySelf: "start", whiteSpace: "nowrap" }}>{label}</span>
      <span style={{ color: "var(--text)", overflow: "hidden", textOverflow: "ellipsis" }}>
        {entry.target && <span style={{ color: "var(--accent)" }}>{entry.target}</span>}
        {entry.target && entry.detail && <span style={{ color: "var(--muted)" }}> · </span>}
        {fmtDetail(entry.detail)}
      </span>
    </div>
  );
}
