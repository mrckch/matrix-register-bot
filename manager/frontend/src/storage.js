// Frontend-Persistenz fuer Werte, die nur den Browser betreffen.
// Aktuell: die Standard-Nutzer-Liste (defaultUsers).
//
// Server-URL und Admin-Token liegen NICHT mehr hier — die werden serverseitig
// als Env-Variable in den Container injiziert.

const STORAGE_KEY = "matrix_bot_manager_config_v2";

export function loadConfig() {
  try {
    const cfg = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
    if (!cfg.defaultUsers) cfg.defaultUsers = [];
    return cfg;
  } catch {
    return { defaultUsers: [] };
  }
}

export function saveConfig(cfg) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
}
