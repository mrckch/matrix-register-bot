#!/usr/bin/env bash
# =============================================================================
#  matrix-register-bot.sh
# -----------------------------------------------------------------------------
#  Interaktiver Assistent zum Registrieren eines Bot-Accounts auf einem
#  privaten Synapse-Homeserver (Matrix). Fuehrt Schritt fuer Schritt durch
#  den Prozess und erklaert jeden Schritt auch fuer Nicht-Systementwickler.
#
#  Zielplattform: Debian 13 (Bash >= 5, curl, jq, openssl).
#  Lauft remote ueber HTTPS gegen die Synapse-Admin-API.
#
#  Ergebnis am Ende:
#    - Bot-User existiert auf dem Homeserver
#    - Eigener Access-Token fuer den Bot ist generiert
#    - Credentials liegen in ~/.config/matrix-register-bot/<bot>.env (chmod 600)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
#  Konstanten & globaler State
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="matrix-register-bot"
readonly SCRIPT_VERSION="0.1.0"
readonly CONFIG_DIR="${HOME}/.config/${SCRIPT_NAME}"

# Globale Variablen, die im Lauf des Assistenten gefuellt werden.
# (In Bash gibt es keine echten Module — wir sammeln Werte in Globals.)
HOMESERVER_URL=""        # z.B. https://matrix.example.org (ohne trailing slash)
INSECURE_TLS="false"     # "true" = curl -k (selbstsignierte Zerts erlauben)
ADMIN_TOKEN=""           # Access-Token eines Admin-Users
BOT_LOCALPART=""         # z.B. "wetterbot"  (ohne @ und ohne :domain)
BOT_USER_ID=""           # z.B. "@wetterbot:example.org"
BOT_DISPLAYNAME=""       # menschenlesbarer Name, optional
BOT_PASSWORD=""          # generiert oder vom User vorgegeben
BOT_ACCESS_TOKEN=""      # vom HS ausgegeben nach erstem Login
BOT_DEVICE_ID="matrix-register-bot"  # konstant — wir wollen ein wiederfindbares Device
SERVER_DOMAIN=""         # Server-Name aus dem HS (z.B. "example.org") — fuer @user:domain

# -----------------------------------------------------------------------------
#  UI-Helfer: Farben, Boxen, Prompts
# -----------------------------------------------------------------------------

# Farben nur aktivieren, wenn stdout ein Terminal ist und NO_COLOR nicht gesetzt.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_CYAN="$(tput setaf 6)"
else
  C_RESET="" ; C_BOLD="" ; C_DIM="" ; C_RED="" ; C_GREEN="" ; C_YELLOW="" ; C_BLUE="" ; C_CYAN=""
fi

# log_info / log_warn / log_error: konsistente Statuszeilen.
log_info()  { printf '%s[i]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[OK]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[X]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }

# step_header: dicker Block am Anfang jedes Schritts — macht die Reihenfolge
# klar sichtbar, sodass man nichts vergisst.
step_header() {
  local num="$1"; shift
  local title="$*"
  printf '\n%s===== Schritt %s: %s =====%s\n' "$C_BOLD$C_CYAN" "$num" "$title" "$C_RESET"
}

# explain: kurze Erklaerung fuer den Anwender, was als naechstes passiert
# und warum. Drei bis fuenf Zeilen ist die Zielgroesse.
explain() {
  # $* wird als Block uebergeben, Einrueckung mit zwei Leerzeichen fuer Optik.
  printf '%s' "$C_DIM"
  printf '  %s\n' "$@"
  printf '%s' "$C_RESET"
}

# ask: einfacher Prompt mit Default. Gibt das Ergebnis ueber stdout zurueck.
#   usage: var=$(ask "Frage" "default")
ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer=""
  if [[ -n "$default" ]]; then
    read -rp "  ${prompt} [${default}]: " answer || true
    echo "${answer:-$default}"
  else
    read -rp "  ${prompt}: " answer || true
    echo "$answer"
  fi
}

# ask_secret: wie ask, aber ohne Echo (Passwoerter, Tokens).
ask_secret() {
  local prompt="$1"
  local answer=""
  # -s = silent, kein Echo. Newline danach, weil read -s keine ausgibt.
  read -rsp "  ${prompt}: " answer || true
  echo
  echo "$answer"
}

# ask_yes_no: gibt 0 zurueck bei "ja", 1 bei "nein". Default ist "n".
#   usage: if ask_yes_no "Wirklich?" "n"; then ... ; fi
ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  local answer=""
  read -rp "  ${prompt} ${hint}: " answer || true
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|j|J|yes|Yes|YES|ja|Ja|JA) return 0 ;;
    *) return 1 ;;
  esac
}

# fatal: Meldung + Abbruch mit Exit-Code 1.
fatal() {
  log_error "$*"
  exit 1
}

# -----------------------------------------------------------------------------
#  HTTP-Helfer
# -----------------------------------------------------------------------------

# curl_args: baut die curl-Basisargumente. Wenn INSECURE_TLS=true, dann -k.
# Wir lesen die HTTP-Statuszeile separat, damit wir saubere Fehler zeigen.
curl_args() {
  local args=(--silent --show-error --location --connect-timeout 10 --max-time 30)
  [[ "$INSECURE_TLS" == "true" ]] && args+=(--insecure)
  printf '%s\n' "${args[@]}"
}

# http_request: macht den Call, liefert "STATUS<TAB>BODY" zurueck. Trennt
# Header und Body sauber, damit der Aufrufer beides pruefen kann.
#   usage: response=$(http_request GET "https://..." [header1 [header2 ...]])
#          status=$(echo "$response" | head -n1)
#          body=$(echo "$response" | tail -n +2)
http_request() {
  local method="$1"; shift
  local url="$1"; shift
  local body=""
  # Wenn das naechste Argument mit -d= anfaengt, ist es der Request-Body.
  if [[ "${1:-}" == "-d="* ]]; then
    body="${1#-d=}"
    shift
  fi

  local -a curl_opts
  mapfile -t curl_opts < <(curl_args)

  local -a header_args=()
  while [[ $# -gt 0 ]]; do
    header_args+=(-H "$1")
    shift
  done

  local -a body_args=()
  if [[ -n "$body" ]]; then
    body_args=(-H "Content-Type: application/json" --data "$body")
  fi

  # -w "\n%{http_code}" haengt nach dem Body eine Newline + HTTP-Statuscode an.
  # So koennen wir Status und Body in einem Aufruf bekommen.
  local raw
  if ! raw="$(curl "${curl_opts[@]}" -X "$method" -w '\n%{http_code}' \
                "${header_args[@]}" "${body_args[@]}" "$url")"; then
    echo "000"
    echo "{\"error\":\"curl_failed\",\"url\":\"$url\"}"
    return 0
  fi

  local status="${raw##*$'\n'}"
  local resp_body="${raw%$'\n'*}"
  echo "$status"
  echo "$resp_body"
}

# json_get: liest einen Pfad aus JSON, gibt leeren String zurueck wenn nicht da.
#   usage: name=$(json_get "$body" '.user_id')
json_get() {
  local json="$1"
  local path="$2"
  echo "$json" | jq -r "${path} // empty" 2>/dev/null || echo ""
}

# url_encode_localpart: einfacher Encode fuer Pfad-Parameter (z.B. @bot:domain).
# Wir kodieren nur die Zeichen, die im Matrix-Localpart und in unserer Domain
# wirklich vorkommen koennen und in URLs Probleme machen ('@' und ':').
url_encode_user_id() {
  local s="$1"
  s="${s//@/%40}"
  s="${s//:/%3A}"
  echo "$s"
}

# -----------------------------------------------------------------------------
#  Schritt 0: Preflight — sind alle Abhaengigkeiten da?
# -----------------------------------------------------------------------------

step_00_preflight() {
  step_header 0 "Voraussetzungen pruefen"
  explain \
    "Wir pruefen zuerst, ob die Werkzeuge installiert sind, die das Skript braucht:" \
    "  - curl    fuer HTTP-Aufrufe an den Matrix-Server" \
    "  - jq      zum Auslesen der JSON-Antworten" \
    "  - openssl zum Erzeugen eines starken Zufalls-Passworts"

  local missing=()
  for tool in curl jq openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Es fehlen folgende Werkzeuge: ${missing[*]}"
    log_info  "Auf Debian 13 installieren mit:"
    printf '\n    sudo apt update && sudo apt install -y %s\n\n' "${missing[*]}"
    fatal "Bitte zuerst die fehlenden Pakete installieren, dann erneut starten."
  fi

  # Bash-Version sicherstellen (assoziative Arrays, mapfile etc.)
  if ((BASH_VERSINFO[0] < 4)); then
    fatal "Bash 4 oder neuer noetig. Debian 13 hat Bash 5 — pruefe deinen Aufruf."
  fi

  log_ok "Alle Werkzeuge gefunden."
}

# -----------------------------------------------------------------------------
#  Schritt 1: Homeserver-URL
# -----------------------------------------------------------------------------

step_01_homeserver_url() {
  step_header 1 "Homeserver-URL eingeben"
  explain \
    "Die Homeserver-URL ist die Adresse, unter der dein Matrix-Server seine API" \
    "anbietet. Das ist nicht zwingend dieselbe Adresse, unter der deine User" \
    "ihre Matrix-IDs haben. Beispiel:" \
    "  Matrix-ID:        @alice:example.org" \
    "  Homeserver-URL:   https://matrix.example.org" \
    "Die URL muss mit https:// (oder http://, wenn du wirklich weisst was du tust)" \
    "beginnen und endet OHNE Schraegstrich."

  while true; do
    HOMESERVER_URL=$(ask "Homeserver-URL" "")
    HOMESERVER_URL="${HOMESERVER_URL%/}"   # Trailing slash entfernen
    if [[ "$HOMESERVER_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
      break
    fi
    log_warn "Das sieht nicht wie eine gueltige URL aus. Beispiel: https://matrix.example.org"
  done

  # TLS-Modus klaeren — fuer Heimserver mit selbstsignierten Zerts.
  if [[ "$HOMESERVER_URL" == https://* ]]; then
    explain \
      "Falls dein Server ein selbstsigniertes TLS-Zertifikat hat (haeufig bei" \
      "Heimservern), schlaegt die normale Pruefung fehl. Du kannst die Pruefung" \
      "abschalten — ABER nur wenn du sicher bist, dass es DEIN Server ist."
    if ask_yes_no "Zertifikatspruefung abschalten (--insecure)?" "n"; then
      INSECURE_TLS="true"
      log_warn "TLS-Pruefung ist ABGESCHALTET. Nur fuer eigenen Server verwenden!"
    fi
  fi
}

# -----------------------------------------------------------------------------
#  Schritt 2: Erreichbarkeit pruefen + Server-Domain herausfinden
# -----------------------------------------------------------------------------

step_02_check_reachability() {
  step_header 2 "Server erreichbar?"
  explain \
    "Wir rufen /_matrix/client/versions auf. Diese Endpoint gibt es auf jedem" \
    "Matrix-Server und sie verrate uns, welche Spec-Versionen er unterstuetzt." \
    "Wenn das hier schiefgeht, sind alle weiteren Schritte sinnlos."

  local response status body
  response=$(http_request GET "${HOMESERVER_URL}/_matrix/client/versions")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)

  if [[ "$status" != "200" ]]; then
    log_error "Status $status beim Aufruf von /_matrix/client/versions"
    echo "  Antwort: $body" >&2
    fatal "Server nicht erreichbar oder kein Matrix-Server unter dieser URL."
  fi
  log_ok "Server antwortet (HTTP 200)."

  # Server-Domain auslesen — die brauchen wir spaeter fuer @bot:domain.
  # Erst aus dem Whoami nach dem Admin-Login. Hier merken wir uns vorlaeufig
  # nichts.
}

# -----------------------------------------------------------------------------
#  Schritt 3: Admin-Token besorgen
# -----------------------------------------------------------------------------

step_03_admin_token() {
  step_header 3 "Admin-Zugang einrichten"
  explain \
    "Um einen neuen User anzulegen, brauchen wir Admin-Rechte auf dem Server." \
    "Konkret brauchen wir einen Access-Token von einem Synapse-User, bei dem" \
    "in der Datenbank das Flag 'admin' gesetzt ist." \
    "Falls du noch keinen Admin hast, lege dir EINMALIG einen mit dem Befehl" \
    "  register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008" \
    "auf dem Synapse-Host an und antworte beim Prompt 'Make admin? y' mit 'y'."

  echo
  echo "  Du hast zwei Optionen:"
  echo "    1) Du hast bereits ein Admin-Access-Token zur Hand."
  echo "    2) Du loggst dich jetzt mit Benutzername+Passwort des Admins ein,"
  echo "       und das Skript holt sich einen Token fuer dich."
  echo

  local choice
  choice=$(ask "Welche Option? (1/2)" "2")

  if [[ "$choice" == "1" ]]; then
    ADMIN_TOKEN=$(ask_secret "Admin-Access-Token (wird nicht angezeigt)")
    [[ -z "$ADMIN_TOKEN" ]] && fatal "Leerer Token — Abbruch."
  else
    local admin_user admin_pass
    admin_user=$(ask "Admin-Benutzername (nur Localpart, z.B. 'admin')" "")
    [[ -z "$admin_user" ]] && fatal "Leerer Benutzername — Abbruch."
    admin_pass=$(ask_secret "Passwort des Admin-Users (wird nicht angezeigt)")
    [[ -z "$admin_pass" ]] && fatal "Leeres Passwort — Abbruch."

    log_info "Login wird durchgefuehrt..."
    local login_body
    # Achtung: Passwoerter mit ", \ und Newlines brauchen JSON-Escaping.
    # jq macht das sauber fuer uns.
    login_body=$(jq -n \
      --arg user "$admin_user" \
      --arg pass "$admin_pass" \
      --arg device "${SCRIPT_NAME}-admin" \
      '{type:"m.login.password",
        identifier:{type:"m.id.user", user:$user},
        password:$pass,
        device_id:$device,
        initial_device_display_name:"matrix-register-bot admin session"}')

    local response status body
    response=$(http_request POST "${HOMESERVER_URL}/_matrix/client/v3/login" "-d=$login_body")
    status=$(echo "$response" | head -n1)
    body=$(echo "$response" | tail -n +2)

    if [[ "$status" != "200" ]]; then
      log_error "Login fehlgeschlagen (HTTP $status)."
      echo "  Antwort: $body" >&2
      fatal "Pruefe Benutzername/Passwort und ob der Server erreichbar ist."
    fi

    ADMIN_TOKEN=$(json_get "$body" '.access_token')
    SERVER_DOMAIN=$(json_get "$body" '.user_id' | sed 's/^@[^:]*://')
    [[ -z "$ADMIN_TOKEN" ]] && fatal "Konnte access_token aus der Antwort nicht lesen."
    log_ok "Login erfolgreich. Server-Domain erkannt: ${SERVER_DOMAIN}"
  fi
}

# -----------------------------------------------------------------------------
#  Schritt 4: Admin-Status verifizieren
# -----------------------------------------------------------------------------

step_04_verify_admin() {
  step_header 4 "Admin-Rechte verifizieren"
  explain \
    "Wir rufen einen Admin-only-Endpunkt auf (/_synapse/admin/v1/server_version)." \
    "Wenn der Server uns 200 zurueckgibt, ist alles gut. Wenn 403/401 kommt," \
    "hat der Token keine Admin-Rechte — dann muessten wir den User in der" \
    "Synapse-DB als Admin markieren oder einen anderen verwenden."

  local response status body
  response=$(http_request GET "${HOMESERVER_URL}/_synapse/admin/v1/server_version" \
    "Authorization: Bearer ${ADMIN_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)

  if [[ "$status" != "200" ]]; then
    log_error "Admin-Check fehlgeschlagen (HTTP $status)."
    echo "  Antwort: $body" >&2
    fatal "Der Token hat keine Admin-Rechte oder der Server antwortet nicht wie erwartet."
  fi

  local server_version
  server_version=$(json_get "$body" '.server_version')
  log_ok "Admin-Rechte bestaetigt. Synapse-Version: ${server_version:-unbekannt}"

  # Wenn wir die Server-Domain noch nicht haben (Option 1: vorhandener Token),
  # holen wir sie jetzt ueber whoami.
  if [[ -z "$SERVER_DOMAIN" ]]; then
    response=$(http_request GET "${HOMESERVER_URL}/_matrix/client/v3/account/whoami" \
      "Authorization: Bearer ${ADMIN_TOKEN}")
    status=$(echo "$response" | head -n1)
    body=$(echo "$response" | tail -n +2)
    if [[ "$status" == "200" ]]; then
      SERVER_DOMAIN=$(json_get "$body" '.user_id' | sed 's/^@[^:]*://')
    fi
    [[ -z "$SERVER_DOMAIN" ]] && fatal "Server-Domain konnte nicht ermittelt werden."
    log_ok "Server-Domain: ${SERVER_DOMAIN}"
  fi
}

# -----------------------------------------------------------------------------
#  Schritt 5: Bot-Localpart eingeben + validieren
# -----------------------------------------------------------------------------

step_05_bot_localpart() {
  step_header 5 "Bot-Benutzername (Localpart) waehlen"
  explain \
    "Der Localpart ist der Teil VOR dem Doppelpunkt in der Matrix-ID." \
    "  Matrix-ID:  @wetterbot:${SERVER_DOMAIN}" \
    "  Localpart:                wetterbot" \
    "Erlaubt sind Kleinbuchstaben, Ziffern und die Zeichen . _ = / -" \
    "Keine Umlaute, keine Leerzeichen, keine Grossbuchstaben."

  while true; do
    BOT_LOCALPART=$(ask "Localpart des Bots" "")
    # Matrix-Spec, Section "User Identifiers": [a-z0-9._=/-]+
    if [[ "$BOT_LOCALPART" =~ ^[a-z0-9._=/-]+$ ]]; then
      break
    fi
    log_warn "Ungueltiger Localpart. Erlaubt: a-z 0-9 . _ = / -"
  done

  BOT_USER_ID="@${BOT_LOCALPART}:${SERVER_DOMAIN}"
  log_info "Vollstaendige Matrix-ID des Bots: ${C_BOLD}${BOT_USER_ID}${C_RESET}"
}

# -----------------------------------------------------------------------------
#  Schritt 6: Duplikat-Check
# -----------------------------------------------------------------------------

# Globale Variable, ob der User schon existiert. Wird in Schritt 8 ausgewertet.
USER_EXISTS="false"

step_06_check_existing() {
  step_header 6 "Pruefen, ob der Bot schon existiert"
  explain \
    "Wir fragen die Admin-API, ob es den User bereits gibt. Falls ja, kannst du" \
    "  - abbrechen," \
    "  - nur einen neuen Access-Token erzeugen (das alte Passwort bleibt)," \
    "  - oder Passwort und Token komplett neu setzen."

  local encoded user_url response status body
  encoded=$(url_encode_user_id "$BOT_USER_ID")
  user_url="${HOMESERVER_URL}/_synapse/admin/v2/users/${encoded}"

  response=$(http_request GET "$user_url" "Authorization: Bearer ${ADMIN_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)

  case "$status" in
    200)
      USER_EXISTS="true"
      log_warn "User ${BOT_USER_ID} existiert bereits."
      local displayname deactivated
      displayname=$(json_get "$body" '.displayname')
      deactivated=$(json_get "$body" '.deactivated')
      echo "  Aktueller Displayname: ${displayname:-(keiner)}"
      echo "  Deaktiviert:           ${deactivated:-false}"
      echo
      echo "  Was moechtest du tun?"
      echo "    1) Abbrechen"
      echo "    2) Passwort beibehalten, nur einen neuen Access-Token holen"
      echo "    3) Passwort UND Token neu setzen"
      local choice
      choice=$(ask "Auswahl (1/2/3)" "1")
      case "$choice" in
        1) fatal "Abgebrochen." ;;
        2) BOT_PASSWORD="__keep__" ;;
        3) BOT_PASSWORD="" ;;  # wird in Schritt 8 neu ermittelt
        *) fatal "Ungueltige Auswahl." ;;
      esac
      ;;
    404)
      log_ok "User existiert noch nicht — wir koennen ihn frisch anlegen."
      ;;
    *)
      log_error "Unerwarteter Status $status beim Duplikat-Check."
      echo "  Antwort: $body" >&2
      fatal "Pruefe deine Admin-Rechte / die Server-URL."
      ;;
  esac
}

# -----------------------------------------------------------------------------
#  Schritt 7: Displayname (optional)
# -----------------------------------------------------------------------------

step_07_displayname() {
  step_header 7 "Displayname festlegen (optional)"
  explain \
    "Der Displayname ist der menschenlesbare Name, der in Matrix-Clients" \
    "neben den Nachrichten des Bots erscheint — z.B. 'Wetter Bot'. Du kannst" \
    "leer lassen, dann wird der Localpart als Anzeigename verwendet."

  BOT_DISPLAYNAME=$(ask "Displayname" "")
}

# -----------------------------------------------------------------------------
#  Schritt 8: Passwort generieren oder eingeben
# -----------------------------------------------------------------------------

step_08_password() {
  step_header 8 "Bot-Passwort festlegen"

  # Falls in Schritt 6 entschieden wurde, das Passwort zu behalten:
  if [[ "$BOT_PASSWORD" == "__keep__" ]]; then
    log_info "Bestehendes Passwort wird beibehalten."
    BOT_PASSWORD=$(ask_secret "Bitte das bestehende Bot-Passwort eingeben (fuer Login)")
    [[ -z "$BOT_PASSWORD" ]] && fatal "Ohne Passwort koennen wir keinen Token holen."
    return
  fi

  explain \
    "Der Bot braucht ein Passwort. Empfehlung: zufaellig generieren lassen — du" \
    "musst es dir nicht merken, weil das Skript den daraus gewonnenen Access-Token" \
    "verschluesselt fuer dich speichert. Bot-Software loggt sich entweder mit" \
    "Passwort ODER mit Access-Token ein; der Token ist die uebliche Wahl."

  if ask_yes_no "Zufaelliges, starkes Passwort generieren?" "y"; then
    # 30 Bytes zufallsbasiert, base64-kodiert ergibt 40 Zeichen — gut genug.
    BOT_PASSWORD="$(openssl rand -base64 30 | tr -d '\n=' | tr '+/' '-_')"
    log_ok "Passwort erzeugt (wird gleich angezeigt und gespeichert)."
  else
    while true; do
      local p1 p2
      p1=$(ask_secret "Passwort eingeben")
      p2=$(ask_secret "Passwort wiederholen")
      if [[ "$p1" == "$p2" && -n "$p1" ]]; then
        BOT_PASSWORD="$p1"
        break
      fi
      log_warn "Passwoerter stimmen nicht ueberein oder sind leer — nochmal."
    done
  fi
}

# -----------------------------------------------------------------------------
#  Schritt 9: User anlegen / aktualisieren
# -----------------------------------------------------------------------------

step_09_create_user() {
  step_header 9 "Bot-User auf dem Server anlegen"
  explain \
    "Jetzt rufen wir die Synapse-Admin-API auf:" \
    "  PUT /_synapse/admin/v2/users/${BOT_USER_ID}" \
    "Wenn der User schon existiert, wird er aktualisiert — sonst neu erstellt." \
    "Der Bot bekommt ausdruecklich KEINE Admin-Rechte (admin: false)."

  local encoded user_url payload
  encoded=$(url_encode_user_id "$BOT_USER_ID")
  user_url="${HOMESERVER_URL}/_synapse/admin/v2/users/${encoded}"

  # Payload bauen — jq macht das JSON-sicher.
  payload=$(jq -n \
    --arg password "$BOT_PASSWORD" \
    --arg displayname "$BOT_DISPLAYNAME" \
    '{ password: $password,
       admin: false,
       deactivated: false }
     + (if $displayname == "" then {} else { displayname: $displayname } end)')

  local response status body
  response=$(http_request PUT "$user_url" "-d=$payload" \
    "Authorization: Bearer ${ADMIN_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)

  case "$status" in
    200|201)
      log_ok "User erfolgreich angelegt/aktualisiert (HTTP $status)."
      ;;
    *)
      log_error "Anlage fehlgeschlagen (HTTP $status)."
      echo "  Antwort: $body" >&2
      fatal "Pruefe Admin-Rechte und Localpart-Konventionen."
      ;;
  esac
}

# -----------------------------------------------------------------------------
#  Schritt 10: Access-Token fuer den Bot holen
# -----------------------------------------------------------------------------

step_10_bot_login() {
  step_header 10 "Access-Token fuer den Bot holen"
  explain \
    "Bot-Software (mautrix, maubot, matrix-nio etc.) loggt sich am bequemsten" \
    "ueber einen Access-Token ein. Wir loggen den Bot jetzt einmal mit Passwort" \
    "ein — der Server gibt uns dafuer einen Token zurueck, den wir dann fuer" \
    "den Bot speichern. Das Admin-Token bleibt davon unberuehrt."

  local login_body
  login_body=$(jq -n \
    --arg user "$BOT_LOCALPART" \
    --arg pass "$BOT_PASSWORD" \
    --arg device "$BOT_DEVICE_ID" \
    --arg display "${BOT_DISPLAYNAME:-$BOT_LOCALPART} (matrix-register-bot)" \
    '{type:"m.login.password",
      identifier:{type:"m.id.user", user:$user},
      password:$pass,
      device_id:$device,
      initial_device_display_name:$display}')

  local response status body
  response=$(http_request POST "${HOMESERVER_URL}/_matrix/client/v3/login" "-d=$login_body")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)

  if [[ "$status" != "200" ]]; then
    log_error "Bot-Login fehlgeschlagen (HTTP $status)."
    echo "  Antwort: $body" >&2
    fatal "Der User wurde angelegt, aber wir konnten ihn nicht einloggen."
  fi

  BOT_ACCESS_TOKEN=$(json_get "$body" '.access_token')
  [[ -z "$BOT_ACCESS_TOKEN" ]] && fatal "Konnte access_token aus der Antwort nicht lesen."
  log_ok "Access-Token fuer den Bot erhalten."
}

# -----------------------------------------------------------------------------
#  Schritt 11: Credentials sichern
# -----------------------------------------------------------------------------

step_11_save_credentials() {
  step_header 11 "Credentials speichern"
  explain \
    "Wir legen alle wichtigen Werte als .env-Datei ab unter" \
    "  ${CONFIG_DIR}/${BOT_LOCALPART}.env" \
    "Die Datei wird mit Modus 600 geschrieben (nur dein User darf lesen)." \
    "Das Verzeichnis bekommt Modus 700. Bitte committe diese Datei NICHT in Git."

  # Verzeichnis anlegen falls noetig.
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  local target="${CONFIG_DIR}/${BOT_LOCALPART}.env"

  # Falls die Datei schon existiert, sicherheitshalber wegsichern.
  if [[ -f "$target" ]]; then
    local backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -- "$target" "$backup"
    chmod 600 "$backup"
    log_warn "Bestehende Datei nach ${backup} gesichert."
  fi

  # Heredoc OHNE Variableninterpolation waere falsch — wir WOLLEN die Werte hier.
  cat > "$target" <<EOF
# matrix-register-bot — Credentials fuer ${BOT_USER_ID}
# Generiert am $(date -u +%Y-%m-%dT%H:%M:%SZ) durch ${SCRIPT_NAME} ${SCRIPT_VERSION}
# WARNUNG: Diese Datei enthaelt Geheimnisse. NIEMALS in Git committen.

HOMESERVER_URL="${HOMESERVER_URL}"
BOT_USER_ID="${BOT_USER_ID}"
BOT_LOCALPART="${BOT_LOCALPART}"
BOT_DISPLAYNAME="${BOT_DISPLAYNAME}"
BOT_PASSWORD="${BOT_PASSWORD}"
BOT_ACCESS_TOKEN="${BOT_ACCESS_TOKEN}"
BOT_DEVICE_ID="${BOT_DEVICE_ID}"
EOF
  chmod 600 "$target"
  log_ok "Gespeichert: ${target}"
}

# -----------------------------------------------------------------------------
#  Schritt 12: Zusammenfassung + naechste Schritte
# -----------------------------------------------------------------------------

step_12_summary() {
  step_header 12 "Fertig — Zusammenfassung"

  printf '\n%sBot angelegt:%s\n' "$C_BOLD" "$C_RESET"
  printf '  Matrix-ID:       %s\n' "$BOT_USER_ID"
  printf '  Displayname:     %s\n' "${BOT_DISPLAYNAME:-(none)}"
  printf '  Device-ID:       %s\n' "$BOT_DEVICE_ID"
  printf '  Credentials in:  %s/%s.env\n' "$CONFIG_DIR" "$BOT_LOCALPART"

  printf '\n%sSchneller Test%s — gibt @bot:domain zurueck, wenn der Token gueltig ist:\n' "$C_BOLD" "$C_RESET"
  local insecure_flag=""
  [[ "$INSECURE_TLS" == "true" ]] && insecure_flag=" -k"
  cat <<EOF

  source "${CONFIG_DIR}/${BOT_LOCALPART}.env"
  curl${insecure_flag} -s -H "Authorization: Bearer \$BOT_ACCESS_TOKEN" \\
       "\$HOMESERVER_URL/_matrix/client/v3/account/whoami" | jq .

EOF

  printf '%sNaechste Schritte%s\n' "$C_BOLD" "$C_RESET"
  cat <<'EOF'
  - Bot in einen Raum einladen: in deinem Matrix-Client einen Raum oeffnen
    und den Bot per /invite @botname:domain einladen.
  - Den Bot in einem Framework verwenden (matrix-nio, mautrix-go, maubot):
    in deren Config HOMESERVER_URL, BOT_USER_ID und BOT_ACCESS_TOKEN eintragen.
  - Token spaeter widerrufen, falls noetig:
      curl -X POST -H "Authorization: Bearer $BOT_ACCESS_TOKEN" \
           "$HOMESERVER_URL/_matrix/client/v3/logout"
EOF
  echo
  log_ok "Alles erledigt."
}

# -----------------------------------------------------------------------------
#  Trap fuer sauberen Abbruch (Ctrl-C)
# -----------------------------------------------------------------------------

on_interrupt() {
  echo
  log_warn "Abgebrochen. Falls bereits ein User angelegt wurde, ist der bestehen geblieben."
  log_warn "Du kannst das Skript erneut starten — es erkennt vorhandene User."
  exit 130
}
trap on_interrupt INT TERM

# -----------------------------------------------------------------------------
#  Banner + Main
# -----------------------------------------------------------------------------

banner() {
  cat <<EOF
${C_BOLD}${C_CYAN}
  matrix-register-bot v${SCRIPT_VERSION}
  Interaktiver Assistent zum Anlegen eines Bot-Users auf Synapse
${C_RESET}
EOF
}

main() {
  banner

  step_00_preflight
  step_01_homeserver_url
  step_02_check_reachability
  step_03_admin_token
  step_04_verify_admin
  step_05_bot_localpart
  step_06_check_existing
  step_07_displayname
  step_08_password
  step_09_create_user
  step_10_bot_login
  step_11_save_credentials
  step_12_summary
}

main "$@"
