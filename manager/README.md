# Matrix Bot Manager

Web-UI zum Verwalten der Bot-User auf einem privaten Synapse-Homeserver.
Laeuft als einzelner Container neben deinem Synapse-Stack, kommuniziert mit
Synapse ueber das Docker-Netz und braucht selbst keinen direkten Zugriff aus
dem Internet.

Komplementaer zum CLI-Tool [`matrix-register-bot.sh`](../matrix-register-bot.sh)
im Hauptverzeichnis — beide Tools sprechen dieselbe Admin-API, das CLI ist
fuers Anlegen einzelner Bots aus Skripten heraus, der Manager ist die GUI fuer
das laufende Drumherum (Token rotieren, Raeume anlegen, Bots loeschen).

## Was die UI kann

- **Setup-Wizard „Bot + Raum komplett"** — Bot, Token (max. Dauer),
  Raum (mit Topic/Alias/E2EE/öffentlich), Invites mit Per-User-Admin-Flag in
  einem Rutsch. Orchestriert vom Backend, gibt am Ende eine Statusliste
  pro Schritt zurück.
- **Audit-Log** — jede schreibende Aktion (Bot-/Token-/Raum-Anlage,
  Wizard-Setup, Standard-User-Pflege, Permanent-Löschung) landet in der
  Manager-DB und ist im UI durchsuchbar (Activity-Icon im Header).
  Exportierbar als CSV oder JSON.
- **Bot-Tags** — frei vergebbare Labels pro Bot (z.B. `prod`, `dev`,
  `personal`). Anzeige in der Bot-Karte, Filter-Leiste oben in der Liste.
- **Suche** in der Bot-Liste — über Displayname / Localpart / MXID.
- **Bulk-Operationen** — Checkbox pro Karte, dann „Deaktivieren",
  „Reaktivieren" oder „Aus Registry entfernen" auf der ganzen Selektion.
- **DB-Export** — Settings-Screen liefert atomaren SQLite-Snapshot
  (VACUUM INTO) als Download fuer Offline-Backups.
- **Erweiterter Health-Check** — `/api/health` prueft Synapse-Reachability,
  Admin-Token-Gueltigkeit und DB; gibt Counts zurueck (Bots, Default-User,
  Audit-Eintraege) fuer Monitoring.
- **Element-Quicklink** — MXID-Pfeil im Bot-Detail-Hero oeffnet matrix.to.
- **Testnachricht** — kleiner Block in der Bot-Uebersicht: Empfaenger aus der
  Standard-User-Liste waehlen, Nachricht eintippen, Bot legt einen 1:1-DM
  an (oder nutzt einen bestehenden) und postet die Nachricht. Praktisch
  zum Verifizieren, ob ein Bot wirklich senden kann.
- **Nachtraegliches Einladen** — der Raeume-Tab listet pro Raum Name,
  Topic, Member-Count und ist aufklappbar. Im aufgeklappten Bereich gibt's
  einen Dropdown mit Standard-Usern (gefiltert: nicht schon drin/eingeladen),
  Power-Level-Auswahl und einen "Einladen"-Knopf. Plus ein Ad-hoc-Feld
  fuer User ausserhalb der Standard-Liste.
- **Avatar pro Bot** — Klick auf den Avatar-Kreis im Bot-Detail öffnet
  einen Picker mit **15 mitgelieferten SVG-Avataren** im gleichen Stil
  (Roboter, Tiere, Symbole) ODER File-Upload. Built-in-SVGs werden
  client-seitig zu 256×256-PNG rasterisiert, damit Synapses Thumbnail-
  Endpoint sie sauber liefert. Funktioniert auch in Element und Ketesa.
- **Bot dauerhaft löschen** — Danger-Zone im Bot-Detail mit zwei Stufen:
  „Aus Registry entfernen" (re-importierbar) oder „Permanent löschen"
  (Synapse erase via Admin-API, hard confirm per Texteingabe).
- **Manager-eigene Bot-Registry** (SQLite) — unabhaengig vom Synapse-internen
  `user_type=bot`-Flag, das auch versehentlich auf Nicht-Bots landen kann
- Bots auflisten (nur aus der Registry)
- Bestehende Synapse-Bots importieren (Modal mit allen `user_type=bot`-Usern,
  einzeln in die Registry uebernehmen)
- Neuen Bot anlegen (Localpart + Anzeigename, zufaelliges Passwort)
- Bot-Detail: Anzeigename inline editieren, Bot **deaktivieren / reaktivieren**
- **Token-Verwaltung** pro Bot:
  - mehrere Tokens parallel mit individuellem Label und Gueltigkeitsdauer
    (1h / 1d / 30d / 1y / 10y / "nie")
  - Klartext-Anzeige (Reveal-Toggle), Copy-Button, einzeln loeschbar
  - Label wird in Synapse als Device-Display-Name gesetzt
  - Loeschen invalidiert das Synapse-Device sofort
- Raeume eines Bots auflisten
- Raum **als Bot** anlegen (Bot ist Creator + Power Level 100), optional
  verschluesselt/oeffentlich, mit voreingestellter Einladungs-Liste
- Standard-Nutzer-Liste pflegen (server-seitig in der Manager-DB, mit
  Per-User-Default-Admin-Flag)

## Architektur

```
Browser ───► nginx-proxy-manager ───► matrix-bot-manager (FastAPI)
                                             │
                                  /api/bots/*        — Registry-CRUD (SQLite + Synapse)
                                  /api/discovery/*   — Lookup gegen Synapse fuer Import
                                  /api/synapse/*     + Admin-Token  (Legacy-Proxy)
                                  /api/client/*      + Bot-Token    (createRoom)
                                             │
                                             ▼
                                       matrix-synapse:8008
                                             │
                       SQLite /data/manager.db (Registry + Tokens)
```

- **Frontend**: React + Vite, statisch gebaut, vom Backend ausgeliefert
- **Backend**: FastAPI + httpx + aiosqlite. Drei Endpoint-Familien:
  - `/api/bots/*` — Manager-eigene Bot-Registry mit Live-Daten aus Synapse
    angereichert (CRUD, Raeume, spaeter Token-Verwaltung)
  - `/api/discovery/*` — Lookup gegen Synapse (z.B. Liste aller User mit
    `user_type=bot`, die noch nicht in der Registry sind, fuer den Import)
  - `/api/synapse/*` + `/api/client/*` — generische Proxies, behalten wir
    fuer Calls, die noch nicht im Bot-API gekapselt sind (`createRoom`)
- **Konfiguration**: drei Env-Variablen:
  - `SYNAPSE_URL` — z.B. `http://matrix-synapse:8008`
  - `SYNAPSE_ADMIN_TOKEN` — Access-Token eines Synapse-Admin-Users
  - `DB_PATH` (optional) — Default `/data/manager.db`
- **Persistenz**: SQLite unter `DB_PATH`. Sollte als Volume eingehangen
  sein, sonst sind Registry, Tokens und Standard-Nutzer-Liste beim
  naechsten `--build` weg.
- **Sicherheit**: Der Admin-Token verlaesst den Container nie und landet
  weder im Browser noch im LocalStorage. Bot-Tokens werden ab v0.6 in
  SQLite gespeichert — wer Lesezugriff auf das Volume hat, sieht sie.
- **Media-Thumbnails** werden ueber `/api/media-thumbnail?mxc=...` durch
  den Container geproxyt — der Browser braucht keinen direkten Zugriff
  auf das Synapse-Media-Endpoint.

## Voraussetzungen

- Docker + docker compose
- Bestehender Synapse-Stack mit Admin-User und Admin-Access-Token. Falls noch
  nicht vorhanden: einmalig
  ```
  docker exec matrix-synapse register_new_matrix_user \
    -c /data/homeserver.yaml http://localhost:8008
  ```
  und beim Prompt „Make admin?" mit `yes` antworten. Den Token kannst du dir
  z.B. mit dem [`matrix-register-bot.sh`](../matrix-register-bot.sh) holen
  (`./matrix-register-bot.sh ... --admin-user alice --admin-pass ...`) oder
  in Element generieren.

## Quickstart

### 1. In den Compose-Stack einbauen

Snippet aus [`docker-compose.yml.snippet`](docker-compose.yml.snippet) in dein
bestehendes `docker-compose.yml` neben dem Synapse-Stack einfuegen. **Achtung:**
Ab v0.6 brauchst du zusaetzlich ein Volume fuer `/data` (SQLite-Persistenz),
sonst sind Bot-Registry und Tokens nach jedem `--build` weg.

```yaml
volumes:
  - bot_manager_data:/data
# ... und ganz unten:
volumes:
  bot_manager_data:
```

Anschliessend `.env` neben deinem Compose-File anlegen:

```env
SYNAPSE_ADMIN_TOKEN=syt_dein_admin_token
```

### 2. Bauen + Starten

```bash
docker compose up -d --build matrix-bot-manager
docker compose logs -f matrix-bot-manager
```

Sobald `Application startup complete` im Log steht, antwortet
`http://<host>:8082/api/health` mit `server_name`.

### 3. Reverse Proxy

Im Nginx Proxy Manager einen neuen Proxy Host anlegen, der auf
`http://<docker-host>:8082` zeigt (oder den Container-Namen, wenn NPM im
selben Docker-Netz haengt). Keine speziellen Einstellungen noetig — das
Backend hat keine Websockets, kein Auth-Layer.

> Wenn du dem Bot Manager im Internet Login schenkst, hau eine Basic-Auth
> oder Access-List in NPM davor. Es gibt **keine** App-eigene Authentifizierung.

## Entwicklung

Frontend und Backend laufen lokal getrennt:

```bash
# Backend (Python 3.13+, in einer venv empfohlen)
cd backend
pip install -r requirements.txt
export SYNAPSE_URL=http://matrix-synapse:8008   # oder lokal: http://localhost:8008
export SYNAPSE_ADMIN_TOKEN=syt_dev_token
uvicorn server:app --reload --port 8080
```

```bash
# Frontend (Node 22+)
cd frontend
npm install
npm run dev   # auf http://localhost:5173
```

Der Vite-Dev-Server proxyt `/api/*` automatisch nach `http://localhost:8080`
(siehe [`vite.config.js`](frontend/vite.config.js)).

## Sicherheit

- Der Admin-Token liegt ausschliesslich als Env-Variable im Container und
  geht nie an den Browser. Wenn jemand das gebaute Frontend inspiziert,
  findet er den Token dort nicht.
- Synapse muss nicht oeffentlich erreichbar sein — der Bot Manager spricht
  ueber das Docker-Netz mit ihm. Du kannst Port 8008 von Synapse intern
  lassen.
- Trotzdem: der Container selbst hat keine Auth. Wer `http://<host>:8082`
  erreicht, kann ueber den Proxy alles tun, was der Admin-Token darf.
  Reverse-Proxy mit Auth davor schalten oder den Port nicht exposen.
