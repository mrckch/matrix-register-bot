# matrix-register-bot

Zwei Tools rund um Bot-Accounts auf einem privaten Synapse-Homeserver (Matrix):

1. **CLI** ([`matrix-register-bot.sh`](matrix-register-bot.sh)) — interaktives
   Bash-Werkzeug fürs Anlegen einzelner Bots, auch non-interaktiv aus Skripten.
2. **UI** ([`manager/`](manager/)) — kleiner Container mit Web-UI fürs laufende
   Drumherum (Bots auflisten, Token generieren, Räume anlegen). Läuft im selben
   Docker-Stack wie Synapse, Admin-Token bleibt serverseitig.

Beide nutzen ausschließlich die Synapse Admin-API + die Matrix Client-Server API.

Ziel: Du musst dir nicht jedes Mal die Synapse-Admin-API ins Gedächtnis
rufen, wenn du einen neuen Bot brauchst, einen Token rotieren oder einen Bot
abschalten willst.

## CLI: Subcommands

| Befehl | Was er macht |
|---|---|
| `register` (Default) | Neuen Bot anlegen, Passwort + Access-Token erzeugen, in Räume joinen, DM mit Usern starten |
| `invite <bot> <raum>...` | Bestehenden Bot in (weitere) Räume joinen (Synapse Admin force-join) |
| `dm <bot> <user>...` | Direkt-Chat zwischen Bot und einem oder mehreren Usern anlegen |
| `rotate-token <bot>` | Mit dem gespeicherten Bot-Passwort einen neuen Access-Token holen |
| `deactivate <bot> [--erase]` | Bot auf dem Server abschalten (optional Daten löschen) |
| `help` | Hilfe anzeigen |

## Voraussetzungen

### Auf deinem Rechner (Debian 13)

```bash
apt update && apt install -y curl jq openssl
```

### Auf dem Synapse-Server: Ein Admin-User muss existieren

Synapse erzeugt keinen „Initial-Admin" für dich. Einmalig auf dem Synapse-Host:

```bash
register_new_matrix_user \
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

### Direkt-Chat mit einem User

Sobald der Bot existiert, kannst du ihm einen 1-zu-1-DM mit dir (oder anderen
Usern) öffnen lassen:

```bash
./matrix-register-bot.sh dm wetterbot @marc:example.org
./matrix-register-bot.sh dm wetterbot marc                  # Kurzform
./matrix-register-bot.sh dm wetterbot marc anna             # mehrere User -> mehrere DMs
```

Was passiert:

1. Bot erstellt einen Raum (`preset: trusted_private_chat`, `is_direct: true`)
2. Bot lädt den User ein
3. Bot trägt den Raum in seine `m.direct`-Account-Data ein — dadurch zeigen
   Matrix-Clients den Raum als 1-zu-1-Chat
4. Bot sendet eine Begrüßungsnachricht (per Default; mit `--dm-no-message`
   auslassbar; mit `--dm-message TEXT` selbst formulieren)

> **Wichtig**: Der User muss die Einladung in seinem Matrix-Client annehmen.
> Force-Join für DMs machen wir bewusst nicht.

Idempotenz: Wenn schon ein DM zwischen Bot und User existiert, fragt das Skript
interaktiv — in non-interactive wird der Schritt übersprungen.

Im **register-Flow** kommt die Frage „DM-Raum mit einem User starten?"
automatisch als Schritt 13. Per Flag kannst du das im register-Aufruf
direkt vorgeben:

```bash
./matrix-register-bot.sh register ... \
  --dm @marc:example.org \
  --dm-message "Hallo Marc, der neue Bot ist startklar."
```

### Bot abschalten

```bash
# Sanft: User existiert weiter, kann sich aber nicht mehr einloggen
./matrix-register-bot.sh deactivate wetterbot --admin-token "$ADMIN_TOKEN"

# Hart: zusätzlich Profil/Avatar löschen (GDPR-Style, irreversibel)
./matrix-register-bot.sh deactivate wetterbot --admin-token "$ADMIN_TOKEN" --erase
```

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

In einem Bot-Framework (matrix-nio, mautrix-go, …) brauchst du in der
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
  --dm "@u1:dom,@u2:dom"         User für DM-Räume (kommasepariert)
  --dm-message TEXT              Eigene Begrüßungsnachricht
  --dm-no-message                Keine Begrüßungsnachricht senden

Für 'deactivate':
  --erase                        Profil-Daten zusätzlich löschen (irreversibel)
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
