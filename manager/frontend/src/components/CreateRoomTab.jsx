import { useState } from "react";
import { Icon } from "./Icon.jsx";
import { synapsePost, clientPost } from "../api.js";
import {
  labelStyle, inputStyle, btnPrimaryStyle, btnGhostStyle,
} from "../styles.js";

export function CreateRoomTab({ bot, config, addToast, onRoomCreated }) {
  const [name, setName] = useState("");
  const [topic, setTopic] = useState("");
  const [isEncrypted, setIsEncrypted] = useState(true);
  const [isPublic, setIsPublic] = useState(false);
  const [extraMxid, setExtraMxid] = useState("");
  const [creating, setCreating] = useState(false);

  // selected: { mxid, admin, selected }
  const [selected, setSelected] = useState(
    (config.defaultUsers || []).map(u => ({ mxid: u.mxid, admin: !!(u.default_admin ?? u.defaultAdmin), selected: true }))
  );

  function toggleSelected(mxid) {
    setSelected(prev => prev.map(s => s.mxid === mxid ? { ...s, selected: !s.selected } : s));
  }
  function toggleAdmin(mxid) {
    setSelected(prev => prev.map(s => s.mxid === mxid ? { ...s, admin: !s.admin } : s));
  }
  function addExtra() {
    const mxid = extraMxid.trim();
    if (!mxid) return;
    if (!mxid.startsWith("@") || !mxid.includes(":")) {
      addToast("Matrix-ID muss Format @user:server haben", "error");
      return;
    }
    if (selected.find(s => s.mxid === mxid)) {
      addToast("Dieser User ist schon in der Liste", "error");
      return;
    }
    setSelected(prev => [...prev, { mxid, admin: false, selected: true }]);
    setExtraMxid("");
  }
  function removeExtra(mxid) {
    setSelected(prev => prev.filter(s => s.mxid !== mxid));
  }

  async function createRoom() {
    if (!name.trim()) {
      addToast("Bitte einen Raumnamen vergeben", "error");
      return;
    }
    setCreating(true);
    try {
      // 1. Get bot's access token via Admin-API (Backend reicht Admin-Token an)
      const tokenResp = await synapsePost(`/v1/users/${encodeURIComponent((bot.mxid || bot.name))}/login`);
      const botToken = tokenResp.access_token;

      // 2. Build createRoom payload
      const activeInvites = selected.filter(s => s.selected);
      const inviteList = activeInvites.map(s => s.mxid);

      const initialState = [];
      if (isEncrypted) {
        initialState.push({
          type: "m.room.encryption",
          state_key: "",
          content: { algorithm: "m.megolm.v1.aes-sha2" },
        });
      }

      // Power level overrides — bot is creator (100), set admins to 100
      const userPowerLevels = { [(bot.mxid || bot.name)]: 100 };
      activeInvites.filter(s => s.admin).forEach(s => {
        userPowerLevels[s.mxid] = 100;
      });

      const payload = {
        name: name.trim(),
        topic: topic.trim() || undefined,
        invite: inviteList,
        preset: isPublic ? "public_chat" : "private_chat",
        visibility: isPublic ? "public" : "private",
        initial_state: initialState,
        power_level_content_override: {
          users: userPowerLevels,
        },
      };

      // 3. Create room as bot (Client-API, Bot-Token im Header)
      const result = await clientPost(botToken, "/createRoom", payload);

      addToast(`Raum erstellt: ${result.room_id}`, "success");

      // Reset form
      setName("");
      setTopic("");
      onRoomCreated();
    } catch (e) {
      addToast("Fehler beim Erstellen: " + e.message, "error");
    } finally {
      setCreating(false);
    }
  }

  const hasDefaults = (config.defaultUsers || []).length > 0;

  return (
    <div>
      <p style={{ color: "var(--muted)", fontSize: 13, marginBottom: 20, fontFamily: "'Space Mono', monospace", lineHeight: 1.7 }}>
        Der Bot erstellt den Raum selbst und ist damit automatisch Admin. Ausgewählte Nutzer werden eingeladen.
      </p>

      {/* Room basics */}
      <div style={{ display: "flex", flexDirection: "column", gap: 14, marginBottom: 24 }}>
        <div>
          <label style={labelStyle}>Raumname</label>
          <input style={inputStyle} value={name} onChange={e => setName(e.target.value)} placeholder="Notifications" />
        </div>
        <div>
          <label style={labelStyle}>Topic (optional)</label>
          <input style={inputStyle} value={topic} onChange={e => setTopic(e.target.value)} placeholder="Benachrichtigungen von MeineApp" />
        </div>
        <div style={{ display: "flex", gap: 10 }}>
          <button
            onClick={() => setIsEncrypted(!isEncrypted)}
            style={{
              ...btnGhostStyle, flex: 1, justifyContent: "center",
              background: isEncrypted ? "var(--accent-dim)" : "transparent",
              color: isEncrypted ? "var(--accent)" : "var(--muted)",
              borderColor: isEncrypted ? "rgba(0,200,150,0.3)" : "var(--border)",
            }}
          >
            <Icon name="shield" size={13} /> Verschlüsselt
          </button>
          <button
            onClick={() => setIsPublic(!isPublic)}
            style={{
              ...btnGhostStyle, flex: 1, justifyContent: "center",
              background: isPublic ? "var(--accent-dim)" : "transparent",
              color: isPublic ? "var(--accent)" : "var(--muted)",
              borderColor: isPublic ? "rgba(0,200,150,0.3)" : "var(--border)",
            }}
          >
            <Icon name="rooms" size={13} /> Öffentlich
          </button>
        </div>
      </div>

      {/* Invite list */}
      <div style={{ marginBottom: 16 }}>
        <label style={{ ...labelStyle, marginBottom: 10 }}>Einladen</label>
        {!hasDefaults && selected.length === 0 ? (
          <div style={{
            padding: 14, background: "var(--bg)", border: "1px dashed var(--border)", borderRadius: 8,
            color: "var(--muted)", fontFamily: "'Space Mono', monospace", fontSize: 11, textAlign: "center",
          }}>
            Keine Standard-Nutzer gepflegt. Füge sie unten ad-hoc hinzu oder pflege sie in den Einstellungen.
          </div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            {selected.map(s => (
              <div key={s.mxid} style={{
                display: "flex", alignItems: "center", gap: 10,
                padding: "10px 14px",
                background: s.selected ? "var(--bg)" : "transparent",
                border: `1px solid ${s.selected ? "var(--border)" : "transparent"}`,
                borderRadius: 8,
                opacity: s.selected ? 1 : 0.45,
                cursor: "pointer",
                transition: "opacity 0.15s, background 0.15s",
              }}
                onClick={() => toggleSelected(s.mxid)}
              >
                <div style={{
                  width: 18, height: 18, borderRadius: 4,
                  border: `2px solid ${s.selected ? "var(--accent)" : "var(--muted)"}`,
                  background: s.selected ? "var(--accent)" : "transparent",
                  display: "flex", alignItems: "center", justifyContent: "center",
                  flexShrink: 0,
                }}>
                  {s.selected && <Icon name="check" size={11} />}
                </div>
                <span style={{ fontFamily: "'Space Mono', monospace", fontSize: 11, color: "var(--text)", flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                  {s.mxid}
                </span>
                <button
                  onClick={(e) => { e.stopPropagation(); toggleAdmin(s.mxid); }}
                  disabled={!s.selected}
                  style={{
                    ...btnGhostStyle,
                    background: s.admin && s.selected ? "var(--accent-dim)" : "transparent",
                    color: s.admin && s.selected ? "var(--accent)" : "var(--muted)",
                    borderColor: s.admin && s.selected ? "rgba(0,200,150,0.3)" : "var(--border)",
                    padding: "5px 9px",
                    fontSize: 11,
                  }}
                  title="Als Admin einladen (Power Level 100)"
                >
                  <Icon name="shield" size={11} /> Admin
                </button>
                {!(config.defaultUsers || []).find(u => u.mxid === s.mxid) && (
                  <button onClick={(e) => { e.stopPropagation(); removeExtra(s.mxid); }} style={{ ...btnGhostStyle, padding: "5px 8px" }} title="Entfernen">
                    <Icon name="x" size={11} />
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Add ad-hoc user */}
      <div style={{ display: "flex", gap: 8, marginBottom: 24 }}>
        <input
          style={{ ...inputStyle, flex: 1 }}
          value={extraMxid}
          onChange={e => setExtraMxid(e.target.value)}
          onKeyDown={e => e.key === "Enter" && addExtra()}
          placeholder="@weiterer:server.de"
        />
        <button onClick={addExtra} disabled={!extraMxid} style={btnGhostStyle}>
          <Icon name="plus" size={13} /> Hinzufügen
        </button>
      </div>

      {/* Submit */}
      <button onClick={createRoom} disabled={creating || !name.trim()} style={{ ...btnPrimaryStyle, width: "100%", justifyContent: "center", padding: "12px 20px" }}>
        {creating ? "Erstelle Raum…" : "Raum erstellen"}
      </button>
    </div>
  );
}
