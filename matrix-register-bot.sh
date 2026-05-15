#!/usr/bin/env bash
# =============================================================================
#  matrix-register-bot.sh
# -----------------------------------------------------------------------------
#  Multi-Command-Werkzeug zum Verwalten von Bot-Accounts auf einem privaten
#  Synapse-Homeserver (Matrix). Fuehrt durch alle Schritte, die man sonst
#  vergisst:
#
#    register      Bot anlegen, Token erzeugen, Credentials speichern,
#                  optional in Raeume joinen, optional in maubot eintragen
#    invite        Bestehenden Bot in (weitere) Raeume joinen (Admin force-join)
#    rotate-token  Mit gespeichertem Passwort neuen Access-Token holen
#    deactivate    Bot auf dem Server deaktivieren
#    maubot-add    Bot als Client in eine maubot-Instanz eintragen
#    maubot-remove Bot aus einer maubot-Instanz entfernen
#    help          Hilfe anzeigen
#
#  Zielplattform: Debian 13 (Bash >= 5, curl, jq, openssl).
#  Laeuft remote ueber HTTPS gegen die Synapse-Admin-API.
#
#  Credentials werden in ~/.config/matrix-register-bot/<bot>.env (chmod 600)
#  abgelegt. NIEMALS in Git committen — siehe mitgelieferte .gitignore.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
#  Konstanten
# =============================================================================

readonly SCRIPT_NAME="matrix-register-bot"
readonly SCRIPT_VERSION="0.3.0"
readonly CONFIG_DIR="${HOME}/.config/${SCRIPT_NAME}"
readonly MAUBOT_CONFIG_FILE="${CONFIG_DIR}/maubot.env"

# =============================================================================
#  Globaler State (wird durch Flags + Prompts gefuellt)
# =============================================================================

HOMESERVER_URL=""        # z.B. https://matrix.example.org (ohne trailing /)
INSECURE_TLS="false"     # "true" = curl -k (selbstsignierte Zerts erlauben)
ADMIN_TOKEN=""           # Access-Token eines Admin-Users
ADMIN_USER=""            # Localpart eines Admin-Users (wenn per Login)
ADMIN_PASS=""            # Passwort des Admin-Users (wenn per Login)
BOT_LOCALPART=""         # z.B. "wetterbot" (ohne @ und ohne :domain)
BOT_USER_ID=""           # z.B. "@wetterbot:example.org"
BOT_DISPLAYNAME=""       # menschenlesbarer Name, optional
BOT_PASSWORD=""          # generiert oder vom User vorgegeben
BOT_ACCESS_TOKEN=""      # vom HS ausgegeben nach Bot-Login
BOT_DEVICE_ID="matrix-register-bot"
SERVER_DOMAIN=""         # Server-Name aus dem HS (z.B. "example.org")

# Verhaltens-Flags
NON_INTERACTIVE="false"  # true = keine Prompts erlaubt, alle Werte aus Flags
GENERATE_PASSWORD=""     # "true"|"false"|"" — "" = nachfragen
USER_EXISTS="false"      # wird in step_06 gesetzt
ROOMS=()                 # Raeume zum Auto-Join (Room-IDs ! oder Aliases #)
ERASE_DATA="false"       # deactivate: GDPR-style erase?

# maubot-State
MAUBOT_URL=""            # z.B. https://maubot.example.org (ohne trailing /)
MAUBOT_TOKEN=""          # Bearer-Token fuer die maubot Management-API
MAUBOT_REPLACE="false"   # true = bestehenden Client ohne Frage ueberschreiben
SKIP_MAUBOT="false"      # true = maubot-Schritt im register-Flow auslassen
MAUBOT_NO_SAVE="false"   # true = neuen Token nicht in maubot.env schreiben

# =============================================================================
#  UI-Helfer: Farben, Logs, Prompts
# =============================================================================

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

log_info()  { printf '%s[i]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[X]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }

step_header() {
  local num="$1"; shift
  local title="$*"
  printf '\n%s===== Schritt %s: %s =====%s\n' "$C_BOLD$C_CYAN" "$num" "$title" "$C_RESET"
}

section_header() {
  printf '\n%s>>> %s <<<%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"
}

# explain(): mehrere Argumente = mehrere Zeilen, eingerueckt + gedimmt.
# Wird im NON_INTERACTIVE-Modus unterdrueckt (kein Mensch liest mit).
explain() {
  [[ "$NON_INTERACTIVE" == "true" ]] && return 0
  printf '%s' "$C_DIM"
  printf '  %s\n' "$@"
  printf '%s' "$C_RESET"
}

# ask "Frage" "default" — Prompt mit Default. Im non-interactive Modus
# wird der Default returnt (oder fatal, wenn kein Default).
ask() {
  local prompt="$1"
  local default="${2:-}"
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -n "$default" ]]; then
      echo "$default"
      return 0
    fi
    fatal "Im --non-interactive-Modus fehlt eine Eingabe: $prompt"
  fi
  local answer=""
  if [[ -n "$default" ]]; then
    read -rp "  ${prompt} [${default}]: " answer || true
    echo "${answer:-$default}"
  else
    read -rp "  ${prompt}: " answer || true
    echo "$answer"
  fi
}

# ask_secret: ohne Echo. In non-interactive fatal — Secrets muessen ueber Flags
# oder stdin reinkommen.
ask_secret() {
  local prompt="$1"
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    fatal "Im --non-interactive-Modus fehlt ein Secret: $prompt"
  fi
  local answer=""
  read -rsp "  ${prompt}: " answer || true
  echo
  echo "$answer"
}

# ask_yes_no: gibt 0 (ja) / 1 (nein). Default "n" wenn nicht angegeben.
# In non-interactive wird IMMER der Default genommen.
ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    [[ "$default" == "y" ]] && return 0 || return 1
  fi
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

fatal() {
  log_error "$*"
  exit 1
}

# =============================================================================
#  HTTP-Helfer
# =============================================================================

curl_args() {
  local args=(--silent --show-error --location --connect-timeout 10 --max-time 30)
  [[ "$INSECURE_TLS" == "true" ]] && args+=(--insecure)
  printf '%s\n' "${args[@]}"
}

# http_request METHOD URL [-d=BODY] [HEADER ...]
# Gibt 2 Zeilen aus: Status-Code, dann Body.
http_request() {
  local method="$1"; shift
  local url="$1"; shift
  local body=""
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

json_get() {
  local json="$1"
  local path="$2"
  echo "$json" | jq -r "${path} // empty" 2>/dev/null || echo ""
}

# url_encode_one: Encoded ein Path-Segment (User-ID oder Raum). Wir kodieren
# die Zeichen, die in Matrix-IDs vorkommen und in URL-Pfaden Probleme machen.
url_encode_one() {
  local s="$1"
  s="${s//@/%40}"
  s="${s//:/%3A}"
  s="${s//\!/%21}"
  s="${s//\#/%23}"
  echo "$s"
}

# =============================================================================
#  Config-Datei IO
# =============================================================================

config_path_for() {
  echo "${CONFIG_DIR}/${1}.env"
}

# write_config: schreibt aktuellen State als .env. chmod 600.
# Wenn die Datei existiert, wird sie vorher mit Zeitstempel weggesichert.
write_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  local target
  target=$(config_path_for "$BOT_LOCALPART")

  if [[ -f "$target" ]]; then
    local backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -- "$target" "$backup"
    chmod 600 "$backup"
    log_warn "Bestehende Datei nach ${backup} gesichert."
  fi

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

# read_config <localpart>: liest eine vorhandene .env in die Globals.
# Wir parsen selbst statt 'source' zu verwenden — das ist sicherer (kein
# Code-Eval) und akzeptiert die simple KEY="VALUE"-Form, die wir schreiben.
read_config() {
  local localpart="$1"
  local path
  path=$(config_path_for "$localpart")
  [[ -f "$path" ]] || fatal "Keine Config gefunden: $path"

  local line key value
  while IFS= read -r line; do
    # Kommentare und Leerzeilen ueberspringen
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Form: KEY="VALUE"
    if [[ "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      case "$key" in
        HOMESERVER_URL)    HOMESERVER_URL="$value" ;;
        BOT_USER_ID)       BOT_USER_ID="$value" ;;
        BOT_LOCALPART)     BOT_LOCALPART="$value" ;;
        BOT_DISPLAYNAME)   BOT_DISPLAYNAME="$value" ;;
        BOT_PASSWORD)      BOT_PASSWORD="$value" ;;
        BOT_ACCESS_TOKEN)  BOT_ACCESS_TOKEN="$value" ;;
        BOT_DEVICE_ID)     BOT_DEVICE_ID="$value" ;;
      esac
    fi
  done < "$path"

  # Server-Domain aus User-ID ableiten
  SERVER_DOMAIN="${BOT_USER_ID#*:}"
  log_ok "Config geladen: $path"
}

# =============================================================================
#  Gemeinsame Bausteine (von mehreren Subcommands genutzt)
# =============================================================================

require_tools() {
  local missing=()
  for tool in curl jq openssl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Es fehlen folgende Werkzeuge: ${missing[*]}"
    printf '\n    sudo apt update && sudo apt install -y %s\n\n' "${missing[*]}"
    fatal "Bitte zuerst die fehlenden Pakete installieren."
  fi
  ((BASH_VERSINFO[0] >= 4)) || fatal "Bash 4 oder neuer noetig."
}

prompt_homeserver_url() {
  if [[ -n "$HOMESERVER_URL" ]]; then
    HOMESERVER_URL="${HOMESERVER_URL%/}"
    log_info "Homeserver-URL: ${HOMESERVER_URL}"
    return 0
  fi
  while true; do
    HOMESERVER_URL=$(ask "Homeserver-URL (z.B. https://matrix.example.org)" "")
    HOMESERVER_URL="${HOMESERVER_URL%/}"
    if [[ "$HOMESERVER_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
      return 0
    fi
    log_warn "Das sieht nicht wie eine gueltige URL aus."
  done
}

check_server_reachable() {
  log_info "Pruefe Erreichbarkeit von $HOMESERVER_URL ..."
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
}

# obtain_admin_token: holt einen Admin-Token. Wenn ADMIN_TOKEN bereits gesetzt,
# benutzt es das. Sonst entweder ADMIN_USER+ADMIN_PASS oder interaktiv.
obtain_admin_token() {
  if [[ -n "$ADMIN_TOKEN" ]]; then
    log_info "Admin-Token aus Flag/Env uebernommen."
  elif [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]]; then
    admin_login "$ADMIN_USER" "$ADMIN_PASS"
  else
    explain \
      "Wir brauchen Admin-Rechte. Du kannst entweder einen vorhandenen Admin-" \
      "Access-Token eingeben (Option 1) oder dich mit Admin-Benutzer+Passwort" \
      "anmelden, sodass wir einen Token fuer dich holen (Option 2)."
    local choice
    choice=$(ask "Auswahl (1/2)" "2")
    if [[ "$choice" == "1" ]]; then
      ADMIN_TOKEN=$(ask_secret "Admin-Access-Token (wird nicht angezeigt)")
      [[ -z "$ADMIN_TOKEN" ]] && fatal "Leerer Token."
    else
      ADMIN_USER=$(ask "Admin-Benutzername (Localpart)" "")
      [[ -z "$ADMIN_USER" ]] && fatal "Leerer Benutzername."
      ADMIN_PASS=$(ask_secret "Passwort des Admin-Users")
      [[ -z "$ADMIN_PASS" ]] && fatal "Leeres Passwort."
      admin_login "$ADMIN_USER" "$ADMIN_PASS"
    fi
  fi
}

admin_login() {
  local user="$1"
  local pass="$2"
  log_info "Admin-Login wird durchgefuehrt..."
  local login_body response status body
  login_body=$(jq -n \
    --arg user "$user" \
    --arg pass "$pass" \
    --arg device "${SCRIPT_NAME}-admin" \
    '{type:"m.login.password",
      identifier:{type:"m.id.user", user:$user},
      password:$pass,
      device_id:$device,
      initial_device_display_name:"matrix-register-bot admin session"}')
  response=$(http_request POST "${HOMESERVER_URL}/_matrix/client/v3/login" "-d=$login_body")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  if [[ "$status" != "200" ]]; then
    log_error "Admin-Login fehlgeschlagen (HTTP $status)."
    echo "  Antwort: $body" >&2
    fatal "Pruefe Benutzername/Passwort."
  fi
  ADMIN_TOKEN=$(json_get "$body" '.access_token')
  SERVER_DOMAIN=$(json_get "$body" '.user_id' | sed 's/^@[^:]*://')
  [[ -z "$ADMIN_TOKEN" ]] && fatal "Konnte access_token aus der Antwort nicht lesen."
  log_ok "Login erfolgreich. Server-Domain: ${SERVER_DOMAIN}"
}

verify_admin() {
  log_info "Verifiziere Admin-Rechte..."
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

  if [[ -z "$SERVER_DOMAIN" ]]; then
    response=$(http_request GET "${HOMESERVER_URL}/_matrix/client/v3/account/whoami" \
      "Authorization: Bearer ${ADMIN_TOKEN}")
    status=$(echo "$response" | head -n1)
    body=$(echo "$response" | tail -n +2)
    [[ "$status" == "200" ]] && SERVER_DOMAIN=$(json_get "$body" '.user_id' | sed 's/^@[^:]*://')
    [[ -z "$SERVER_DOMAIN" ]] && fatal "Server-Domain konnte nicht ermittelt werden."
    log_ok "Server-Domain: ${SERVER_DOMAIN}"
  fi
}

# bot_login: loggt den Bot ein und setzt BOT_ACCESS_TOKEN.
bot_login() {
  log_info "Logge Bot ein, um Access-Token zu holen..."
  local login_body response status body
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
  response=$(http_request POST "${HOMESERVER_URL}/_matrix/client/v3/login" "-d=$login_body")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  if [[ "$status" != "200" ]]; then
    log_error "Bot-Login fehlgeschlagen (HTTP $status)."
    echo "  Antwort: $body" >&2
    fatal "Der User existiert, aber Login schlaegt fehl — falsches Passwort?"
  fi
  BOT_ACCESS_TOKEN=$(json_get "$body" '.access_token')
  [[ -z "$BOT_ACCESS_TOKEN" ]] && fatal "Konnte access_token aus der Antwort nicht lesen."
  log_ok "Access-Token erhalten."
}

# admin_force_join_one ROOM: Force-Join des Bots in einen Raum via Admin-API.
# Funktioniert fuer Raeume, in denen ein lokaler User Mitglied ist (Standardfall
# auf dem eigenen Homeserver). Federation/externe Raeume gehen damit i.d.R.
# nicht — dort muss der Bot manuell eingeladen werden.
admin_force_join_one() {
  local room="$1"
  local encoded url payload response status body
  encoded=$(url_encode_one "$room")
  url="${HOMESERVER_URL}/_synapse/admin/v1/join/${encoded}"
  payload=$(jq -n --arg uid "$BOT_USER_ID" '{user_id: $uid}')

  response=$(http_request POST "$url" "-d=$payload" \
    "Authorization: Bearer ${ADMIN_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)

  if [[ "$status" == "200" ]]; then
    local room_id
    room_id=$(json_get "$body" '.room_id')
    log_ok "Bot ist Raum beigetreten: ${room} -> ${room_id:-(?)}"
    return 0
  fi

  log_warn "Force-Join in '${room}' fehlgeschlagen (HTTP $status)."
  local err errcode
  errcode=$(json_get "$body" '.errcode')
  err=$(json_get "$body" '.error')
  [[ -n "$errcode" ]] && echo "    errcode: $errcode" >&2
  [[ -n "$err" ]]     && echo "    error:   $err" >&2
  return 1
}

# =============================================================================
#  maubot-Integration
# =============================================================================
#
#  maubot ist ein Plugin-basiertes Matrix-Bot-Framework. Eine maubot-Instanz
#  verwaltet mehrere "Clients" (= Matrix-Accounts) und kann auf jedem davon
#  Plugin-Instanzen laufen lassen.
#
#  Management-API:
#    POST   /_matrix/maubot/v1/auth/login   { username, password } -> { token }
#    POST   /_matrix/maubot/v1/auth/ping    (Token validieren)
#    GET    /_matrix/maubot/v1/client/{mxid}
#    PUT    /_matrix/maubot/v1/client/{mxid}   (anlegen oder ersetzen)
#    DELETE /_matrix/maubot/v1/client/{mxid}
#  Auth: Authorization: Bearer <token>
# =============================================================================

# read_maubot_config: laedt MAUBOT_URL + MAUBOT_TOKEN aus maubot.env, falls
# vorhanden und noch nicht gesetzt. Sicheres Parsing (kein source).
read_maubot_config() {
  [[ -f "$MAUBOT_CONFIG_FILE" ]] || return 0
  local line key value
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      case "$key" in
        MAUBOT_URL)   [[ -z "$MAUBOT_URL"   ]] && MAUBOT_URL="$value" ;;
        MAUBOT_TOKEN) [[ -z "$MAUBOT_TOKEN" ]] && MAUBOT_TOKEN="$value" ;;
      esac
    fi
  done < "$MAUBOT_CONFIG_FILE"
}

# write_maubot_config: speichert MAUBOT_URL + MAUBOT_TOKEN. Wird nur aufgerufen,
# wenn der User explizit speichern moechte (oder beim Bootstrap-Login).
write_maubot_config() {
  [[ "$MAUBOT_NO_SAVE" == "true" ]] && { log_info "maubot-Config NICHT gespeichert (--maubot-no-save)."; return 0; }
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  if [[ -f "$MAUBOT_CONFIG_FILE" ]]; then
    local backup="${MAUBOT_CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -- "$MAUBOT_CONFIG_FILE" "$backup"
    chmod 600 "$backup"
  fi
  cat > "$MAUBOT_CONFIG_FILE" <<EOF
# maubot-Verbindungsdaten fuer ${SCRIPT_NAME}
# Generiert am $(date -u +%Y-%m-%dT%H:%M:%SZ)
# WARNUNG: Enthaelt einen Management-Token. NIEMALS in Git committen.

MAUBOT_URL="${MAUBOT_URL}"
MAUBOT_TOKEN="${MAUBOT_TOKEN}"
EOF
  chmod 600 "$MAUBOT_CONFIG_FILE"
  log_ok "maubot-Config gespeichert: ${MAUBOT_CONFIG_FILE}"
}

# maubot_api METHOD PATH [-d=BODY]: Wrapper um http_request, der die
# Base-URL + Auth-Header vorsetzt. Liefert "STATUS\nBODY" wie http_request.
maubot_api() {
  local method="$1"; shift
  local path="$1"; shift
  local url="${MAUBOT_URL%/}/_matrix/maubot/v1${path}"
  if [[ "${1:-}" == "-d="* ]]; then
    local body="$1"
    http_request "$method" "$url" "$body" \
      "Authorization: Bearer ${MAUBOT_TOKEN}"
  else
    http_request "$method" "$url" \
      "Authorization: Bearer ${MAUBOT_TOKEN}"
  fi
}

# maubot_login: holt einen Token per Username+Passwort. Setzt MAUBOT_TOKEN.
maubot_login() {
  local user="$1"
  local pass="$2"
  local body response status resp_body
  body=$(jq -n --arg u "$user" --arg p "$pass" '{username:$u, password:$p}')
  response=$(http_request POST "${MAUBOT_URL%/}/_matrix/maubot/v1/auth/login" "-d=$body")
  status=$(echo "$response" | head -n1)
  resp_body=$(echo "$response" | tail -n +2)
  if [[ "$status" != "200" ]]; then
    log_error "maubot-Login fehlgeschlagen (HTTP $status)."
    echo "  Antwort: $resp_body" >&2
    fatal "Pruefe Username/Passwort und ob das wirklich der maubot-Endpoint ist."
  fi
  MAUBOT_TOKEN=$(json_get "$resp_body" '.token')
  [[ -z "$MAUBOT_TOKEN" ]] && fatal "Konnte token aus der Antwort nicht lesen."
  log_ok "maubot-Login erfolgreich."
}

# maubot_ping: validiert den aktuellen Token. Gibt 0 zurueck wenn OK, 1 sonst.
maubot_ping() {
  local response status
  response=$(maubot_api POST "/auth/ping")
  status=$(echo "$response" | head -n1)
  [[ "$status" == "200" ]]
}

# maubot_get_client <mxid>: pruefte ob ein Client existiert.
# Echo: "200" wenn existiert, "404" wenn nicht, sonst Statuscode.
maubot_get_client() {
  local mxid="$1"
  local encoded response status
  encoded=$(url_encode_one "$mxid")
  response=$(maubot_api GET "/client/${encoded}")
  status=$(echo "$response" | head -n1)
  echo "$status"
}

# maubot_put_client: legt den Bot als Client in maubot an oder ersetzt ihn.
# Nutzt die globalen Bot-Werte (BOT_USER_ID, HOMESERVER_URL, BOT_ACCESS_TOKEN,
# BOT_DEVICE_ID, BOT_DISPLAYNAME).
maubot_put_client() {
  local encoded url payload response status body
  encoded=$(url_encode_one "$BOT_USER_ID")

  # JSON-Body: alle Felder, die maubot fuer einen funktionalen Client braucht.
  # sync/autojoin/enabled/online sind die typischen Bot-Defaults.
  payload=$(jq -n \
    --arg hs "$HOMESERVER_URL" \
    --arg tok "$BOT_ACCESS_TOKEN" \
    --arg dev "$BOT_DEVICE_ID" \
    --arg dn "$BOT_DISPLAYNAME" \
    '{ homeserver: $hs,
       access_token: $tok,
       device_id: $dev,
       sync: true,
       autojoin: true,
       enabled: true,
       online: true }
     + (if $dn == "" then {} else { displayname: $dn } end)')

  response=$(maubot_api PUT "/client/${encoded}" "-d=$payload")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  case "$status" in
    200|201)
      log_ok "Client in maubot angelegt/aktualisiert (HTTP $status)."
      return 0 ;;
    *)
      log_error "maubot-PUT fehlgeschlagen (HTTP $status)."
      echo "  Antwort: $body" >&2
      return 1 ;;
  esac
}

# maubot_delete_client <mxid>: entfernt den Client aus maubot.
maubot_delete_client() {
  local mxid="$1"
  local encoded response status body
  encoded=$(url_encode_one "$mxid")
  response=$(maubot_api DELETE "/client/${encoded}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  case "$status" in
    200|204)
      log_ok "Client aus maubot entfernt (HTTP $status)."
      return 0 ;;
    404)
      log_warn "Client war in maubot nicht eingetragen (HTTP 404)."
      return 0 ;;
    *)
      log_error "maubot-DELETE fehlgeschlagen (HTTP $status)."
      echo "  Antwort: $body" >&2
      return 1 ;;
  esac
}

# ensure_maubot_url: stellt sicher, dass MAUBOT_URL gesetzt ist. Liest
# erstmal die Config; wenn dort auch nichts steht, fragt interaktiv. In
# non-interactive ohne Wert -> fatal.
ensure_maubot_url() {
  if [[ -z "$MAUBOT_URL" ]]; then
    read_maubot_config
  fi
  if [[ -z "$MAUBOT_URL" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      fatal "maubot-URL fehlt. --maubot-url angeben oder Config in $MAUBOT_CONFIG_FILE pflegen."
    fi
    while true; do
      MAUBOT_URL=$(ask "maubot-URL (z.B. https://maubot.example.org)" "")
      MAUBOT_URL="${MAUBOT_URL%/}"
      [[ "$MAUBOT_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] && break
      log_warn "Das sieht nicht wie eine gueltige URL aus."
    done
  fi
}

# ensure_maubot_token: stellt sicher, dass MAUBOT_TOKEN gueltig ist. Reihenfolge:
#   1. Wenn schon gesetzt -> ping zur Verifikation, ggf. invalidieren
#   2. Aus maubot.env laden -> ping
#   3. Interaktiv: vorhandenen Token eingeben ODER einmaliger Bootstrap-Login
#      mit Username+Passwort (Passwort wird NICHT gespeichert, nur der Token).
ensure_maubot_token() {
  ensure_maubot_url

  if [[ -n "$MAUBOT_TOKEN" ]]; then
    if maubot_ping; then
      log_ok "maubot-Token akzeptiert."
      return 0
    fi
    log_warn "maubot-Token aus Flag/Config ist ungueltig oder abgelaufen."
    MAUBOT_TOKEN=""
  fi

  read_maubot_config
  if [[ -n "$MAUBOT_TOKEN" ]]; then
    if maubot_ping; then
      log_ok "maubot-Token aus Config akzeptiert."
      return 0
    fi
    log_warn "Gespeicherter Token in $MAUBOT_CONFIG_FILE funktioniert nicht."
    MAUBOT_TOKEN=""
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    fatal "Kein gueltiger maubot-Token. --maubot-token angeben oder vorher interaktiv ausfuehren."
  fi

  explain \
    "Wir brauchen einen maubot-Management-Token. Du hast zwei Optionen:" \
    "  1) Du hast bereits einen Token zur Hand (z.B. aus dem Web-UI oder mbc-CLI)." \
    "  2) Du loggst dich JETZT einmalig mit deinem maubot-Username+Passwort ein —" \
    "     das Skript holt den Token fuer dich und speichert NUR den Token."
  local choice
  choice=$(ask "Auswahl (1/2)" "2")
  if [[ "$choice" == "1" ]]; then
    MAUBOT_TOKEN=$(ask_secret "maubot-Token (wird nicht angezeigt)")
    [[ -z "$MAUBOT_TOKEN" ]] && fatal "Leerer Token."
    maubot_ping || fatal "Token wird vom Server abgelehnt — falscher Token oder falsche URL?"
    log_ok "Token verifiziert."
  else
    local user pass
    user=$(ask "maubot-Username" "")
    [[ -z "$user" ]] && fatal "Leerer Username."
    pass=$(ask_secret "maubot-Passwort")
    [[ -z "$pass" ]] && fatal "Leeres Passwort."
    maubot_login "$user" "$pass"
  fi

  # Token speichern (sofern nicht --maubot-no-save).
  if [[ "$MAUBOT_NO_SAVE" != "true" ]]; then
    if ask_yes_no "maubot-URL und -Token persistent speichern (chmod 600)?" "y"; then
      write_maubot_config
    fi
  fi
}

# register_in_maubot: trifft die Idempotenz-Entscheidung (GET -> 200/404),
# fragt ggf. nach, und ruft dann maubot_put_client auf.
register_in_maubot() {
  ensure_maubot_token

  local existing_status
  existing_status=$(maubot_get_client "$BOT_USER_ID")
  case "$existing_status" in
    200)
      log_warn "Client ${BOT_USER_ID} existiert in maubot bereits."
      if [[ "$MAUBOT_REPLACE" == "true" ]]; then
        log_info "Wird ueberschrieben (--maubot-replace)."
      elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        fatal "In non-interactive Modus: --maubot-replace setzen, um zu ueberschreiben."
      else
        if ! ask_yes_no "Bestehenden maubot-Client ueberschreiben?" "n"; then
          log_info "maubot-Eintragung uebersprungen."
          return 0
        fi
      fi
      ;;
    404)
      log_info "Client in maubot noch nicht vorhanden — wird neu angelegt."
      ;;
    *)
      log_error "Unerwarteter Status beim maubot-GET: $existing_status"
      fatal "Pruefe maubot-URL und Token."
      ;;
  esac

  maubot_put_client || fatal "Konnte Client nicht in maubot eintragen."

  printf '\n  %sNaechster Schritt in maubot:%s im Web-UI eine Plugin-Instanz auf\n' "$C_BOLD" "$C_RESET"
  printf '  diesem Client anlegen (Clients -> %s -> + Instance).\n' "$BOT_USER_ID"
}

# =============================================================================
#  Subcommand: register
# =============================================================================

# Schritte 0–13 fuer den vollen Register-Flow.

step_00_preflight() {
  step_header 0 "Voraussetzungen pruefen"
  explain \
    "Wir pruefen, ob curl, jq und openssl installiert sind. Wenn nicht, gibt es" \
    "eine Anleitung zum Nachinstallieren."
  require_tools
  log_ok "Alle Werkzeuge gefunden."
}

step_01_homeserver_url() {
  step_header 1 "Homeserver-URL eingeben"
  explain \
    "Die Homeserver-URL ist die Adresse, unter der dein Matrix-Server seine API" \
    "anbietet. Das ist nicht zwingend dieselbe Adresse, unter der deine User" \
    "ihre Matrix-IDs haben. Beispiel:" \
    "  Matrix-ID:        @alice:example.org" \
    "  Homeserver-URL:   https://matrix.example.org"
  prompt_homeserver_url

  if [[ "$HOMESERVER_URL" == https://* && "$INSECURE_TLS" != "true" ]]; then
    explain \
      "Falls dein Server ein selbstsigniertes TLS-Zertifikat hat (haeufig bei" \
      "Heimservern), schlaegt die normale Pruefung fehl. Du kannst sie abschalten —" \
      "ABER nur fuer DEINEN Server."
    if ask_yes_no "Zertifikatspruefung abschalten (--insecure)?" "n"; then
      INSECURE_TLS="true"
      log_warn "TLS-Pruefung ist ABGESCHALTET. Nur fuer eigenen Server verwenden!"
    fi
  fi
}

step_02_check_reachability() {
  step_header 2 "Server erreichbar?"
  explain \
    "Wir rufen /_matrix/client/versions auf — diese Endpoint gibt es auf jedem" \
    "Matrix-Server. Wenn das hier schiefgeht, sind alle weiteren Schritte sinnlos."
  check_server_reachable
}

step_03_admin_token() {
  step_header 3 "Admin-Zugang einrichten"
  explain \
    "Um einen neuen User anzulegen, brauchen wir Admin-Rechte. Konkret einen" \
    "Access-Token von einem User, der in Synapse das Admin-Flag hat. Falls du" \
    "noch keinen Admin hast, lege einmalig einen an mit:" \
    "  register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008" \
    "und antworte beim Prompt 'Make admin? y' mit 'y'."
  obtain_admin_token
}

step_04_verify_admin() {
  step_header 4 "Admin-Rechte verifizieren"
  explain \
    "Wir rufen einen Admin-only-Endpunkt auf. 200 = alles gut, 403/401 = der" \
    "Token hat keine Admin-Rechte."
  verify_admin
}

step_05_bot_localpart() {
  step_header 5 "Bot-Benutzername (Localpart) waehlen"
  explain \
    "Der Localpart ist der Teil VOR dem Doppelpunkt in der Matrix-ID." \
    "  Matrix-ID:  @wetterbot:${SERVER_DOMAIN}" \
    "  Localpart:                wetterbot" \
    "Erlaubt: Kleinbuchstaben, Ziffern, . _ = / -"

  if [[ -n "$BOT_LOCALPART" ]]; then
    if [[ ! "$BOT_LOCALPART" =~ ^[a-z0-9._=/-]+$ ]]; then
      fatal "Ungueltiger Localpart aus Flag: '$BOT_LOCALPART'"
    fi
    log_info "Localpart: $BOT_LOCALPART"
  else
    while true; do
      BOT_LOCALPART=$(ask "Localpart des Bots" "")
      if [[ "$BOT_LOCALPART" =~ ^[a-z0-9._=/-]+$ ]]; then
        break
      fi
      log_warn "Ungueltiger Localpart. Erlaubt: a-z 0-9 . _ = / -"
    done
  fi
  BOT_USER_ID="@${BOT_LOCALPART}:${SERVER_DOMAIN}"
  log_info "Vollstaendige Matrix-ID: ${C_BOLD}${BOT_USER_ID}${C_RESET}"
}

step_06_check_existing() {
  step_header 6 "Pruefen, ob der Bot schon existiert"
  explain \
    "Wir fragen die Admin-API. Falls der User existiert, kannst du wahlweise" \
    "abbrechen, nur einen neuen Token holen oder Passwort komplett neu setzen."

  local encoded user_url response status body
  encoded=$(url_encode_one "$BOT_USER_ID")
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

      # Im non-interactive Modus: Token rotieren (Passwort behalten),
      # wenn ein Passwort bekannt ist, sonst fatal.
      if [[ "$NON_INTERACTIVE" == "true" ]]; then
        if [[ -n "$BOT_PASSWORD" ]]; then
          log_info "(non-interactive) Passwort wird neu gesetzt."
        else
          fatal "User existiert. In non-interactive --password angeben (oder rotate-token nutzen)."
        fi
        return 0
      fi

      echo
      echo "  1) Abbrechen"
      echo "  2) Passwort beibehalten, nur einen neuen Access-Token holen"
      echo "  3) Passwort UND Token neu setzen"
      local choice
      choice=$(ask "Auswahl (1/2/3)" "1")
      case "$choice" in
        1) fatal "Abgebrochen." ;;
        2) BOT_PASSWORD="__keep__" ;;
        3) BOT_PASSWORD="" ;;
        *) fatal "Ungueltige Auswahl." ;;
      esac
      ;;
    404)
      log_ok "User existiert noch nicht — wir koennen ihn frisch anlegen."
      ;;
    *)
      log_error "Unerwarteter Status $status beim Duplikat-Check."
      echo "  Antwort: $body" >&2
      fatal "Pruefe Admin-Rechte / Server-URL."
      ;;
  esac
}

step_07_displayname() {
  step_header 7 "Displayname festlegen (optional)"
  explain \
    "Der Displayname ist der menschenlesbare Name, der in Matrix-Clients" \
    "neben den Nachrichten des Bots erscheint. Kann auch leer bleiben."

  if [[ -n "$BOT_DISPLAYNAME" ]]; then
    log_info "Displayname: $BOT_DISPLAYNAME"
  else
    BOT_DISPLAYNAME=$(ask "Displayname" "")
  fi
}

step_08_password() {
  step_header 8 "Bot-Passwort festlegen"

  if [[ "$BOT_PASSWORD" == "__keep__" ]]; then
    log_info "Bestehendes Passwort wird beibehalten."
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      fatal "In non-interactive kein bestehendes Passwort verfuegbar."
    fi
    BOT_PASSWORD=$(ask_secret "Bitte das bestehende Bot-Passwort eingeben (fuer Login)")
    [[ -z "$BOT_PASSWORD" ]] && fatal "Ohne Passwort kein Token."
    return
  fi

  if [[ -n "$BOT_PASSWORD" ]]; then
    log_info "Passwort aus Flag uebernommen."
    return
  fi

  if [[ "$GENERATE_PASSWORD" == "true" ]] \
       || { [[ "$NON_INTERACTIVE" == "true" ]] && [[ -z "$GENERATE_PASSWORD" ]]; }; then
    BOT_PASSWORD="$(openssl rand -base64 30 | tr -d '\n=' | tr '+/' '-_')"
    log_ok "Passwort generiert."
    return
  fi

  if [[ "$GENERATE_PASSWORD" == "false" ]]; then
    BOT_PASSWORD=$(ask_secret "Passwort fuer den Bot")
    [[ -z "$BOT_PASSWORD" ]] && fatal "Leeres Passwort."
    return
  fi

  explain \
    "Empfehlung: zufaellig generieren. Du musst dir das Passwort nicht merken," \
    "weil das Skript danach einen Access-Token holt und beides fuer dich speichert."
  if ask_yes_no "Zufaelliges, starkes Passwort generieren?" "y"; then
    BOT_PASSWORD="$(openssl rand -base64 30 | tr -d '\n=' | tr '+/' '-_')"
    log_ok "Passwort generiert."
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

step_09_create_user() {
  step_header 9 "Bot-User auf dem Server anlegen"
  explain \
    "PUT /_synapse/admin/v2/users/${BOT_USER_ID}" \
    "Wenn der User schon existiert, wird er aktualisiert. Der Bot bekommt" \
    "KEINE Admin-Rechte (admin: false)."

  local encoded user_url payload response status body
  encoded=$(url_encode_one "$BOT_USER_ID")
  user_url="${HOMESERVER_URL}/_synapse/admin/v2/users/${encoded}"

  payload=$(jq -n \
    --arg password "$BOT_PASSWORD" \
    --arg displayname "$BOT_DISPLAYNAME" \
    '{ password: $password,
       admin: false,
       deactivated: false }
     + (if $displayname == "" then {} else { displayname: $displayname } end)')

  response=$(http_request PUT "$user_url" "-d=$payload" \
    "Authorization: Bearer ${ADMIN_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  case "$status" in
    200|201) log_ok "User erfolgreich angelegt/aktualisiert (HTTP $status)." ;;
    *) log_error "Anlage fehlgeschlagen (HTTP $status)."
       echo "  Antwort: $body" >&2
       fatal "Pruefe Admin-Rechte und Localpart-Konventionen." ;;
  esac
}

step_10_bot_login() {
  step_header 10 "Access-Token fuer den Bot holen"
  explain \
    "Wir loggen den Bot einmal mit Passwort ein, um einen Access-Token zu" \
    "bekommen. Bot-Frameworks nutzen typischerweise diesen Token, nicht das Passwort."
  bot_login
}

step_11_save_credentials() {
  step_header 11 "Credentials speichern"
  explain \
    "Alle Werte gehen in ${CONFIG_DIR}/${BOT_LOCALPART}.env mit chmod 600." \
    "Niemals committen — die .gitignore deckt *.env ab."
  write_config
}

step_12_rooms() {
  step_header 12 "Raeume beitreten (optional)"
  explain \
    "Wir koennen den Bot direkt in einen oder mehrere Raeume joinen — via" \
    "Synapse Admin-Force-Join. Funktioniert fuer Raeume auf DEINEM Homeserver." \
    "Federation-Raeume gehen damit nicht; dort muss der Bot manuell eingeladen werden." \
    "Eingabe: Room-IDs (!abc:domain) oder Aliases (#raum:domain), kommasepariert."

  # Wenn Raeume per Flag mitgegeben wurden, ueberspringen wir die Frage.
  if [[ ${#ROOMS[@]} -eq 0 && "$NON_INTERACTIVE" == "false" ]]; then
    local input
    input=$(ask "Raeume (leer = ueberspringen)" "")
    if [[ -n "$input" ]]; then
      IFS=',' read -r -a ROOMS <<<"$input"
    fi
  fi

  if [[ ${#ROOMS[@]} -eq 0 ]]; then
    log_info "Keine Raeume angegeben — uebersprungen."
    return 0
  fi

  local r trimmed failed=0
  for r in "${ROOMS[@]}"; do
    # Whitespace trimmen
    trimmed="$(echo "$r" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$trimmed" ]] && continue
    if ! admin_force_join_one "$trimmed"; then
      failed=$((failed + 1))
    fi
  done
  if (( failed > 0 )); then
    log_warn "${failed} von ${#ROOMS[@]} Raeumen fehlgeschlagen — siehe oben."
  fi
}

step_13_maubot() {
  step_header 13 "In maubot eintragen (optional)"
  explain \
    "maubot ist ein Plugin-Bot-Framework. Wenn du maubot betreibst, koennen wir" \
    "den neuen Bot direkt als 'Client' dort eintragen — alle noetigen Werte" \
    "(Homeserver, Access-Token, Device-ID, Displayname) haben wir gerade." \
    "Plugin-Instanzen musst du anschliessend im maubot-Web-UI selbst anlegen."

  if [[ "$SKIP_MAUBOT" == "true" ]]; then
    log_info "maubot-Schritt uebersprungen (--no-maubot)."
    return 0
  fi

  # Default-Antwort: wenn schon eine maubot-Config existiert ODER der User
  # eine maubot-URL/Token mit Flags gegeben hat, ist die Wahrscheinlichkeit
  # hoch, dass er ja meint. Sonst default n.
  local default_answer="n"
  if [[ -n "$MAUBOT_URL" || -n "$MAUBOT_TOKEN" || -f "$MAUBOT_CONFIG_FILE" ]]; then
    default_answer="y"
  fi

  # In non-interactive: nur eintragen, wenn maubot-Daten explizit verfuegbar.
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -n "$MAUBOT_URL" || -f "$MAUBOT_CONFIG_FILE" ]]; then
      register_in_maubot
    else
      log_info "Keine maubot-Konfiguration sichtbar — Schritt uebersprungen."
    fi
    return 0
  fi

  if ask_yes_no "Bot jetzt in maubot eintragen?" "$default_answer"; then
    register_in_maubot
  else
    log_info "OK, kein Eintrag in maubot. Spaeter mit:"
    printf '  %s maubot-add %s\n' "$0" "$BOT_LOCALPART"
  fi
}

step_14_summary() {
  step_header 14 "Fertig — Zusammenfassung"
  printf '\n%sBot angelegt:%s\n' "$C_BOLD" "$C_RESET"
  printf '  Matrix-ID:       %s\n' "$BOT_USER_ID"
  printf '  Displayname:     %s\n' "${BOT_DISPLAYNAME:-(none)}"
  printf '  Device-ID:       %s\n' "$BOT_DEVICE_ID"
  printf '  Credentials in:  %s\n' "$(config_path_for "$BOT_LOCALPART")"

  printf '\n%sSchneller Test%s — sollte @bot:domain zurueckgeben:\n' "$C_BOLD" "$C_RESET"
  local insecure_flag=""
  [[ "$INSECURE_TLS" == "true" ]] && insecure_flag=" -k"
  cat <<EOF

  source "$(config_path_for "$BOT_LOCALPART")"
  curl${insecure_flag} -s -H "Authorization: Bearer \$BOT_ACCESS_TOKEN" \\
       "\$HOMESERVER_URL/_matrix/client/v3/account/whoami" | jq .

EOF
  printf '%sWeitere Befehle:%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s invite %s <raum1> <raum2>     # Bot in weitere Raeume joinen\n' "$0" "$BOT_LOCALPART"
  printf '  %s rotate-token %s               # neuen Token holen\n' "$0" "$BOT_LOCALPART"
  printf '  %s maubot-add %s                 # Bot in maubot eintragen\n' "$0" "$BOT_LOCALPART"
  printf '  %s maubot-remove %s              # Bot aus maubot entfernen\n' "$0" "$BOT_LOCALPART"
  printf '  %s deactivate %s                 # Bot abschalten\n' "$0" "$BOT_LOCALPART"
  echo
  log_ok "Alles erledigt."
}

cmd_register() {
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
  step_12_rooms
  step_13_maubot
  step_14_summary
}

# =============================================================================
#  Subcommand: invite
# =============================================================================

cmd_invite() {
  banner
  require_tools

  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: invite <bot> <raum>..."
  [[ ${#ROOMS[@]} -gt 0 ]]   || fatal "Mindestens einen Raum angeben. Aufruf: invite <bot> <raum>..."

  section_header "Bot in Raeume joinen (Admin force-join)"
  explain \
    "Wir laden die Bot-Config (fuer User-ID + Homeserver-URL) und brauchen" \
    "zusaetzlich einen Admin-Token, um den Bot per Synapse Admin-API in die" \
    "Raeume zu joinen. Das funktioniert fuer Raeume auf deinem eigenen HS."

  read_config "$BOT_LOCALPART"
  check_server_reachable
  obtain_admin_token
  verify_admin

  local r trimmed failed=0
  for r in "${ROOMS[@]}"; do
    trimmed="$(echo "$r" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$trimmed" ]] && continue
    if ! admin_force_join_one "$trimmed"; then
      failed=$((failed + 1))
    fi
  done

  if (( failed == 0 )); then
    log_ok "Alle Raeume erfolgreich beigetreten."
  else
    log_warn "${failed} von ${#ROOMS[@]} Raeumen fehlgeschlagen."
    exit 2
  fi
}

# =============================================================================
#  Subcommand: rotate-token
# =============================================================================

cmd_rotate_token() {
  banner
  require_tools
  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: rotate-token <bot>"

  section_header "Access-Token erneuern"
  explain \
    "Wir loggen den Bot mit dem gespeicherten Passwort neu ein und ersetzen" \
    "den Access-Token in der Config. Das alte Token bleibt zunaechst gueltig" \
    "(Synapse-Default) — du kannst es spaeter explizit per /logout entwerten." \
    "Die alte Config wird mit Zeitstempel als .bak gesichert."

  read_config "$BOT_LOCALPART"
  [[ -n "$BOT_PASSWORD" ]] || fatal "Kein BOT_PASSWORD in der Config — kann keinen neuen Token holen."

  check_server_reachable
  bot_login          # setzt BOT_ACCESS_TOKEN neu
  write_config       # schreibt mit neuem Token, sichert alte als .bak

  log_ok "Neuer Token gespeichert."
}

# =============================================================================
#  Subcommand: deactivate
# =============================================================================

cmd_deactivate() {
  banner
  require_tools
  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: deactivate <bot>"

  section_header "Bot deaktivieren"
  explain \
    "Deaktiviert den Bot auf dem Server. Der User existiert danach weiter, kann" \
    "sich aber nicht mehr einloggen. Mit --erase werden Profil-Daten zusaetzlich" \
    "geloescht (GDPR-Style). Das ist irreversibel."

  read_config "$BOT_LOCALPART"
  check_server_reachable
  obtain_admin_token
  verify_admin

  if [[ "$NON_INTERACTIVE" != "true" ]]; then
    if ! ask_yes_no "Bot ${BOT_USER_ID} wirklich deaktivieren${ERASE_DATA:+ und Daten loeschen}?" "n"; then
      fatal "Abgebrochen."
    fi
  fi

  local encoded url payload response status body
  encoded=$(url_encode_one "$BOT_USER_ID")
  url="${HOMESERVER_URL}/_synapse/admin/v1/deactivate/${encoded}"
  payload=$(jq -n --argjson erase "$([[ "$ERASE_DATA" == "true" ]] && echo true || echo false)" \
    '{erase: $erase}')

  response=$(http_request POST "$url" "-d=$payload" \
    "Authorization: Bearer ${ADMIN_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)

  if [[ "$status" != "200" ]]; then
    log_error "Deaktivierung fehlgeschlagen (HTTP $status)."
    echo "  Antwort: $body" >&2
    fatal "Pruefe Admin-Rechte / User-ID."
  fi
  log_ok "Bot ${BOT_USER_ID} deaktiviert."

  # Lokale Config sicherheitshalber wegsichern statt loeschen.
  local cfg
  cfg=$(config_path_for "$BOT_LOCALPART")
  if [[ -f "$cfg" ]]; then
    local backup="${cfg}.deactivated.$(date +%Y%m%d-%H%M%S)"
    mv -- "$cfg" "$backup"
    chmod 600 "$backup"
    log_warn "Lokale Config nach ${backup} verschoben."
  fi
}

# =============================================================================
#  Subcommand: maubot-add
# =============================================================================

cmd_maubot_add() {
  banner
  require_tools
  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: maubot-add <bot>"

  section_header "Bot in maubot eintragen"
  explain \
    "Wir laden die gespeicherte Bot-Config und tragen den Bot dann als Client" \
    "in deine maubot-Instanz ein. Falls noch keine maubot-Verbindungsdaten" \
    "konfiguriert sind, wirst du einmalig danach gefragt — danach werden" \
    "URL und Token in ${MAUBOT_CONFIG_FILE} gespeichert."

  read_config "$BOT_LOCALPART"
  register_in_maubot
}

# =============================================================================
#  Subcommand: maubot-remove
# =============================================================================

cmd_maubot_remove() {
  banner
  require_tools
  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: maubot-remove <bot>"

  section_header "Bot aus maubot entfernen"
  explain \
    "Entfernt den Client aus der maubot-Instanz. Plugin-Instanzen, die diesen" \
    "Client nutzen, werden in maubot vorher manuell geloescht werden muessen —" \
    "sonst lehnt maubot das Loeschen ggf. ab."

  read_config "$BOT_LOCALPART"
  ensure_maubot_token

  if [[ "$NON_INTERACTIVE" != "true" ]]; then
    if ! ask_yes_no "Client ${BOT_USER_ID} wirklich aus maubot entfernen?" "n"; then
      fatal "Abgebrochen."
    fi
  fi

  maubot_delete_client "$BOT_USER_ID" || fatal "Loeschen fehlgeschlagen."
}

# =============================================================================
#  CLI-Parsing
# =============================================================================

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}
  Interaktiver Assistent fuer Bot-Accounts auf einem Synapse-Homeserver.

Verwendung:
  $0 [register] [optionen]            # Default: neuen Bot registrieren
  $0 invite <bot> <raum> [<raum>...]  # Bot in Raeume joinen (Admin force-join)
  $0 rotate-token <bot>               # Neuen Access-Token holen
  $0 deactivate <bot> [--erase]       # Bot deaktivieren
  $0 maubot-add <bot>                 # Bot als Client in maubot eintragen
  $0 maubot-remove <bot>              # Bot aus maubot entfernen
  $0 help                             # Diese Hilfe

Gemeinsame Optionen:
  --server URL                   Homeserver-URL (https://matrix.example.org)
  --insecure                     TLS-Pruefung abschalten (nur eigener Server!)
  --admin-token TOKEN            Vorhandener Admin-Access-Token
  --admin-user LOCALPART         Admin-Benutzername (Localpart)
  --admin-pass PASS              Admin-Passwort (Achtung: in Shell-History!)
  --non-interactive              Keine Prompts, alle Werte aus Flags

Optionen fuer 'register':
  --bot LOCALPART                Bot-Localpart (z.B. wetterbot)
  --displayname NAME             Anzeigename
  --password PASS                Passwort vorgeben
  --generate-password            Zufaelliges Passwort erzeugen
  --rooms "r1,r2,..."            Raeume zum Auto-Join (kommasepariert)
  --no-maubot                    maubot-Schritt im register-Flow auslassen

Optionen fuer 'deactivate':
  --erase                        Profil-Daten zusaetzlich loeschen (irreversibel)

maubot-Optionen (fuer register, maubot-add, maubot-remove):
  --maubot-url URL               Maubot-URL (z.B. https://maubot.example.org)
  --maubot-token TOKEN           Maubot-Management-Token (Bearer)
  --maubot-replace               Bestehenden Client ohne Frage ueberschreiben
  --maubot-no-save               Token NICHT in ${MAUBOT_CONFIG_FILE} speichern

  Hinweis: Beim ersten Mal kannst du den Token interaktiv per einmaligem
  Username/Passwort-Login holen. URL und Token werden danach in
  ${MAUBOT_CONFIG_FILE} (chmod 600) abgelegt und automatisch wiederverwendet.

Beispiele:
  # Interaktiv (empfohlen beim ersten Mal):
  $0

  # Non-interaktiv komplett (inkl. maubot):
  $0 register --server https://matrix.example.org \\
              --admin-token \$ADMIN_TOKEN \\
              --bot wetterbot --displayname "Wetter Bot" \\
              --generate-password \\
              --rooms "#general:example.org,!abc123:example.org" \\
              --maubot-url https://maubot.example.org \\
              --maubot-token \$MAUBOT_TOKEN \\
              --non-interactive

  # Bot spaeter in einen Raum joinen:
  $0 invite wetterbot "#meldungen:example.org" --admin-user alice --admin-pass ...

  # Token erneuern (kein Admin-Token noetig — Bot-Passwort steht in der Config):
  $0 rotate-token wetterbot --server https://matrix.example.org

  # Bestehenden Bot nachtraeglich in maubot eintragen:
  $0 maubot-add wetterbot

  # Bot aus maubot entfernen:
  $0 maubot-remove wetterbot

  # Bot abschalten:
  $0 deactivate wetterbot --admin-token \$ADMIN_TOKEN
EOF
}

banner() {
  cat <<EOF
${C_BOLD}${C_CYAN}
  ${SCRIPT_NAME} v${SCRIPT_VERSION}
${C_RESET}
EOF
}

# parse_common_flags: zieht aus den verbleibenden Argumenten die gemeinsamen
# Optionen + die subcommand-spezifischen heraus. Positionsargumente landen
# zurueck in $REMAINING_ARGS.
REMAINING_ARGS=()
parse_flags() {
  local subcommand="$1"; shift
  REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)              HOMESERVER_URL="$2"; shift 2 ;;
      --server=*)            HOMESERVER_URL="${1#*=}"; shift ;;
      --insecure)            INSECURE_TLS="true"; shift ;;
      --admin-token)         ADMIN_TOKEN="$2"; shift 2 ;;
      --admin-token=*)       ADMIN_TOKEN="${1#*=}"; shift ;;
      --admin-user)          ADMIN_USER="$2"; shift 2 ;;
      --admin-user=*)        ADMIN_USER="${1#*=}"; shift ;;
      --admin-pass)          ADMIN_PASS="$2"; shift 2 ;;
      --admin-pass=*)        ADMIN_PASS="${1#*=}"; shift ;;
      --non-interactive)     NON_INTERACTIVE="true"; shift ;;
      --bot)                 BOT_LOCALPART="$2"; shift 2 ;;
      --bot=*)               BOT_LOCALPART="${1#*=}"; shift ;;
      --displayname)         BOT_DISPLAYNAME="$2"; shift 2 ;;
      --displayname=*)       BOT_DISPLAYNAME="${1#*=}"; shift ;;
      --password)            BOT_PASSWORD="$2"; GENERATE_PASSWORD="false"; shift 2 ;;
      --password=*)          BOT_PASSWORD="${1#*=}"; GENERATE_PASSWORD="false"; shift ;;
      --generate-password)   GENERATE_PASSWORD="true"; shift ;;
      --rooms)               IFS=',' read -r -a ROOMS <<<"$2"; shift 2 ;;
      --rooms=*)             IFS=',' read -r -a ROOMS <<<"${1#*=}"; shift ;;
      --erase)               ERASE_DATA="true"; shift ;;
      --maubot-url)          MAUBOT_URL="${2%/}"; shift 2 ;;
      --maubot-url=*)        MAUBOT_URL="${1#*=}"; MAUBOT_URL="${MAUBOT_URL%/}"; shift ;;
      --maubot-token)        MAUBOT_TOKEN="$2"; shift 2 ;;
      --maubot-token=*)      MAUBOT_TOKEN="${1#*=}"; shift ;;
      --maubot-replace)      MAUBOT_REPLACE="true"; shift ;;
      --maubot-no-save)      MAUBOT_NO_SAVE="true"; shift ;;
      --no-maubot)           SKIP_MAUBOT="true"; shift ;;
      -h|--help)             usage; exit 0 ;;
      --)                    shift; while [[ $# -gt 0 ]]; do REMAINING_ARGS+=("$1"); shift; done ;;
      --*)                   fatal "Unbekanntes Flag: $1" ;;
      *)                     REMAINING_ARGS+=("$1"); shift ;;
    esac
  done

  # Subcommand-spezifische Positionsargument-Logik:
  case "$subcommand" in
    register)
      # Keine zwingenden Positionsargs.
      ;;
    invite)
      # Erstes Pos-Arg = Bot, der Rest = Raeume.
      if [[ ${#REMAINING_ARGS[@]} -gt 0 && -z "$BOT_LOCALPART" ]]; then
        BOT_LOCALPART="${REMAINING_ARGS[0]}"
        REMAINING_ARGS=("${REMAINING_ARGS[@]:1}")
      fi
      if [[ ${#REMAINING_ARGS[@]} -gt 0 ]]; then
        # Restliche Pos-Args + die per --rooms gesetzten kombinieren.
        ROOMS+=("${REMAINING_ARGS[@]}")
      fi
      ;;
    rotate-token|deactivate|maubot-add|maubot-remove)
      if [[ ${#REMAINING_ARGS[@]} -gt 0 && -z "$BOT_LOCALPART" ]]; then
        BOT_LOCALPART="${REMAINING_ARGS[0]}"
        REMAINING_ARGS=("${REMAINING_ARGS[@]:1}")
      fi
      ;;
  esac
}

on_interrupt() {
  echo
  log_warn "Abgebrochen. Bereits angelegte User oder gespeicherte Configs bleiben bestehen."
  exit 130
}
trap on_interrupt INT TERM

# =============================================================================
#  Dispatcher
# =============================================================================

main() {
  local subcommand="register"
  if [[ $# -gt 0 ]]; then
    case "$1" in
      register|invite|rotate-token|deactivate|maubot-add|maubot-remove)
        subcommand="$1"; shift ;;
      help|--help|-h)
        usage; exit 0 ;;
      --*)
        # Direkt mit Flags (ohne Subcommand) = register
        ;;
      *)
        # Unbekanntes Positionsargument am Anfang — ggf. Tippfehler.
        log_warn "Unbekannter Subcommand '$1' — behandele als 'register'."
        ;;
    esac
  fi

  parse_flags "$subcommand" "$@"

  case "$subcommand" in
    register)      cmd_register ;;
    invite)        cmd_invite ;;
    rotate-token)  cmd_rotate_token ;;
    deactivate)    cmd_deactivate ;;
    maubot-add)    cmd_maubot_add ;;
    maubot-remove) cmd_maubot_remove ;;
  esac
}

main "$@"
