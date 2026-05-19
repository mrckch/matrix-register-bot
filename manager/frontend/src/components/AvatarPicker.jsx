import { useRef, useState } from "react";
import { Icon } from "./Icon.jsx";
import { apiUpload } from "../api.js";
import { BOT_AVATARS, avatarToPngBlob } from "./BotAvatars.jsx";
import {
  btnGhostStyle, btnPrimaryStyle, labelStyle,
  modalOverlayStyle, modalStyle,
} from "../styles.js";

export function AvatarPicker({ mxid, onClose, onApplied, addToast }) {
  const [busy, setBusy] = useState(null); // null | "upload" | avatar.id
  const fileInputRef = useRef(null);

  async function applyBuiltin(avatar) {
    setBusy(avatar.id);
    try {
      const blob = await avatarToPngBlob(avatar.svg, 256);
      const file = new File([blob], `${avatar.id}.png`, { type: "image/png" });
      const r = await apiUpload(`/bots/${encodeURIComponent(mxid)}/avatar`, file);
      addToast(`Avatar „${avatar.name}" gesetzt`, "success");
      onApplied(r.avatar_url);
    } catch (e) {
      addToast("Fehler: " + (e.message || String(e)), "error");
    } finally {
      setBusy(null);
    }
  }

  async function handleFile(e) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      addToast("Bitte eine Bilddatei wählen", "error");
      return;
    }
    if (file.size > 8 * 1024 * 1024) {
      addToast("Datei zu groß (max 8 MB)", "error");
      return;
    }
    setBusy("upload");
    try {
      const r = await apiUpload(`/bots/${encodeURIComponent(mxid)}/avatar`, file);
      addToast("Avatar gesetzt", "success");
      onApplied(r.avatar_url);
    } catch (err) {
      addToast("Fehler: " + err.message, "error");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div style={modalOverlayStyle}>
      <div style={{ ...modalStyle, maxWidth: 560 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
          <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 20, fontWeight: 700, margin: 0, color: "var(--text)" }}>
            Avatar wählen
          </h2>
          <button onClick={onClose} disabled={!!busy} style={btnGhostStyle}>
            <Icon name="x" size={16} />
          </button>
        </div>
        <p style={{ color: "var(--muted)", fontSize: 12, fontFamily: "'Space Mono', monospace", lineHeight: 1.6, marginBottom: 16 }}>
          Vorgefertigte Bot-Bilder oder eigene Datei.
        </p>

        <div style={labelStyle}>Galerie</div>
        <div style={{
          display: "grid",
          gridTemplateColumns: "repeat(5, 1fr)",
          gap: 10,
          marginBottom: 18,
        }}>
          {BOT_AVATARS.map(a => (
            <AvatarTile key={a.id} avatar={a}
              busy={busy === a.id}
              disabled={!!busy && busy !== a.id}
              onClick={() => applyBuiltin(a)} />
          ))}
        </div>

        <div style={labelStyle}>Oder eigene Datei</div>
        <button
          onClick={() => fileInputRef.current?.click()}
          disabled={!!busy}
          style={{ ...btnPrimaryStyle, width: "100%", justifyContent: "center" }}>
          <Icon name="download" size={14} />
          {busy === "upload" ? "Lade hoch…" : "Bild hochladen (max 8 MB)"}
        </button>
        <input
          ref={fileInputRef}
          type="file"
          accept="image/*"
          onChange={handleFile}
          style={{ display: "none" }}
        />
      </div>
    </div>
  );
}

function AvatarTile({ avatar, busy, disabled, onClick }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={avatar.name}
      style={{
        background: "none",
        border: "2px solid transparent",
        borderRadius: 14,
        padding: 0,
        cursor: disabled ? "not-allowed" : "pointer",
        opacity: disabled ? 0.4 : 1,
        position: "relative",
        aspectRatio: "1 / 1",
        transition: "border-color 0.15s, transform 0.15s",
      }}
      onMouseEnter={e => { if (!disabled) e.currentTarget.style.borderColor = "var(--accent)"; }}
      onMouseLeave={e => { e.currentTarget.style.borderColor = "transparent"; }}
    >
      <div
        dangerouslySetInnerHTML={{ __html: avatar.svg }}
        style={{ width: "100%", height: "100%", display: "block" }}
      />
      {busy && (
        <div style={{
          position: "absolute", inset: 0,
          display: "flex", alignItems: "center", justifyContent: "center",
          background: "rgba(0,0,0,0.6)", borderRadius: 12,
          fontFamily: "'Space Mono', monospace", fontSize: 9, color: "var(--text)",
        }}>lade…</div>
      )}
    </button>
  );
}
