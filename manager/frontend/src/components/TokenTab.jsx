import { useState, useEffect, useCallback } from "react";
import { Icon } from "./Icon.jsx";
import { apiGet, apiPost, apiDelete } from "../api.js";
import {
  labelStyle, inputStyle, btnPrimaryStyle, btnGhostStyle, badgeStyle,
  modalOverlayStyle, modalStyle,
} from "../styles.js";

const DURATIONS = [
  { label: "1 Stunde",  ms: 1 * 60 * 60 * 1000 },
  { label: "1 Tag",     ms: 24 * 60 * 60 * 1000 },
  { label: "30 Tage",   ms: 30 * 24 * 60 * 60 * 1000 },
  { label: "1 Jahr",    ms: 365 * 24 * 60 * 60 * 1000 },
  { label: "10 Jahre",  ms: 10 * 365 * 24 * 60 * 60 * 1000 },
  { label: "Nie (~100 Jahre)", ms: null },  // null = "nie"
];
const DEFAULT_DURATION_IDX = 5;

function fmtDate(ms) {
  if (!ms) return "—";
  return new Date(ms).toLocaleString("de-DE");
}

function fmtRelativeFuture(ms) {
  if (!ms) return "—";
  const diff = ms - Date.now();
  if (diff < 0) return "abgelaufen";
  const days = Math.floor(diff / (24 * 60 * 60 * 1000));
  if (days < 1) {
    const hours = Math.floor(diff / (60 * 60 * 1000));
    return `in ${hours} Std.`;
  }
  if (days < 90) return `in ${days} Tagen`;
  if (days < 365 * 2) return `in ${Math.floor(days / 30)} Monaten`;
  return `in ${Math.floor(days / 365)} Jahren`;
}

export function TokenTab({ mxid, addToast }) {
  const [tokens, setTokens] = useState(null);
  const [loading, setLoading] = useState(false);
  const [showCreate, setShowCreate] = useState(false);
  const [newlyCreatedId, setNewlyCreatedId] = useState(null);
  const [revealed, setRevealed] = useState({});  // {token_id: true}

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await apiGet(`/bots/${encodeURIComponent(mxid)}/tokens`);
      setTokens(data.tokens || []);
    } catch (e) {
      addToast("Fehler beim Laden der Tokens: " + e.message, "error");
    } finally {
      setLoading(false);
    }
  }, [mxid, addToast]);

  useEffect(() => { load(); }, [load]);

  async function handleCreate({ label, durationMs }) {
    try {
      const t = await apiPost(`/bots/${encodeURIComponent(mxid)}/tokens`, {
        label: label || null,
        valid_for_ms: durationMs,
      });
      addToast("Token erstellt", "success");
      setNewlyCreatedId(t.id);
      setRevealed(prev => ({ ...prev, [t.id]: true }));
      setShowCreate(false);
      load();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    }
  }

  async function handleDelete(token) {
    const lbl = token.label || `#${token.id}`;
    if (!confirm(`Token „${lbl}" wirklich löschen? Das zugehörige Synapse-Device wird invalidiert.`)) return;
    try {
      await apiDelete(`/bots/${encodeURIComponent(mxid)}/tokens/${token.id}`);
      addToast(`Token „${lbl}" gelöscht`, "success");
      load();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    }
  }

  function copyToken(token) {
    navigator.clipboard.writeText(token.access_token);
    addToast("Token in die Zwischenablage kopiert", "success");
  }

  function toggleReveal(id) {
    setRevealed(prev => ({ ...prev, [id]: !prev[id] }));
  }

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
        <p style={{ color: "var(--muted)", fontSize: 13, fontFamily: "'Space Mono', monospace", margin: 0 }}>
          Access-Tokens für diesen Bot. Klartext aus der Manager-DB — kopier- und löschbar.
        </p>
        <button onClick={() => setShowCreate(true)} style={btnPrimaryStyle}>
          <Icon name="plus" size={14} /> Neuer Token
        </button>
      </div>

      {loading && tokens === null ? (
        <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 32 }}>Lade Tokens…</div>
      ) : (tokens || []).length === 0 ? (
        <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 13, textAlign: "center", padding: 32 }}>
          Noch keine Tokens. „Neuer Token" anlegen.
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          {tokens.map(t => (
            <TokenCard
              key={t.id}
              token={t}
              isRevealed={!!revealed[t.id]}
              isNew={t.id === newlyCreatedId}
              onToggle={() => toggleReveal(t.id)}
              onCopy={() => copyToken(t)}
              onDelete={() => handleDelete(t)}
            />
          ))}
        </div>
      )}

      {showCreate && (
        <CreateTokenModal
          onCancel={() => setShowCreate(false)}
          onCreate={handleCreate}
        />
      )}
    </div>
  );
}

function TokenCard({ token, isRevealed, isNew, onToggle, onCopy, onDelete }) {
  const expired = token.valid_until_ms && token.valid_until_ms < Date.now();
  const danger = expired || !token.device_present;

  return (
    <div style={{
      background: isNew ? "rgba(0,200,150,0.06)" : "var(--bg)",
      border: `1px solid ${isNew ? "var(--accent)" : "var(--border)"}`,
      borderRadius: 10,
      padding: 14,
    }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12, marginBottom: 10 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
            <div style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 14, color: "var(--text)" }}>
              {token.label || `Token #${token.id}`}
            </div>
            {isNew && <span style={{ ...badgeStyle, color: "var(--accent)", border: "1px solid rgba(0,200,150,0.3)" }}>neu</span>}
            {expired && <span style={{ ...badgeStyle, color: "#ff4d4d", border: "1px solid rgba(255,77,77,0.3)" }}>abgelaufen</span>}
            {!token.device_present && !expired && <span style={{ ...badgeStyle, color: "#ffa94d", border: "1px solid rgba(255,169,77,0.3)" }}>Device fehlt</span>}
          </div>
          <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, color: "var(--muted)" }}>
            Device: {token.device_id}
          </div>
        </div>
        <div style={{ display: "flex", gap: 6 }}>
          <button onClick={onToggle} style={btnGhostStyle} title={isRevealed ? "Verbergen" : "Anzeigen"}>
            <Icon name={isRevealed ? "eyeOff" : "eye"} size={14} />
          </button>
          <button onClick={onCopy} style={btnGhostStyle} title="In Zwischenablage kopieren">
            <Icon name="copy" size={14} />
          </button>
          <button onClick={onDelete} style={{ ...btnGhostStyle, color: "#ff4d4d" }} title="Löschen">
            <Icon name="trash" size={14} />
          </button>
        </div>
      </div>

      <div style={{
        background: "var(--surface)", border: "1px solid var(--border)", borderRadius: 6,
        padding: "8px 10px", fontFamily: "'Space Mono', monospace", fontSize: 11,
        color: isRevealed ? "var(--accent)" : "var(--muted)", wordBreak: "break-all",
        lineHeight: 1.5, marginBottom: 10,
      }}>
        {isRevealed ? token.access_token : "•".repeat(Math.min(60, (token.access_token || "").length))}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 8, fontFamily: "'Space Mono', monospace", fontSize: 10 }}>
        <Field k="Erstellt" v={fmtDate(token.created_at)} />
        <Field k="Läuft ab" v={`${fmtRelativeFuture(token.valid_until_ms)} (${fmtDate(token.valid_until_ms)})`} danger={danger} />
        <Field k="Zuletzt gesehen" v={token.last_seen_ts ? fmtDate(token.last_seen_ts) : "—"} />
      </div>
    </div>
  );
}

function Field({ k, v, danger }) {
  return (
    <div>
      <div style={{ color: "var(--muted)", textTransform: "uppercase", letterSpacing: 1, marginBottom: 2 }}>{k}</div>
      <div style={{ color: danger ? "#ff4d4d" : "var(--text)" }}>{v}</div>
    </div>
  );
}

function CreateTokenModal({ onCancel, onCreate }) {
  const [label, setLabel] = useState("");
  const [durationIdx, setDurationIdx] = useState(DEFAULT_DURATION_IDX);
  const [busy, setBusy] = useState(false);

  async function submit() {
    setBusy(true);
    await onCreate({ label: label.trim(), durationMs: DURATIONS[durationIdx].ms });
    setBusy(false);
  }

  return (
    <div style={modalOverlayStyle}>
      <div style={modalStyle}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 20 }}>
          <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 20, fontWeight: 700, margin: 0, color: "var(--text)" }}>Neuen Token erzeugen</h2>
          <button onClick={onCancel} style={btnGhostStyle}><Icon name="x" size={16} /></button>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
          <div>
            <label style={labelStyle}>Label (optional)</label>
            <input style={inputStyle} value={label}
              onChange={e => setLabel(e.target.value)}
              placeholder="z.B. 'prod' oder 'maubot-instance'" autoFocus />
            <div style={{ color: "var(--muted)", fontSize: 10, fontFamily: "'Space Mono', monospace", marginTop: 4 }}>
              Wird als Device-Anzeigename in Synapse gesetzt — auch in Ketesa/Element sichtbar.
            </div>
          </div>
          <div>
            <label style={labelStyle}>Gültigkeit</label>
            <select
              value={durationIdx}
              onChange={e => setDurationIdx(parseInt(e.target.value, 10))}
              style={{ ...inputStyle, appearance: "auto" }}
            >
              {DURATIONS.map((d, i) => <option key={i} value={i}>{d.label}</option>)}
            </select>
          </div>
          <div style={{ display: "flex", gap: 10, marginTop: 4 }}>
            <button onClick={onCancel} style={{ ...btnGhostStyle, flex: 1, justifyContent: "center" }}>Abbrechen</button>
            <button onClick={submit} disabled={busy} style={{ ...btnPrimaryStyle, flex: 2, justifyContent: "center" }}>
              {busy ? "Erzeuge…" : "Token erzeugen"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
