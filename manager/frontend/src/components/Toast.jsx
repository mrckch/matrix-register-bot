import { useState, useCallback } from "react";

export function Toast({ toasts }) {
  return (
    <div style={{ position: "fixed", bottom: 24, right: 24, zIndex: 1000, display: "flex", flexDirection: "column", gap: 8 }}>
      {toasts.map((t) => (
        <div key={t.id} style={{
          background: t.type === "error" ? "#ff4d4d" : t.type === "success" ? "#00c896" : "#2a2a3a",
          color: "#fff",
          padding: "10px 16px",
          borderRadius: 8,
          fontSize: 13,
          fontFamily: "'IBM Plex Mono', monospace",
          boxShadow: "0 4px 20px rgba(0,0,0,0.4)",
          maxWidth: 320,
          animation: "slideIn 0.2s ease",
        }}>
          {t.msg}
        </div>
      ))}
    </div>
  );
}

export function useToast() {
  const [toasts, setToasts] = useState([]);
  const addToast = useCallback((msg, type = "info") => {
    const id = Date.now() + Math.random();
    setToasts((prev) => [...prev, { id, msg, type }]);
    setTimeout(() => setToasts((prev) => prev.filter((t) => t.id !== id)), 3500);
  }, []);
  return { toasts, addToast };
}
