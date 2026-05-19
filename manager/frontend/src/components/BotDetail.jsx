import { useState, useEffect } from "react";
import { Icon } from "./Icon.jsx";
import { apiGet, apiPut, apiDelete } from "../api.js";
import { CreateRoomTab } from "./CreateRoomTab.jsx";
import { TokenTab } from "./TokenTab.jsx";
import { AvatarPicker } from "./AvatarPicker.jsx";
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
  const [showAvatarPicker, setShowAvatarPicker] = useState(false);

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

  async function deleteFromRegistry() {
    if (!confirm(
      `Bot „${bot.displayname || localpart}" aus der Manager-Registry entfernen?\n\n` +
      `Der Synapse-User bleibt bestehen — Tokens, Räume, Mitgliedschaften sind nicht betroffen. ` +
      `Du kannst den Bot später per „Importieren" wieder reinholen.`
    )) return;
    try {
      await apiDelete(`/bots/${encodeURIComponent(mxid)}`);
      addToast("Aus Registry entfernt", "success");
      onBack();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
    }
  }

  async function eraseSynapse() {
    const phrase = `lösche ${localpart}`;
    const answer = prompt(
      `Bot „${bot.displayname || localpart}" PERMANENT löschen?\n\n` +
      `Synapse-User wird via Admin-API deaktiviert + erased: ` +
      `Profilbild, Anzeigename, Konto-Daten weg. Tokens invalidiert. ` +
      `Historische Nachrichten in Räumen bleiben aus Designgründen erhalten.\n\n` +
      `Zum Bestätigen tippe: ${phrase}`
    );
    if (answer?.trim() !== phrase) {
      if (answer !== null) addToast("Falsche Bestätigung, abgebrochen", "error");
      return;
    }
    try {
      await apiDelete(`/bots/${encodeURIComponent(mxid)}?erase_synapse=true`);
      addToast("Bot permanent gelöscht", "success");
      onBack();
    } catch (e) {
      addToast("Fehler: " + e.message, "error");
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
          <div
            onClick={() => bot.exists_in_synapse && setShowAvatarPicker(true)}
            title={bot.exists_in_synapse ? "Avatar wählen (Klick)" : "Bot existiert nicht in Synapse"}
            style={{
              width: 56, height: 56, borderRadius: 14, background: "var(--accent-dim)",
              display: "flex", alignItems: "center", justifyContent: "center",
              fontFamily: "'Syne', sans-serif", fontWeight: 800, fontSize: 24, color: "var(--accent)",
              flexShrink: 0, cursor: bot.exists_in_synapse ? "pointer" : "default",
              overflow: "hidden", position: "relative",
            }}>
            {bot.avatar_url ? (
              <img
                src={`/api/media-thumbnail?mxc=${encodeURIComponent(bot.avatar_url)}&size=112`}
                alt=""
                style={{ width: "100%", height: "100%", objectFit: "cover" }}
                onError={e => { e.currentTarget.style.display = "none"; }}
              />
            ) : initial}
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
            <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)", marginTop: 4 }}>
              {mxid}{" "}
              <a href={`https://matrix.to/#/${mxid}`} target="_blank" rel="noopener noreferrer"
                 style={{ color: "var(--accent)", textDecoration: "none" }}
                 title="In Element öffnen">↗</a>
            </div>
            <div style={{ display: "flex", gap: 6, marginTop: 10, flexWrap: "wrap" }}>
              <span style={{ ...badgeStyle, background: bot.deactivated ? "rgba(255,77,77,0.15)" : "rgba(0,200,150,0.12)", color: bot.deactivated ? "#ff4d4d" : "var(--accent)", border: `1px solid ${bot.deactivated ? "rgba(255,77,77,0.3)" : "rgba(0,200,150,0.3)"}` }}>
                {bot.deactivated ? "deaktiviert" : "aktiv"}
              </span>
              <span style={badgeStyle}>bot</span>
              {!bot.exists_in_synapse && (
                <span style={{ ...badgeStyle, color: "#ffa94d", border: "1px solid rgba(255,169,77,0.3)" }}>verwaist</span>
              )}
              {(bot.tags || []).map(t => (
                <span key={t} style={{ ...badgeStyle, color: "var(--accent)", border: "1px solid rgba(0,200,150,0.3)" }}>
                  #{t}
                </span>
              ))}
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
            <TagsEditor
              tags={bot.tags || []}
              onChange={async (next) => {
                try {
                  const updated = await apiPut(`/bots/${encodeURIComponent(mxid)}`, { tags: next });
                  setBot(updated);
                } catch (e) { addToast("Fehler: " + e.message, "error"); }
              }}
            />
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

            <div style={{ marginTop: 24, padding: 20, background: "rgba(255,77,77,0.06)", border: "1px solid rgba(255,77,77,0.25)", borderRadius: 10 }}>
              <div style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 14, color: "#ff4d4d", marginBottom: 6 }}>
                Danger Zone
              </div>
              <div style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)", marginBottom: 14, lineHeight: 1.6 }}>
                {bot.exists_in_synapse
                  ? `'Aus Registry entfernen' lässt den Synapse-User in Ruhe — re-importierbar. 'Permanent löschen' erased ihn endgültig.`
                  : `Der Synapse-Account fehlt bereits — der Registry-Eintrag ist verwaist und kann gefahrlos entfernt werden.`}
              </div>
              <div style={{ display: "flex", gap: 8 }}>
                <button onClick={deleteFromRegistry}
                  style={{ ...btnGhostStyle, color: "#ffa94d", borderColor: "rgba(255,169,77,0.3)", fontSize: 12 }}>
                  <Icon name="trash" size={13} /> Aus Registry entfernen
                </button>
                {bot.exists_in_synapse && (
                  <button onClick={eraseSynapse}
                    style={{ ...btnGhostStyle, color: "#ff4d4d", borderColor: "rgba(255,77,77,0.3)", fontSize: 12 }}>
                    <Icon name="trash" size={13} /> Permanent löschen (Synapse-Erase)
                  </button>
                )}
              </div>
            </div>
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

      {showAvatarPicker && (
        <AvatarPicker
          mxid={mxid}
          addToast={addToast}
          onClose={() => setShowAvatarPicker(false)}
          onApplied={(avatar_url) => {
            setBot(b => ({ ...b, avatar_url }));
            setShowAvatarPicker(false);
          }}
        />
      )}
    </div>
  );
}

function TagsEditor({ tags, onChange }) {
  const [adding, setAdding] = useState(false);
  const [newTag, setNewTag] = useState("");

  function clean(s) { return s.toLowerCase().replace(/[^a-z0-9_-]/g, "").slice(0, 24); }

  async function addTag() {
    const t = clean(newTag);
    if (!t) return;
    if (tags.includes(t)) { setNewTag(""); setAdding(false); return; }
    await onChange([...tags, t]);
    setNewTag("");
    setAdding(false);
  }

  async function removeTag(t) {
    await onChange(tags.filter(x => x !== t));
  }

  return (
    <div style={{
      padding: "12px 14px", background: "var(--bg)",
      border: "1px solid var(--border)", borderRadius: 10,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
        <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 10, color: "var(--muted)", textTransform: "uppercase", letterSpacing: 1 }}>Tags</span>
        <div style={{ flex: 1 }} />
        {!adding && (
          <button onClick={() => setAdding(true)} style={{ ...btnGhostStyle, padding: "4px 8px", fontSize: 11 }}>
            <Icon name="plus" size={11} /> Tag
          </button>
        )}
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center" }}>
        {tags.length === 0 && !adding && (
          <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--muted)" }}>
            keine Tags — z.B. prod / dev / personal
          </span>
        )}
        {tags.map(t => (
          <span key={t} style={{
            ...badgeStyle, color: "var(--accent)",
            border: "1px solid rgba(0,200,150,0.3)", display: "inline-flex", gap: 4, alignItems: "center",
          }}>
            #{t}
            <button onClick={() => removeTag(t)}
              style={{ background: "none", border: "none", color: "var(--accent)", cursor: "pointer", padding: 0, lineHeight: 1 }}>×</button>
          </span>
        ))}
        {adding && (
          <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
            <input
              autoFocus
              value={newTag}
              onChange={e => setNewTag(clean(e.target.value))}
              onKeyDown={e => {
                if (e.key === "Enter") addTag();
                if (e.key === "Escape") { setAdding(false); setNewTag(""); }
              }}
              placeholder="tag-name"
              style={{
                background: "var(--surface)", border: "1px solid var(--border)",
                borderRadius: 8, padding: "4px 8px", fontSize: 11,
                fontFamily: "'Space Mono', monospace", color: "var(--text)",
                outline: "none", width: 100,
              }}
            />
            <button onClick={addTag} style={{ ...btnGhostStyle, padding: "4px 6px" }}>
              <Icon name="check" size={11} />
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
