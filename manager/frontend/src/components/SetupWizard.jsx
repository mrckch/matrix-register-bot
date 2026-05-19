import { useState } from "react";
import { Icon } from "./Icon.jsx";
import { apiPost, apiUpload } from "../api.js";
import { BOT_AVATARS, avatarToPngBlob } from "./BotAvatars.jsx";
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
  { label: "Nie (~100 Jahre)", ms: null },
];
const DEFAULT_DURATION_IDX = 5;

function slugify(s) {
  return s.toLowerCase()
    .replace(/ä/g, "ae").replace(/ö/g, "oe").replace(/ü/g, "ue").replace(/ß/g, "ss")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function SetupWizard({ config, onClose, onDone, addToast }) {
  const [step, setStep] = useState(1);
  const [localpartTouched, setLocalpartTouched] = useState(false);
  const [roomNameTouched, setRoomNameTouched] = useState(false);
  const [aliasTouched, setAliasTouched] = useState(false);
  const [data, setData] = useState({
    displayname: "",
    localpart: "",
    avatarId: null,        // id aus BOT_AVATARS oder null
    tokenLabel: "default",
    tokenDurationIdx: DEFAULT_DURATION_IDX,
    roomName: "",
    roomTopic: "",
    roomAlias: "",
    encrypted: false,
    isPublic: false,
    invites: (config.defaultUsers || []).map(u => ({
      mxid: u.mxid, power_level: (u.default_admin ?? u.defaultAdmin) ? 100 : 0, selected: true,
    })),
  });
  const [extraMxid, setExtraMxid] = useState("");
  const [running, setRunning] = useState(false);
  const [result, setResult] = useState(null);

  function setField(field, value) {
    setData(d => ({ ...d, [field]: value }));
  }

  function onDisplaynameChange(value) {
    setData(d => ({
      ...d,
      displayname: value,
      localpart: localpartTouched ? d.localpart : slugify(value),
      roomName: roomNameTouched ? d.roomName : value,
      roomAlias: aliasTouched ? d.roomAlias : slugify(value),
    }));
  }

  function onRoomNameChange(value) {
    setRoomNameTouched(true);
    setData(d => ({
      ...d,
      roomName: value,
      roomAlias: aliasTouched ? d.roomAlias : slugify(value),
    }));
  }

  function addExtra() {
    const mxid = extraMxid.trim();
    if (!mxid.startsWith("@") || !mxid.includes(":")) {
      addToast("Matrix-ID muss Format @user:server haben", "error");
      return;
    }
    if (data.invites.find(i => i.mxid === mxid)) {
      addToast("Schon in der Liste", "error");
      return;
    }
    setData(d => ({ ...d, invites: [...d.invites, { mxid, power_level: 0, selected: true }] }));
    setExtraMxid("");
  }

  function toggleInviteSelected(mxid) {
    setData(d => ({
      ...d,
      invites: d.invites.map(i => i.mxid === mxid ? { ...i, selected: !i.selected } : i),
    }));
  }

  function setInvitePL(mxid, power_level) {
    setData(d => ({
      ...d,
      invites: d.invites.map(i => i.mxid === mxid ? { ...i, power_level } : i),
    }));
  }

  function removeInvite(mxid) {
    setData(d => ({ ...d, invites: d.invites.filter(i => i.mxid !== mxid) }));
  }

  async function execute() {
    setRunning(true);
    const active = data.invites.filter(i => i.selected);
    const payload = {
      localpart: data.localpart,
      displayname: data.displayname || data.localpart,
      token_label: data.tokenLabel || null,
      token_valid_for_ms: DURATIONS[data.tokenDurationIdx].ms,
      room: {
        name: data.roomName || data.displayname || data.localpart,
        topic: data.roomTopic || null,
        encrypted: data.encrypted,
        public: data.isPublic,
        alias_localpart: data.roomAlias || null,
        invites: active.map(i => ({ mxid: i.mxid, power_level: i.power_level })),
      },
    };
    try {
      const r = await apiPost("/wizard/setup-bot", payload);

      // Optional: ausgewaehlten Built-in-Avatar nach dem Setup-Erfolg setzen
      if (data.avatarId && r.bot?.mxid) {
        const avatar = BOT_AVATARS.find(a => a.id === data.avatarId);
        if (avatar) {
          try {
            const blob = await avatarToPngBlob(avatar.svg, 256);
            const file = new File([blob], `${avatar.id}.png`, { type: "image/png" });
            const av = await apiUpload(`/bots/${encodeURIComponent(r.bot.mxid)}/avatar`, file);
            r.bot.avatar_url = av.avatar_url;
            r.steps.push({ id: "set_avatar", status: "ok", detail: avatar.name });
          } catch (avErr) {
            r.steps.push({ id: "set_avatar", status: "error", detail: avErr.message });
          }
        }
      }

      setResult(r);
      setStep(5);
    } catch (e) {
      addToast("Wizard fehlgeschlagen: " + e.message, "error");
    } finally {
      setRunning(false);
    }
  }

  function close() {
    if (result && onDone) onDone();
    onClose();
  }

  return (
    <div style={modalOverlayStyle}>
      <div style={{ ...modalStyle, maxWidth: 640 }}>
        <Header step={step} onClose={close} />
        <Stepper currentStep={step} />

        {step === 1 && (
          <Step1
            data={data} setField={setField}
            onDisplaynameChange={onDisplaynameChange}
            onLocalpartChange={v => { setLocalpartTouched(true); setField("localpart", v); }}
          />
        )}
        {step === 2 && (
          <Step2
            data={data} setField={setField}
            onRoomNameChange={onRoomNameChange}
            onAliasChange={v => { setAliasTouched(true); setField("roomAlias", v); }}
          />
        )}
        {step === 3 && (
          <Step3
            data={data}
            extraMxid={extraMxid} setExtraMxid={setExtraMxid}
            addExtra={addExtra}
            toggleInviteSelected={toggleInviteSelected}
            setInvitePL={setInvitePL}
            removeInvite={removeInvite}
          />
        )}
        {step === 4 && (
          <Step4 data={data} />
        )}
        {step === 5 && result && (
          <Step5 result={result} addToast={addToast} />
        )}

        <Footer
          step={step}
          running={running}
          canAdvance={
            (step === 1 && !!data.localpart) ||
            (step === 2 && !!data.roomName) ||
            (step === 3) ||
            (step === 4)
          }
          onBack={() => setStep(s => s - 1)}
          onNext={() => setStep(s => s + 1)}
          onExecute={execute}
          onClose={close}
        />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function Header({ step, onClose }) {
  const titles = {
    1: "Schritt 1 — Bot & Token",
    2: "Schritt 2 — Raum",
    3: "Schritt 3 — Einladungen",
    4: "Schritt 4 — Bestätigen",
    5: "Ergebnis",
  };
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
      <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 20, fontWeight: 700, margin: 0, color: "var(--text)" }}>
        {titles[step]}
      </h2>
      <button onClick={onClose} style={btnGhostStyle}><Icon name="x" size={16} /></button>
    </div>
  );
}

function Stepper({ currentStep }) {
  if (currentStep === 5) return null;
  return (
    <div style={{ display: "flex", gap: 4, marginBottom: 22 }}>
      {[1, 2, 3, 4].map(n => (
        <div key={n} style={{
          flex: 1, height: 3, borderRadius: 2,
          background: n <= currentStep ? "var(--accent)" : "var(--border)",
        }} />
      ))}
    </div>
  );
}

function Step1({ data, setField, onDisplaynameChange, onLocalpartChange }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <div>
        <label style={labelStyle}>Anzeigename</label>
        <input style={inputStyle} value={data.displayname}
          onChange={e => onDisplaynameChange(e.target.value)}
          placeholder="z.B. Kurswahl-Bot" autoFocus />
      </div>
      <div>
        <label style={labelStyle}>Localpart (Username ohne @domain)</label>
        <input style={inputStyle} value={data.localpart}
          onChange={e => onLocalpartChange(e.target.value.toLowerCase().replace(/\s/g, "-"))}
          placeholder="kurswahl-bot" />
        <div style={{ color: "var(--muted)", fontSize: 10, fontFamily: "'Space Mono', monospace", marginTop: 4 }}>
          Automatisch aus dem Anzeigenamen abgeleitet, kann übersteuert werden.
        </div>
      </div>
      <div>
        <label style={labelStyle}>Avatar (optional)</label>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(8, 1fr)", gap: 6 }}>
          <button onClick={() => setField("avatarId", null)} type="button"
            title="Kein Avatar"
            style={{
              aspectRatio: "1 / 1", borderRadius: 10,
              border: `2px solid ${data.avatarId === null ? "var(--accent)" : "var(--border)"}`,
              background: "var(--bg)", cursor: "pointer", padding: 0,
              display: "flex", alignItems: "center", justifyContent: "center",
              color: "var(--muted)", fontSize: 14,
            }}>—</button>
          {BOT_AVATARS.map(a => (
            <button key={a.id} onClick={() => setField("avatarId", a.id)} type="button"
              title={a.name}
              style={{
                aspectRatio: "1 / 1", borderRadius: 10,
                border: `2px solid ${data.avatarId === a.id ? "var(--accent)" : "transparent"}`,
                background: "none", cursor: "pointer", padding: 0,
              }}>
              <div dangerouslySetInnerHTML={{ __html: a.svg }} style={{ width: "100%", height: "100%" }} />
            </button>
          ))}
        </div>
        <div style={{ color: "var(--muted)", fontSize: 10, fontFamily: "'Space Mono', monospace", marginTop: 4 }}>
          Wird nach erfolgreichem Bot-Anlegen als Avatar gesetzt. Eigenes Bild später im Bot-Detail.
        </div>
      </div>
      <div>
        <label style={labelStyle}>Token-Label</label>
        <input style={inputStyle} value={data.tokenLabel}
          onChange={e => setField("tokenLabel", e.target.value)}
          placeholder="default" />
      </div>
      <div>
        <label style={labelStyle}>Token-Gültigkeit</label>
        <select style={{ ...inputStyle, appearance: "auto" }}
          value={data.tokenDurationIdx}
          onChange={e => setField("tokenDurationIdx", parseInt(e.target.value, 10))}>
          {DURATIONS.map((d, i) => <option key={i} value={i}>{d.label}</option>)}
        </select>
      </div>
    </div>
  );
}

function Step2({ data, setField, onRoomNameChange, onAliasChange }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <div>
        <label style={labelStyle}>Raum-Name</label>
        <input style={inputStyle} value={data.roomName}
          onChange={e => onRoomNameChange(e.target.value)}
          placeholder="z.B. Kurswahl" autoFocus />
        <div style={{ color: "var(--muted)", fontSize: 10, fontFamily: "'Space Mono', monospace", marginTop: 4 }}>
          Default = Bot-Anzeigename. Bot wird Creator (Power Level 100).
        </div>
      </div>
      <div>
        <label style={labelStyle}>Raum-Alias (optional)</label>
        <input style={inputStyle} value={data.roomAlias}
          onChange={e => onAliasChange(e.target.value.toLowerCase().replace(/\s/g, "-"))}
          placeholder="kurswahl" />
        <div style={{ color: "var(--muted)", fontSize: 10, fontFamily: "'Space Mono', monospace", marginTop: 4 }}>
          Ergibt #{data.roomAlias || "raum-alias"}:server. Leer = nur Room-ID, kein Alias.
        </div>
      </div>
      <div>
        <label style={labelStyle}>Topic (optional)</label>
        <input style={inputStyle} value={data.roomTopic}
          onChange={e => setField("roomTopic", e.target.value)}
          placeholder="Worum geht's hier?" />
      </div>
      <Toggle
        label="Verschlüsselt (E2EE)"
        hint="Default aus. Viele Bot-Frameworks (z.B. maubot ohne Pantalaimon) brechen in E2EE-Räumen."
        checked={data.encrypted}
        onChange={() => setField("encrypted", !data.encrypted)}
      />
      <Toggle
        label="Öffentlich"
        hint="Default privat (nur per Einladung). Öffentlich = im Verzeichnis und joinbar."
        checked={data.isPublic}
        onChange={() => setField("isPublic", !data.isPublic)}
      />
    </div>
  );
}

function Toggle({ label, hint, checked, onChange }) {
  return (
    <div style={{
      display: "flex", justifyContent: "space-between", alignItems: "center",
      padding: "12px 14px", background: "var(--bg)",
      border: "1px solid var(--border)", borderRadius: 8,
    }}>
      <div style={{ flex: 1 }}>
        <div style={{ fontFamily: "'Syne', sans-serif", fontSize: 13, fontWeight: 700, color: "var(--text)" }}>{label}</div>
        <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, color: "var(--muted)", marginTop: 2, lineHeight: 1.5 }}>{hint}</div>
      </div>
      <button onClick={onChange} style={{
        width: 40, height: 22, borderRadius: 11,
        background: checked ? "var(--accent)" : "var(--border)",
        border: "none", cursor: "pointer", position: "relative",
        flexShrink: 0,
      }}>
        <span style={{
          position: "absolute", top: 2, left: checked ? 20 : 2,
          width: 18, height: 18, borderRadius: 9, background: "var(--bg)",
          transition: "left 0.15s",
        }} />
      </button>
    </div>
  );
}

function Step3({ data, extraMxid, setExtraMxid, addExtra, toggleInviteSelected, setInvitePL, removeInvite }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <p style={{ color: "var(--muted)", fontSize: 12, fontFamily: "'Space Mono', monospace", lineHeight: 1.6, margin: 0 }}>
        Wer wird in den Raum eingeladen? Power-Level:
        <strong style={{ color: "var(--text)" }}> Admin = 100</strong> (mit-administrieren),
        <strong style={{ color: "var(--text)" }}> Moderator = 50</strong> (Nachrichten redigieren, kicken),
        <strong style={{ color: "var(--text)" }}> Standard = 0</strong>.
      </p>
      <div style={{ display: "flex", flexDirection: "column", gap: 6, maxHeight: 280, overflowY: "auto" }}>
        {data.invites.length === 0 ? (
          <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 12, padding: 16, textAlign: "center" }}>
            Keine User in der Standard-Liste. Unten manuell hinzufügen oder Schritt überspringen.
          </div>
        ) : data.invites.map(inv => (
          <div key={inv.mxid} style={{
            display: "flex", alignItems: "center", gap: 10,
            padding: "10px 12px", background: "var(--bg)",
            border: "1px solid var(--border)", borderRadius: 8,
          }}>
            <input type="checkbox" checked={inv.selected}
              onChange={() => toggleInviteSelected(inv.mxid)}
              style={{ cursor: "pointer" }} />
            <div style={{ flex: 1, minWidth: 0, opacity: inv.selected ? 1 : 0.45 }}>
              <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 12, color: "var(--text)" }}>{inv.mxid}</div>
            </div>
            <select
              value={inv.power_level}
              disabled={!inv.selected}
              onChange={e => setInvitePL(inv.mxid, parseInt(e.target.value, 10))}
              style={{
                background: "var(--surface)", border: "1px solid var(--border)",
                borderRadius: 6, padding: "4px 8px", fontSize: 11,
                fontFamily: "'Space Mono', monospace", color: "var(--text)",
                opacity: inv.selected ? 1 : 0.45,
              }}>
              <option value={0}>Standard</option>
              <option value={50}>Moderator</option>
              <option value={100}>Admin</option>
            </select>
            <button onClick={() => removeInvite(inv.mxid)} style={{ ...btnGhostStyle, padding: "4px 8px", color: "#ff4d4d" }}>
              <Icon name="x" size={12} />
            </button>
          </div>
        ))}
      </div>
      <div style={{ display: "flex", gap: 8 }}>
        <input style={{ ...inputStyle, flex: 1 }} value={extraMxid}
          onChange={e => setExtraMxid(e.target.value)}
          onKeyDown={e => e.key === "Enter" && addExtra()}
          placeholder="@alice:matrix.hoetten.online" />
        <button onClick={addExtra} style={btnPrimaryStyle}>
          <Icon name="plus" size={13} /> Hinzufügen
        </button>
      </div>
    </div>
  );
}

function Step4({ data }) {
  const active = data.invites.filter(i => i.selected);
  const admins = active.filter(i => i.power_level >= 100);
  const mods = active.filter(i => i.power_level === 50);
  const duration = DURATIONS[data.tokenDurationIdx].label;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10, fontFamily: "'Space Mono', monospace", fontSize: 12 }}>
      <SummaryRow k="Bot anlegen" v={`@${data.localpart}:[server]`} sub={data.displayname && `Anzeigename: ${data.displayname}`} />
      <SummaryRow k="Token erzeugen" v={data.tokenLabel || "(ohne Label)"} sub={`Gültigkeit: ${duration}`} />
      <SummaryRow k="Raum anlegen" v={data.roomName}
        sub={[
          data.roomAlias && `Alias: #${data.roomAlias}:[server]`,
          data.roomTopic && `Topic: ${data.roomTopic}`,
          data.encrypted ? "verschlüsselt" : "unverschlüsselt",
          data.isPublic ? "öffentlich" : "privat",
        ].filter(Boolean).join(" · ")} />
      <SummaryRow k="Einladungen" v={`${active.length} User`}
        sub={active.length === 0
          ? "(keine)"
          : active.map(i => {
              const tag = i.power_level >= 100 ? " 👑" : i.power_level === 50 ? " 🛡" : "";
              return `${i.mxid}${tag}`;
            }).join(", ")} />
      {active.length > 0 && (
        <div style={{ background: "var(--accent-dim)", border: "1px solid rgba(0,200,150,0.3)", borderRadius: 8, padding: 12, color: "var(--text)", marginTop: 4, lineHeight: 1.6 }}>
          Bot ist Creator (PL 100). {admins.length} Admin{admins.length === 1 ? "" : "s"} (PL 100),
          {" "}{mods.length} Moderator{mods.length === 1 ? "" : "en"} (PL 50).
        </div>
      )}
    </div>
  );
}

function SummaryRow({ k, v, sub }) {
  return (
    <div style={{ padding: "10px 12px", background: "var(--bg)", border: "1px solid var(--border)", borderRadius: 8 }}>
      <div style={{ color: "var(--muted)", fontSize: 10, textTransform: "uppercase", letterSpacing: 1, marginBottom: 4 }}>{k}</div>
      <div style={{ color: "var(--text)", fontSize: 13, fontWeight: 700, fontFamily: "'Syne', sans-serif" }}>{v}</div>
      {sub && <div style={{ color: "var(--muted)", fontSize: 11, marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

function Step5({ result, addToast }) {
  const tokenStr = result.token?.access_token;

  function copyToken() {
    navigator.clipboard.writeText(tokenStr);
    addToast("Token kopiert", "success");
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {result.steps.map(s => <StepResult key={s.id} step={s} />)}
      </div>

      {tokenStr && (
        <div>
          <div style={labelStyle}>Access Token</div>
          <div style={{ display: "flex", gap: 8, alignItems: "stretch" }}>
            <div style={{
              flex: 1, background: "var(--bg)", border: "1px solid var(--accent)",
              borderRadius: 8, padding: "10px 12px", fontFamily: "'Space Mono', monospace",
              fontSize: 11, color: "var(--accent)", wordBreak: "break-all", lineHeight: 1.5,
            }}>{tokenStr}</div>
            <button onClick={copyToken} style={btnPrimaryStyle} title="Kopieren">
              <Icon name="copy" size={14} />
            </button>
          </div>
          <div style={{ color: "var(--muted)", fontSize: 10, fontFamily: "'Space Mono', monospace", marginTop: 6, lineHeight: 1.5 }}>
            Der Token liegt auch dauerhaft im Bot-Detail-Tab „Tokens".
          </div>
        </div>
      )}

      {result.room?.matrix_to && (
        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          {result.room.room_alias && (
            <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)", lineHeight: 1.6 }}>
              Raum-Alias: <span style={{ color: "var(--accent)" }}>{result.room.room_alias}</span>
            </div>
          )}
          <a href={result.room.matrix_to} target="_blank" rel="noopener noreferrer" style={{
            ...btnPrimaryStyle, width: "100%", justifyContent: "center",
            textDecoration: "none",
          }}>
            <Icon name="rooms" size={14} /> Raum in Element öffnen
          </a>
        </div>
      )}
    </div>
  );
}

function StepResult({ step }) {
  const icon = step.status === "ok" ? "check" : step.status === "skipped" ? "x" : "x";
  const color = step.status === "ok" ? "var(--accent)" : step.status === "skipped" ? "var(--muted)" : "#ff4d4d";
  const labels = {
    create_bot: "Bot anlegen",
    create_token: "Token erzeugen",
    create_room: "Raum anlegen",
  };
  return (
    <div style={{
      display: "flex", alignItems: "flex-start", gap: 10,
      padding: "10px 12px", background: "var(--bg)",
      border: "1px solid var(--border)", borderRadius: 8,
    }}>
      <div style={{ color, marginTop: 2 }}>
        <Icon name={icon} size={14} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontFamily: "'Syne', sans-serif", fontSize: 13, fontWeight: 700, color: "var(--text)" }}>
          {labels[step.id] || step.id}{" "}
          <span style={{ ...badgeStyle, color, border: `1px solid ${color}40`, marginLeft: 4 }}>{step.status}</span>
        </div>
        {step.detail && (
          <div style={{ color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 11, marginTop: 4, wordBreak: "break-all", lineHeight: 1.5 }}>
            {step.detail}
          </div>
        )}
      </div>
    </div>
  );
}

function Footer({ step, running, canAdvance, onBack, onNext, onExecute, onClose }) {
  if (step === 5) {
    return (
      <div style={{ display: "flex", gap: 10, marginTop: 16 }}>
        <button onClick={onClose} style={{ ...btnPrimaryStyle, flex: 1, justifyContent: "center" }}>
          Schließen
        </button>
      </div>
    );
  }
  return (
    <div style={{ display: "flex", gap: 10, marginTop: 16 }}>
      <button onClick={onBack} disabled={step === 1 || running}
        style={{ ...btnGhostStyle, flex: 1, justifyContent: "center" }}>
        Zurück
      </button>
      {step < 4 ? (
        <button onClick={onNext} disabled={!canAdvance}
          style={{ ...btnPrimaryStyle, flex: 2, justifyContent: "center" }}>
          Weiter
        </button>
      ) : (
        <button onClick={onExecute} disabled={running}
          style={{ ...btnPrimaryStyle, flex: 2, justifyContent: "center" }}>
          {running ? "Lege an…" : "Jetzt anlegen"}
        </button>
      )}
    </div>
  );
}
