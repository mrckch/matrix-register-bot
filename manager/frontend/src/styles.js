// Geteilte Inline-Style-Konstanten. Identisch zum Original-Single-File-Stand.
// CSS-Variablen werden global in App.jsx in einem <style>-Block deklariert.

export const labelStyle = {
  display: "block",
  fontFamily: "'Space Mono', monospace",
  fontSize: 10,
  letterSpacing: 2,
  textTransform: "uppercase",
  color: "var(--muted)",
  marginBottom: 6,
};

export const inputStyle = {
  width: "100%",
  background: "var(--bg)",
  border: "1px solid var(--border)",
  borderRadius: 8,
  padding: "10px 12px",
  color: "var(--text)",
  fontFamily: "'Space Mono', monospace",
  fontSize: 13,
  outline: "none",
  boxSizing: "border-box",
  transition: "border-color 0.15s",
};

export const btnPrimaryStyle = {
  display: "inline-flex",
  alignItems: "center",
  gap: 7,
  background: "var(--accent)",
  color: "#000",
  border: "none",
  borderRadius: 8,
  padding: "10px 18px",
  fontFamily: "'Space Mono', monospace",
  fontSize: 12,
  fontWeight: 700,
  cursor: "pointer",
  transition: "opacity 0.15s",
  whiteSpace: "nowrap",
};

export const btnGhostStyle = {
  display: "inline-flex",
  alignItems: "center",
  gap: 6,
  background: "transparent",
  color: "var(--muted)",
  border: "1px solid var(--border)",
  borderRadius: 8,
  padding: "8px 12px",
  fontFamily: "'Space Mono', monospace",
  fontSize: 12,
  cursor: "pointer",
  transition: "color 0.15s, border-color 0.15s",
};

export const badgeStyle = {
  fontFamily: "'Space Mono', monospace",
  fontSize: 9,
  letterSpacing: 1,
  textTransform: "uppercase",
  padding: "3px 8px",
  borderRadius: 4,
  background: "rgba(255,255,255,0.06)",
  color: "var(--muted)",
  border: "1px solid var(--border)",
};

export const modalOverlayStyle = {
  position: "fixed",
  inset: 0,
  background: "rgba(0,0,0,0.7)",
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  zIndex: 500,
};

export const modalStyle = {
  background: "var(--surface)",
  border: "1px solid var(--border)",
  borderRadius: 16,
  padding: 28,
  width: 400,
  boxShadow: "0 24px 80px rgba(0,0,0,0.6)",
};
