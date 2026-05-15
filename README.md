# matrix-register-bot

Interaktiver Bash-Assistent zum Anlegen von **Bot-Accounts auf einem privaten
Synapse-Homeserver** (Matrix). Er fragt Schritt für Schritt alles ab, erklärt
jeden Schritt in einfachem Deutsch und legt am Ende einen Bot-User samt
eigenem Access-Token an.

Ziel: Du musst dir nicht jedes Mal die Synapse-Admin-API ins Gedächtnis
rufen, wenn du einen neuen Bot brauchst.

## Was das Tool macht

1. Prüft, dass `curl`, `jq` und `openssl` installiert sind
2. Fragt nach Homeserver-URL und prüft, ob der Server erreichbar ist
3. Holt sich ein Admin-Access-Token (entweder eingeben oder per Login erzeugen)
4. Verifiziert die Admin-Rechte gegen die Admin-API
5. Fragt nach dem Bot-Localpart (validiert nach Matrix-Spec)
6. Prüft, ob der User schon existiert – mit Option „nur Token erneuern"
7. Optionaler Displayname
8. Passwort: zufällig generieren (empfohlen) oder selbst eingeben
9. Legt den User per `PUT /_synapse/admin/v2/users/{mxid}` an
10. Loggt den Bot einmal ein → eigener Access-Token
11. Speichert alles in `~/.config/matrix-register-bot/<bot>.env` (`chmod 600`)
12. Zeigt Zusammenfassung + Quick-Test + nächste Schritte

## Voraussetzungen

### Auf deinem Rechner (Debian 13)

```bash
sudo apt update && sudo apt install -y curl jq openssl
```

### Auf dem Synapse-Server

Du brauchst **einen Admin-User**. Synapse erzeugt keinen „Initial-Admin" für
dich – das musst du einmalig selbst tun. Auf dem Synapse-Host:

```bash
sudo register_new_matrix_user \
  -c /etc/matrix-synapse/homeserver.yaml \
  http://localhost:8008
```

Beim Prompt **„Make admin? (yes/no)"** mit `yes` antworten.

> Alternative: einen bestehenden User per SQL als Admin markieren:
> `UPDATE users SET admin = 1 WHERE name = '@alice:example.org';`

## Verwendung

```bash
chmod +x matrix-register-bot.sh
./matrix-register-bot.sh
```

Dann einfach den Prompts folgen. Bei jedem Schritt steht im grauen Block, was
gerade passiert und warum.

### Beispielsitzung

```
===== Schritt 1: Homeserver-URL eingeben =====
  Die Homeserver-URL ist die Adresse, unter der dein Matrix-Server seine API
  anbietet. ...
  Homeserver-URL: https://matrix.example.org

===== Schritt 3: Admin-Zugang einrichten =====
  Welche Option? (1/2) [2]: 2
  Admin-Benutzername (nur Localpart, z.B. 'admin'): alice
  Passwort des Admin-Users (wird nicht angezeigt):
[OK] Login erfolgreich. Server-Domain erkannt: example.org

===== Schritt 5: Bot-Benutzername (Localpart) waehlen =====
  Localpart des Bots: wetterbot
[i] Vollstaendige Matrix-ID des Bots: @wetterbot:example.org
...
===== Schritt 12: Fertig — Zusammenfassung =====
Bot angelegt:
  Matrix-ID:       @wetterbot:example.org
  Credentials in:  /home/marc/.config/matrix-register-bot/wetterbot.env
```

## Ergebnis-Datei

Unter `~/.config/matrix-register-bot/<bot>.env` (Mode 600):

```env
HOMESERVER_URL="https://matrix.example.org"
BOT_USER_ID="@wetterbot:example.org"
BOT_LOCALPART="wetterbot"
BOT_DISPLAYNAME="Wetter Bot"
BOT_PASSWORD="…"
BOT_ACCESS_TOKEN="syt_…"
BOT_DEVICE_ID="matrix-register-bot"
```

In einem Bot-Framework brauchst du normalerweise nur:

- `HOMESERVER_URL`
- `BOT_USER_ID`
- `BOT_ACCESS_TOKEN`

## Häufige Fragen

### Selbstsigniertes TLS-Zertifikat

In Schritt 1 fragt das Skript nach, ob die Zertifikatsprüfung abgeschaltet
werden soll. Antworte mit `y`, wenn dein Server ein selbstsigniertes Zert hat.
**Niemals** bei fremden Servern abschalten.

### „User existiert bereits"

In Schritt 6 kannst du wählen:

1. Abbrechen
2. Passwort beibehalten, nur einen neuen Token holen
3. Passwort und Token komplett neu setzen

### Access-Token später widerrufen

```bash
source ~/.config/matrix-register-bot/<bot>.env
curl -X POST \
  -H "Authorization: Bearer $BOT_ACCESS_TOKEN" \
  "$HOMESERVER_URL/_matrix/client/v3/logout"
```

### Bot wieder löschen

```bash
# Mit Admin-Token (Beispiel — Token entsprechend setzen):
curl -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"erase": false}' \
  "$HOMESERVER_URL/_synapse/admin/v1/deactivate/@wetterbot:example.org"
```

## Sicherheitshinweise

- Die `.env`-Dateien enthalten **Klartext-Passwörter und -Tokens**. Sie sind
  per `chmod 600` geschützt, aber bewahre sie nicht in Sync-Ordnern (Dropbox,
  iCloud Drive) auf.
- **Niemals** die `.env`-Dateien committen. Die mitgelieferte `.gitignore`
  schützt davor, aber pass auch bei manuellen Kopien auf.
- Wenn du den Admin-Token im Skript eingibst, wird er **nicht** persistiert.
  Wenn du dich per Admin-Login authentifizierst, wird auch der Admin-Token
  nur im Speicher gehalten und beim Skript-Ende verworfen.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
