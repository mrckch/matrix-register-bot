# matrix-register-bot

Interaktives Bash-Werkzeug zum **Verwalten von Bot-Accounts auf einem privaten
Synapse-Homeserver** (Matrix). Führt Schritt für Schritt durch alles, was man
sonst vergisst — und kann denselben Job auch non-interaktiv aus Skripten heraus.

Ziel: Du musst dir nicht jedes Mal die Synapse-Admin-API ins Gedächtnis
rufen, wenn du einen neuen Bot brauchst, einen Token rotieren oder einen Bot
abschalten willst.

## Subcommands

| Befehl | Was er macht |
|---|---|
| `register` (Default) | Neuen Bot anlegen, Passwort + Access-Token erzeugen, in Räume joinen, optional direkt in maubot eintragen |
| `invite <bot> <raum>...` | Bestehenden Bot in (weitere) Räume joinen (Synapse Admin force-join) |
| `rotate-token <bot>` | Mit dem gespeicherten Bot-Passwort einen neuen Access-Token holen |
| `deactivate <bot> [--erase]` | Bot auf dem Server abschalten (optional Daten löschen) |
| `maubot-add <bot>` | Bestehenden Bot als Client in eine [maubot](https://github.com/maubot/maubot)-Instanz eintragen |
| `maubot-remove <bot>` | Bot aus der maubot-Instanz entfernen |
| `help` | Hilfe anzeigen |

## Voraussetzungen

### Auf deinem Rechner (Debian 13)

```bash
sudo apt update && sudo apt install -y curl jq openssl
```

### Auf dem Synapse-Server: Ein Admin-User muss existieren

Synapse erzeugt keinen „Initial-Admin" für dich. Einmalig auf dem Synapse-Host:

```bash
sudo register_new_matrix_user \
  -c /etc/matrix-synapse/homeserver.yaml \
  http://localhost:8008
```

Beim Prompt **„Make admin? (yes/no)"** mit `yes` antworten.

Alternative: einen bestehenden User als Admin markieren —
`UPDATE users SET admin = 1 WHERE name = '@alice:example.org';`

## Schneller Einstieg

```bash
git clone git@github.com:mrckch/matrix-register-bot.git
cd matrix-register-bot
chmod +x matrix-register-bot.sh
./matrix-register-bot.sh
```

Den Prompts folgen. Bei jedem Schritt erklärt das Skript in grauer Schrift,
was gerade passiert und warum.

### Beispielsitzung (interaktiv)

```
===== Schritt 1: Homeserver-URL eingeben =====
  Die Homeserver-URL ist die Adresse, unter der dein Matrix-Server seine API
  anbietet. ...
  Homeserver-URL: https://matrix.example.org

===== Schritt 3: Admin-Zugang einrichten =====
  Auswahl (1/2) [2]: 2
  Admin-Benutzername (Localpart): alice
  Passwort des Admin-Users: ******
[OK] Login erfolgreich. Server-Domain: example.org

===== Schritt 5: Bot-Benutzername (Localpart) waehlen =====
  Localpart des Bots: wetterbot
[i] Vollstaendige Matrix-ID: @wetterbot:example.org
...
===== Schritt 12: Raeume beitreten (optional) =====
  Raeume (leer = ueberspringen): #meldungen:example.org,!abcdef:example.org
[OK] Bot ist Raum beigetreten: #meldungen:example.org -> !xyz:example.org
[OK] Bot ist Raum beigetreten: !abcdef:example.org -> !abcdef:example.org

===== Schritt 13: Fertig — Zusammenfassung =====
Bot angelegt:
  Matrix-ID:       @wetterbot:example.org
  Credentials in:  /home/marc/.config/matrix-register-bot/wetterbot.env
```

## Non-interaktiv (für Automatisierung)

Alle Werte als Flag mitgeben + `--non-interactive`:

```bash
./matrix-register-bot.sh register \
  --server https://matrix.example.org \
  --admin-token "$ADMIN_TOKEN" \
  --bot wetterbot \
  --displayname "Wetter Bot" \
  --generate-password \
  --rooms "#meldungen:example.org,!abcdef:example.org" \
  --non-interactive
```

Statt `--admin-token` geht auch `--admin-user alice --admin-pass ...`. Achtung:
Passwörter auf der Kommandozeile landen in der Shell-History — für reguläres
Skripten ist Admin-Token aus einer Env-Variable die bessere Wahl.

## Weitere Beispiele

### Bestehenden Bot in einen neuen Raum joinen

```bash
./matrix-register-bot.sh invite wetterbot "#neuer-raum:example.org" \
  --admin-token "$ADMIN_TOKEN"
```

Force-Join funktioniert für Räume auf dem **eigenen** Homeserver. Für
Federation-Räume muss der Bot dort manuell eingeladen werden — joinen kann er
sich danach selbst über den gespeicherten Token.

### Access-Token rotieren

Token kompromittiert oder einfach vorsichtig wechseln:

```bash
./matrix-register-bot.sh rotate-token wetterbot \
  --server https://matrix.example.org
```

Braucht **kein** Admin-Token — das Bot-Passwort steht in der Config. Die alte
Config wird mit Zeitstempel als `.bak` gesichert.

### Bot abschalten

```bash
# Sanft: User existiert weiter, kann sich aber nicht mehr einloggen
./matrix-register-bot.sh deactivate wetterbot --admin-token "$ADMIN_TOKEN"

# Hart: zusätzlich Profil/Avatar löschen (GDPR-Style, irreversibel)
./matrix-register-bot.sh deactivate wetterbot --admin-token "$ADMIN_TOKEN" --erase
```

## maubot-Integration

Wenn du [maubot](https://github.com/maubot/maubot) als Plugin-Bot-Framework
betreibst, kann das Skript den frisch angelegten Bot direkt als **Client** in
maubot eintragen. Alle nötigen Werte (Homeserver-URL, Access-Token, Device-ID,
Displayname) hat es zu diesem Zeitpunkt sowieso schon.

### Im register-Flow

Direkt nach Schritt 11 (Credentials speichern) fragt der Assistent in
Schritt 13: **„Bot jetzt in maubot eintragen?"** Bei Ja:

1. Beim **ersten Mal** wird nach der maubot-URL gefragt.
2. **Token-Bootstrap**: entweder einen vorhandenen Token eingeben *oder*
   einmalig mit maubot-Username+Passwort einloggen — das Skript holt sich
   dann den Token und speichert **nur den Token** (Passwort wird verworfen).
3. URL + Token landen in `~/.config/matrix-register-bot/maubot.env`
   (`chmod 600`) und werden bei zukünftigen Aufrufen automatisch wiederverwendet.
4. Bot wird per `PUT /_matrix/maubot/v1/client/{mxid}` als Client eingetragen,
   mit `sync=true`, `autojoin=true`, `enabled=true`.

**Plugin-Instanzen** musst du weiterhin im maubot-Web-UI selbst anlegen
(Clients → `@bot:domain` → **+ Instance**). Der Client ist nur die
Account-Hülle; das eigentliche Bot-Verhalten kommt aus den Plugins.

### Nachträglich oder zu einer anderen maubot-Instanz

```bash
./matrix-register-bot.sh maubot-add wetterbot
```

Lädt die gespeicherte Bot-Config + die maubot-Verbindungsdaten, prüft ob der
Client schon existiert, und legt ihn an (oder fragt vorher).

### Bot aus maubot entfernen

```bash
./matrix-register-bot.sh maubot-remove wetterbot
```

> **Hinweis**: Plugin-Instanzen, die auf diesem Client laufen, müssen vorher
> in maubot gelöscht werden — sonst lehnt die API den DELETE ab.

### Non-interaktiv mit maubot

```bash
./matrix-register-bot.sh register \
  --server https://matrix.example.org \
  --admin-token "$ADMIN_TOKEN" \
  --bot wetterbot --displayname "Wetter Bot" \
  --generate-password \
  --maubot-url https://maubot.example.org \
  --maubot-token "$MAUBOT_TOKEN" \
  --non-interactive
```

Oder ohne maubot (wenn `maubot.env` existiert würde es sonst eingetragen):

```bash
./matrix-register-bot.sh register ... --no-maubot --non-interactive
```

### maubot-spezifische Flags

```
--maubot-url URL                Maubot-Mgmt-URL (https://maubot.example.org)
--maubot-token TOKEN            Management-Token (Bearer)
--maubot-homeserver-url URL     Andere HS-URL, die maubot intern benutzt
                                (z.B. http://synapse:8008 bei Compose-Setup)
--maubot-replace                Bestehenden Client ohne Frage überschreiben
--maubot-no-save                Token NICHT in maubot.env speichern (z.B. CI)
--no-maubot                     maubot-Schritt im register-Flow auslassen
```

### Container-Setup: maubot und Synapse im selben docker-compose

Wenn maubot als Container neben Synapse läuft, sollte maubot den Homeserver
**intern** über das Compose-Netz erreichen (z.B. `http://synapse:8008`),
nicht über die externe Reverse-Proxy-URL. Das spart Hairpin-NAT-Probleme,
TLS-Last und Latenz.

Das Skript läuft typischerweise vom Host und nutzt für seine eigenen
Synapse-Aufrufe weiterhin die externe URL (`https://matrix.example.org`).
Nur in maubots Client-Eintrag landet die interne URL — geregelt über
`--maubot-homeserver-url` bzw. die interaktive Frage beim Erstkonfig.

```bash
./matrix-register-bot.sh register \
  --server https://matrix.example.org \
  --maubot-url https://maubot.example.org \
  --maubot-homeserver-url http://synapse:8008 \
  ...
```

Der Override wird mit in `maubot.env` persistiert — nach dem einmaligen Setup
arbeiten alle weiteren `register` und `maubot-add`-Aufrufe automatisch mit
dem internen Hostnamen.

Beispiel `maubot.env` nach Erstkonfig:

```env
MAUBOT_URL="https://maubot.example.org"
MAUBOT_TOKEN="..."
MAUBOT_HOMESERVER_OVERRIDE="http://synapse:8008"
```

> **Wichtig:** Der Service-Name (`synapse`) muss dem `services:`-Key in deiner
> `docker-compose.yml` entsprechen und maubot muss im selben Netzwerk sein.

### Wo bekomme ich den maubot-Token her?

- **Web-UI**: einloggen, DevTools → Application → Local Storage → `accessToken`
- **mbc-CLI** (offizielle maubot-CLI): `mbc login` legt den Token unter
  `~/.config/maubot-cli.json` ab — `jq -r .servers[].token` aus der Datei lesen
- **Einfacher**: einfach den Bootstrap-Login dieses Skripts nutzen — gib beim
  ersten Mal Username/Passwort ein, das Skript holt den Token, speichert ihn,
  verwirft das Passwort.

## Ergebnis-Datei

Unter `~/.config/matrix-register-bot/<bot>.env` (Mode 600, Ordner Mode 700):

```env
HOMESERVER_URL="https://matrix.example.org"
BOT_USER_ID="@wetterbot:example.org"
BOT_LOCALPART="wetterbot"
BOT_DISPLAYNAME="Wetter Bot"
BOT_PASSWORD="…"
BOT_ACCESS_TOKEN="syt_…"
BOT_DEVICE_ID="matrix-register-bot"
```

In einem Bot-Framework (matrix-nio, mautrix-go, maubot, …) brauchst du in der
Regel nur:

- `HOMESERVER_URL`
- `BOT_USER_ID`
- `BOT_ACCESS_TOKEN`

## Flags-Übersicht

```
Gemeinsame Optionen:
  --server URL                   Homeserver-URL (https://matrix.example.org)
  --insecure                     TLS-Prüfung abschalten (nur eigener Server!)
  --admin-token TOKEN            Vorhandener Admin-Access-Token
  --admin-user LOCALPART         Admin-Benutzername (Localpart)
  --admin-pass PASS              Admin-Passwort
  --non-interactive              Keine Prompts, alle Werte aus Flags

Für 'register':
  --bot LOCALPART                Bot-Localpart (z.B. wetterbot)
  --displayname NAME             Anzeigename
  --password PASS                Passwort vorgeben
  --generate-password            Zufälliges Passwort erzeugen
  --rooms "r1,r2,..."            Räume zum Auto-Join (kommasepariert)

Für 'deactivate':
  --erase                        Profil-Daten zusätzlich löschen (irreversibel)

Für 'register', 'maubot-add', 'maubot-remove':
  --maubot-url URL               Maubot-Mgmt-URL
  --maubot-token TOKEN           Maubot-Management-Token (Bearer)
  --maubot-homeserver-url URL    Andere HS-URL für maubot intern (Container)
  --maubot-replace               Bestehenden Client ohne Frage überschreiben
  --maubot-no-save               Token NICHT in maubot.env speichern
  --no-maubot                    (nur register) Schritt auslassen
```

## Häufige Fragen

### Selbstsigniertes TLS-Zertifikat

`--insecure` als Flag oder im interaktiven Prompt mit „y" beantworten. Niemals
bei fremden Servern.

### „User existiert bereits"

Interaktiv wirst du gefragt:
1. Abbrechen
2. Passwort beibehalten, nur einen neuen Token holen
3. Passwort und Token komplett neu setzen

Non-interaktiv mit `--password` oder `--generate-password` werden Passwort und
Token überschrieben.

### Force-Join schlägt fehl

Der Admin-Force-Join (`/_synapse/admin/v1/join/<raum>`) klappt nur, wenn ein
**lokaler User** Mitglied im Zielraum ist — typisch für deinen eigenen
Homeserver. Für Räume auf anderen Servern muss der Bot eingeladen werden;
danach kann er sich mit `BOT_ACCESS_TOKEN` selbst per `/_matrix/client/v3/join`
joinen.

### Access-Token später widerrufen

```bash
source ~/.config/matrix-register-bot/<bot>.env
curl -X POST \
  -H "Authorization: Bearer $BOT_ACCESS_TOKEN" \
  "$HOMESERVER_URL/_matrix/client/v3/logout"
```

## Sicherheitshinweise

- Die `.env`-Dateien enthalten **Klartext-Passwörter und -Tokens**. Schutz:
  `chmod 600` (Datei) + `chmod 700` (Ordner). Nicht in Sync-Ordnern (Dropbox,
  iCloud Drive) aufbewahren.
- **Niemals** die `.env`-Dateien committen — die mitgelieferte `.gitignore`
  schützt davor.
- Admin-Token und -Passwörter werden vom Skript **nicht** persistiert — sie
  leben nur im Prozess-Speicher und verschwinden beim Exit.
- Bei `--admin-pass` auf der Kommandozeile: das landet in deiner Shell-History.
  Für Automation lieber `--admin-token "$VAR"` aus einer Env-Variable lesen.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
