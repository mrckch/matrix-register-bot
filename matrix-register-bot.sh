#!/usr/bin/env bash
# =============================================================================
#  matrix-register-bot.sh
# -----------------------------------------------------------------------------
#  Multi-Command-Werkzeug zum Verwalten von Bot-Accounts auf einem privaten
#  Synapse-Homeserver (Matrix). Fuehrt durch alle Schritte, die man sonst
#  vergisst:
#
#    register      Bot anlegen, Token erzeugen, Credentials speichern,
#                  optional in Raeume joinen, optional DM mit User starten
#    invite        Bestehenden Bot in (weitere) Raeume joinen (Admin force-join)
#    dm            Direkt-Chat zwischen Bot und einem oder mehreren Usern
#    rotate-token  Mit gespeichertem Passwort neuen Access-Token holen
#    deactivate    Bot auf dem Server deaktivieren
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
readonly SCRIPT_VERSION="0.4.3"
readonly CONFIG_DIR="${HOME}/.config/${SCRIPT_NAME}"

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

# Direct-Message-State
DMS=()                   # User-MXIDs (vollqualifiziert), mit denen ein DM angelegt wird
DM_MESSAGE=""            # Optionale Begruessungsnachricht (leer = Default-Text)
DM_NO_MESSAGE="false"    # true = ueberhaupt keine Nachricht senden

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

# extract_localpart <input> [expected_domain]
# Liefert den Localpart einer Matrix-User-Eingabe auf stdout. Akzeptiert sowohl
# nackten Localpart ("alice") als auch volle MXID ("@alice:matrix.example.org",
# auch ohne fuehrendes "@"). Validiert den Localpart gegen die Matrix-Regel
# (Kleinbuchstaben, Ziffern, . _ = / -).
# Exit-Codes:
#   0  OK
#   1  Eingabe ist syntaktisch keine gueltige Matrix-User-Form
#   2  MXID gegeben, Domain stimmt nicht mit expected_domain ueberein.
#      Der Localpart wird trotzdem auf stdout ausgegeben (damit der Caller
#      eine Mismatch-Meldung mit Werten formatieren kann).
extract_localpart() {
  local input="$1"
  local expected_domain="${2:-}"
  # Whitespace trimmen
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  [[ -z "$input" ]] && return 1

  local local_part="" domain=""
  # Form mit Domain: optional "@", Localpart, ":", Domain
  if [[ "$input" =~ ^@?([a-z0-9._=/-]+):([a-zA-Z0-9.-]+)$ ]]; then
    local_part="${BASH_REMATCH[1]}"
    domain="${BASH_REMATCH[2]}"
  # Form ohne Domain: optional "@", Localpart
  elif [[ "$input" =~ ^@?([a-z0-9._=/-]+)$ ]]; then
    local_part="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  printf '%s' "$local_part"
  if [[ -n "$domain" && -n "$expected_domain" && "$domain" != "$expected_domain" ]]; then
    return 2
  fi
  return 0
}

# csv_split <input>: gibt jedes nicht-leere, gestripte Item zeilenweise aus.
# Macht `--rooms ""` / `--dm "a,,b,"` robust: leere Eintraege werden verworfen.
csv_split() {
  local input="$1"
  [[ -z "$input" ]] && return 0
  local item trimmed
  local oldIFS="$IFS"
  IFS=','
  # Globbing aus, damit ein '#raum:*' nicht versehentlich expandiert.
  set -f
  for item in $input; do
    trimmed="${item#"${item%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] && printf '%s\n' "$trimmed"
  done
  set +f
  IFS="$oldIFS"
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
  local out
  # Kein "// empty" — sonst geht der Wert 'false' verloren (`false // empty` == empty).
  # Stattdessen jq normal aufrufen und 'null' (= Feld nicht vorhanden) auf leer mappen.
  if ! out=$(echo "$json" | jq -r "$path" 2>/dev/null); then
    echo ""
    return
  fi
  [[ "$out" == "null" ]] && out=""
  echo "$out"
}

# url_encode_one: Encoded ein Path-Segment (User-ID oder Raum). Wir kodieren
# die Zeichen, die in Matrix-IDs vorkommen und in URL-Pfaden Probleme machen.
# WICHTIG: '%' MUSS zuerst kodiert werden, sonst werden bereits produzierte
# %XX-Sequenzen ein zweites Mal kodiert.
url_encode_one() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//@/%40}"
  s="${s//:/%3A}"
  s="${s//\!/%21}"
  s="${s//\#/%23}"
  s="${s//\//%2F}"
  s="${s//\?/%3F}"
  s="${s//\&/%26}"
  s="${s// /%20}"
  echo "$s"
}

# =============================================================================
#  Config-Datei IO
# =============================================================================

config_path_for() {
  # Der Matrix-Localpart darf '/' enthalten — das wuerde aber zu einem
  # Unterverzeichnis im Pfad. Ersetzen wir durch '%2F' (URL-Stil), damit der
  # Dateiname stabil bleibt und sich nicht mit echten Subdirs ueberlagert.
  local safe="${1//\//%2F}"
  echo "${CONFIG_DIR}/${safe}.env"
}

# shell_escape_for_dq: escaped einen Wert so, dass er innerhalb von "..." in
# einer Shell-Datei korrekt liegt — d.h. `source` die Datei ohne Schaden lesen
# kann. Reihenfolge wichtig: Backslash ZUERST, sonst werden nachfolgende
# Escapes selbst nochmal eskapt.
shell_escape_for_dq() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$/\\\$}"
  s="${s//\`/\\\`}"
  printf '%s' "$s"
}

# shell_unescape_from_dq: dreht shell_escape_for_dq um. Liest Zeichen fuer
# Zeichen und konsumiert Backslash + Folgezeichen, wenn das Folgezeichen ein
# bekanntes Escape ist. Andere Backslashes bleiben stehen.
shell_unescape_from_dq() {
  local s="$1"
  local out="" i ch next
  local len=${#s}
  for (( i=0; i<len; i++ )); do
    ch="${s:i:1}"
    if [[ "$ch" == "\\" && $((i+1)) -lt len ]]; then
      next="${s:i+1:1}"
      case "$next" in
        '\'|'"'|'$'|'`')
          out+="$next"
          (( i++ ))
          continue
          ;;
      esac
    fi
    out+="$ch"
  done
  printf '%s' "$out"
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

  # Alle Werte fuer "..."-Kontext escapen, damit `source <datei>` auch dann
  # noch funktioniert, wenn das Passwort oder der Displayname Quotes, $, ` etc.
  # enthaelt.
  local _hs _uid _local _dn _pw _tok _dev
  _hs=$(shell_escape_for_dq    "$HOMESERVER_URL")
  _uid=$(shell_escape_for_dq   "$BOT_USER_ID")
  _local=$(shell_escape_for_dq "$BOT_LOCALPART")
  _dn=$(shell_escape_for_dq    "$BOT_DISPLAYNAME")
  _pw=$(shell_escape_for_dq    "$BOT_PASSWORD")
  _tok=$(shell_escape_for_dq   "$BOT_ACCESS_TOKEN")
  _dev=$(shell_escape_for_dq   "$BOT_DEVICE_ID")

  cat > "$target" <<EOF
# matrix-register-bot — Credentials fuer ${BOT_USER_ID}
# Generiert am $(date -u +%Y-%m-%dT%H:%M:%SZ) durch ${SCRIPT_NAME} ${SCRIPT_VERSION}
# WARNUNG: Diese Datei enthaelt Geheimnisse. NIEMALS in Git committen.

HOMESERVER_URL="${_hs}"
BOT_USER_ID="${_uid}"
BOT_LOCALPART="${_local}"
BOT_DISPLAYNAME="${_dn}"
BOT_PASSWORD="${_pw}"
BOT_ACCESS_TOKEN="${_tok}"
BOT_DEVICE_ID="${_dev}"
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
    # Form: KEY=VALUE — Schluessel ist alles vor dem ersten =. VALUE darf
    # optional in "..." stehen; Inhalt wird in dem Fall unescaped (Pendant
    # zu shell_escape_for_dq).
    if [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
        value=$(shell_unescape_from_dq "$value")
      fi
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

# normalize_bot_localpart_or_fatal: Wenn BOT_LOCALPART gesetzt ist (z.B. aus
# Positionsarg oder --bot Flag) und der User die volle MXID angegeben hat,
# wird auf den Localpart reduziert. Domain-Check passiert hier NICHT — bei den
# Subcommands ausser register kennen wir die Server-Domain erst nach
# read_config; ein Mismatch wuerde dort beim read_config auffallen.
normalize_bot_localpart_or_fatal() {
  [[ -z "$BOT_LOCALPART" ]] && return 0
  local normalized
  if ! normalized=$(extract_localpart "$BOT_LOCALPART"); then
    fatal "Ungueltiger Bot-Localpart/MXID: '$BOT_LOCALPART'"
  fi
  if [[ "$normalized" != "$BOT_LOCALPART" ]]; then
    log_info "Aus '${BOT_LOCALPART}' extrahiert: Localpart '${normalized}'"
  fi
  BOT_LOCALPART="$normalized"
}

require_tools() {
  local missing=()
  for tool in curl jq openssl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Es fehlen folgende Werkzeuge: ${missing[*]}"
    printf '\n    apt update && apt install -y %s\n\n' "${missing[*]}"
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
    # http(s)://host[:port][/optional/subpath] — Subpath ist gaengig hinter
    # Reverse-Proxies (z.B. https://example.org/matrix).
    if [[ "$HOMESERVER_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/!$&\'()*+,;=:@-]*)?$ ]]; then
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
    return 0
  fi

  # ADMIN_USER kann aus --admin-user kommen — normalisieren und validieren.
  if [[ -n "$ADMIN_USER" ]]; then
    local normalized
    if ! normalized=$(extract_localpart "$ADMIN_USER"); then
      fatal "Ungueltiger Admin-Benutzername: '$ADMIN_USER' (erlaubt: a-z 0-9 . _ = / -, optional als MXID @user:domain)"
    fi
    if [[ "$normalized" != "$ADMIN_USER" ]]; then
      log_info "Admin-Benutzername aus '$ADMIN_USER' auf Localpart '$normalized' reduziert."
    fi
    ADMIN_USER="$normalized"
  fi

  if [[ -n "$ADMIN_USER" && -n "$ADMIN_PASS" ]]; then
    admin_login "$ADMIN_USER" "$ADMIN_PASS"
    return 0
  fi

  explain \
    "Wir brauchen Admin-Rechte. Du kannst entweder einen vorhandenen Admin-" \
    "Access-Token eingeben (Option 1) oder dich mit Admin-Benutzer+Passwort" \
    "anmelden, sodass wir einen Token fuer dich holen (Option 2)."
  local choice
  choice=$(ask "Auswahl (1/2)" "2")
  if [[ "$choice" == "1" ]]; then
    ADMIN_TOKEN=$(ask_secret "Admin-Access-Token (wird nicht angezeigt)")
    [[ -z "$ADMIN_TOKEN" ]] && fatal "Leerer Token."
    return 0
  fi

  # Option 2: User + Pass. Solange wiederholen, bis Eingabe valide.
  if [[ -z "$ADMIN_USER" ]]; then
    local raw normalized
    while true; do
      raw=$(ask "Admin-Benutzername (z.B. 'alice' oder '@alice:matrix.example.org')" "")
      [[ -z "$raw" ]] && { log_warn "Leerer Benutzername. Nochmal."; continue; }
      if normalized=$(extract_localpart "$raw"); then
        ADMIN_USER="$normalized"
        [[ "$normalized" != "$raw" ]] && log_info "Localpart extrahiert: '${ADMIN_USER}'"
        break
      fi
      log_warn "Ungueltige Eingabe. Erlaubt: Localpart wie 'alice' oder MXID wie '@alice:domain'."
    done
  fi
  ADMIN_PASS=$(ask_secret "Passwort des Admin-Users")
  [[ -z "$ADMIN_PASS" ]] && fatal "Leeres Passwort."
  admin_login "$ADMIN_USER" "$ADMIN_PASS"
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
#  Direct-Message-Funktionen
# =============================================================================
#
#  Ein DM auf Matrix ist technisch ein normaler Raum mit
#    - is_direct: true beim Erstellen
#    - preset: trusted_private_chat
#    - einem Eintrag in der m.direct Account-Data des Bot-Users, der den Raum
#      einem bestimmten Gegenueber zuordnet (Map: user_id -> [room_id, ...])
#
#  Wir nutzen den Bot-Access-Token (nicht den Admin-Token) — der Bot ist
#  selbst der Raum-Creator und lae den Ziel-User ein. Den eigentlichen Beitritt
#  muss der User in seinem Client annehmen — das koennen (und wollen) wir nicht
#  fuer ihn erzwingen.
# =============================================================================

# normalize_user_id <input>: vervollstaendigt eine Matrix-ID.
#   "marc"               -> "@marc:${SERVER_DOMAIN}"
#   "@marc"              -> "@marc:${SERVER_DOMAIN}"
#   "@marc:example.org"  -> unveraendert
normalize_user_id() {
  local input="$1"
  input="$(echo "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$input" ]] && { echo ""; return; }
  if [[ "$input" == *:* ]]; then
    # Ggf. fehlendes @ ergaenzen
    [[ "$input" != @* ]] && input="@$input"
    echo "$input"
  else
    local localpart="${input#@}"
    echo "@${localpart}:${SERVER_DOMAIN}"
  fi
}

# bot_get_direct_map: liest die m.direct Account-Data des Bots und gibt das
# JSON-Object zurueck. Bei 404 (noch nie gesetzt) wird "{}" geliefert.
bot_get_direct_map() {
  local encoded_user url response status body
  encoded_user=$(url_encode_one "$BOT_USER_ID")
  url="${HOMESERVER_URL}/_matrix/client/v3/user/${encoded_user}/account_data/m.direct"
  response=$(http_request GET "$url" "Authorization: Bearer ${BOT_ACCESS_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  case "$status" in
    200) echo "$body" ;;
    404) echo "{}" ;;
    *)
      log_warn "m.direct-Lesen unerwarteter Status $status — nehme leeres Mapping an."
      echo "{}" ;;
  esac
}

# bot_user_has_dm <user_mxid>: prueft im Bot's m.direct-Mapping, ob es schon
# einen DM-Raum mit diesem User gibt. Gibt 0 zurueck wenn ja, 1 wenn nein.
bot_user_has_dm() {
  local target="$1"
  local map count
  map=$(bot_get_direct_map)
  count=$(echo "$map" | jq --arg u "$target" '(.[$u] // []) | length' 2>/dev/null || echo "0")
  [[ "$count" -gt 0 ]]
}

# bot_create_dm_room <user_mxid>: erstellt einen DM-Raum, gibt room_id auf stdout.
# Setzt einen Fehler-Exit, wenn der Server den Raum nicht erstellt.
bot_create_dm_room() {
  local target="$1"
  local payload response status body room_id
  payload=$(jq -n --arg u "$target" \
    '{ preset: "trusted_private_chat",
       is_direct: true,
       visibility: "private",
       invite: [ $u ] }')
  response=$(http_request POST "${HOMESERVER_URL}/_matrix/client/v3/createRoom" \
    "-d=$payload" \
    "Authorization: Bearer ${BOT_ACCESS_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  if [[ "$status" != "200" ]]; then
    log_error "Raum-Erstellung fehlgeschlagen (HTTP $status)."
    echo "  Antwort: $body" >&2
    fatal "Pruefe Bot-Token und User-ID."
  fi
  room_id=$(json_get "$body" '.room_id')
  [[ -z "$room_id" ]] && fatal "Kein room_id in der Antwort gefunden."
  echo "$room_id"
}

# bot_update_direct_map <user_mxid> <room_id>: liest m.direct, fuegt den neuen
# Raum unter dem User-Key hinzu (oder erstellt den Eintrag) und schreibt zurueck.
bot_update_direct_map() {
  local target="$1"
  local room_id="$2"
  local map new_map encoded_user url payload response status body
  map=$(bot_get_direct_map)
  new_map=$(echo "$map" | jq --arg u "$target" --arg r "$room_id" \
    '. + {($u): ((.[$u] // []) + [$r] | unique)}')

  encoded_user=$(url_encode_one "$BOT_USER_ID")
  url="${HOMESERVER_URL}/_matrix/client/v3/user/${encoded_user}/account_data/m.direct"
  response=$(http_request PUT "$url" "-d=$new_map" \
    "Authorization: Bearer ${BOT_ACCESS_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  if [[ "$status" != "200" ]]; then
    log_warn "m.direct-Update fehlgeschlagen (HTTP $status). Der Raum wurde trotzdem angelegt."
    echo "  Antwort: $body" >&2
    return 1
  fi
}

# bot_send_message <room_id> <text>: schickt eine m.room.message vom Bot.
bot_send_message() {
  local room_id="$1"
  local text="$2"
  local txn payload encoded_room url response status body
  # Eindeutige Transaktions-ID — Matrix verlangt das, sonst Replay-Schutz.
  txn="mrb-$(openssl rand -hex 8)"
  payload=$(jq -n --arg b "$text" '{msgtype:"m.text", body:$b}')
  encoded_room=$(url_encode_one "$room_id")
  url="${HOMESERVER_URL}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn}"
  response=$(http_request PUT "$url" "-d=$payload" \
    "Authorization: Bearer ${BOT_ACCESS_TOKEN}")
  status=$(echo "$response" | head -n1)
  body=$(echo "$response" | tail -n +2)
  if [[ "$status" != "200" ]]; then
    log_warn "Begruessungsnachricht konnte nicht gesendet werden (HTTP $status)."
    echo "  Antwort: $body" >&2
    return 1
  fi
}

# default_dm_message: liefert einen Standard-Text fuer den Bot.
default_dm_message() {
  local name="${BOT_DISPLAYNAME:-$BOT_LOCALPART}"
  echo "Hallo! Ich bin ${name} und wurde gerade per matrix-register-bot eingerichtet. Wenn du diese Nachricht siehst, klappt unser DM."
}

# dm_with_user <user_mxid>: legt einen DM zum User an inkl. Konflikt-Check,
# m.direct-Update und optionaler Begruessung. Gibt 0 zurueck bei Erfolg,
# 1 bei Skip (z.B. existierender DM und non-interactive).
dm_with_user() {
  local raw="$1"
  local target
  target=$(normalize_user_id "$raw")

  # MXID-Form pruefen — soll @local:domain matchen.
  if [[ ! "$target" =~ ^@[a-z0-9._=/-]+:[a-zA-Z0-9.-]+$ ]]; then
    log_error "Ungueltige Matrix-ID: '$raw' (normalisiert: '$target')"
    return 1
  fi

  # Idempotenz: gibt's schon einen DM mit dem User?
  if bot_user_has_dm "$target"; then
    log_warn "Es existiert bereits ein DM zwischen ${BOT_USER_ID} und ${target}."
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      log_info "Skipped (non-interactive)."
      return 1
    fi
    if ! ask_yes_no "Trotzdem einen neuen DM-Raum anlegen?" "n"; then
      log_info "OK, kein zweiter DM."
      return 1
    fi
  fi

  log_info "Erstelle DM-Raum mit ${target}..."
  local room_id
  room_id=$(bot_create_dm_room "$target")
  log_ok "Raum angelegt: ${room_id}"

  bot_update_direct_map "$target" "$room_id" \
    && log_ok "m.direct aktualisiert (Client erkennt den Raum als DM)." || true

  if [[ "$DM_NO_MESSAGE" != "true" ]]; then
    local text="${DM_MESSAGE:-$(default_dm_message)}"
    if bot_send_message "$room_id" "$text"; then
      log_ok "Begruessungsnachricht gesendet."
    fi
  fi

  log_info "Wichtig: ${target} muss die Einladung in seinem Matrix-Client annehmen."
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
  step_header 5 "Bot-Benutzername (Localpart oder volle Matrix-ID)"
  explain \
    "Du kannst entweder nur den Localpart oder die volle Matrix-ID eingeben:" \
    "  Localpart:    wetterbot" \
    "  Matrix-ID:    @wetterbot:${SERVER_DOMAIN}" \
    "Erlaubt im Localpart: Kleinbuchstaben, Ziffern, . _ = / -" \
    "Bei voller MXID wird die Domain gegen den Server (${SERVER_DOMAIN}) geprueft."

  if [[ -n "$BOT_LOCALPART" ]]; then
    local normalized rc=0
    normalized=$(extract_localpart "$BOT_LOCALPART" "$SERVER_DOMAIN") || rc=$?
    case $rc in
      0)
        if [[ "$normalized" != "$BOT_LOCALPART" ]]; then
          log_info "Aus '${BOT_LOCALPART}' extrahiert: Localpart '${normalized}'"
        fi
        BOT_LOCALPART="$normalized"
        ;;
      2)
        fatal "Bot-MXID '${BOT_LOCALPART}' gehoert nicht zu Server-Domain '${SERVER_DOMAIN}'."
        ;;
      *)
        fatal "Ungueltiger Bot-Localpart aus Flag: '${BOT_LOCALPART}'"
        ;;
    esac
    log_info "Localpart: ${BOT_LOCALPART}"
  else
    local raw normalized rc
    while true; do
      raw=$(ask "Bot-Localpart oder MXID (z.B. 'wetterbot' oder '@wetterbot:${SERVER_DOMAIN}')" "")
      [[ -z "$raw" ]] && { log_warn "Leere Eingabe. Nochmal."; continue; }
      rc=0
      normalized=$(extract_localpart "$raw" "$SERVER_DOMAIN") || rc=$?
      case $rc in
        0)
          BOT_LOCALPART="$normalized"
          [[ "$normalized" != "$raw" ]] && log_info "Localpart extrahiert: '${BOT_LOCALPART}'"
          break
          ;;
        2)
          log_warn "Domain '${raw##*:}' passt nicht zu '${SERVER_DOMAIN}'. Bitte korrigieren."
          ;;
        *)
          log_warn "Ungueltige Eingabe. Erlaubt: Localpart (a-z 0-9 . _ = / -) oder MXID (@local:domain)."
          ;;
      esac
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

      # Ein deaktivierter User wuerde durch das spaetere PUT (Step 9) mit
      # 'deactivated: false' STILLSCHWEIGEND reaktiviert. Das ist fast nie
      # gewollt, also explizit darauf hinweisen.
      if [[ "$deactivated" == "true" ]]; then
        log_warn "ACHTUNG: Dieser User ist deaktiviert. Beim Fortfahren wird er reaktiviert."
      fi

      # Im non-interactive Modus: Passwort + Token neu setzen, wenn entweder
      # --password (BOT_PASSWORD != "") oder --generate-password
      # (GENERATE_PASSWORD == "true") gegeben wurde. Sonst fatal — der User
      # soll sich aktiv fuer eine der Optionen entscheiden.
      if [[ "$NON_INTERACTIVE" == "true" ]]; then
        if [[ -n "$BOT_PASSWORD" ]]; then
          log_info "(non-interactive) Passwort wird neu gesetzt (aus --password)."
        elif [[ "$GENERATE_PASSWORD" == "true" ]]; then
          log_info "(non-interactive) Passwort wird neu gesetzt (--generate-password)."
        else
          fatal "User existiert. In non-interactive --password oder --generate-password angeben (oder rotate-token nutzen)."
        fi
        return 0
      fi

      if [[ "$deactivated" == "true" ]]; then
        if ! ask_yes_no "Deaktivierten User ${BOT_USER_ID} jetzt reaktivieren?" "n"; then
          fatal "Abgebrochen — User bleibt deaktiviert."
        fi
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
      mapfile -t ROOMS < <(csv_split "$input")
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

step_13_direct_messages() {
  step_header 13 "Direkt-Chats anlegen (optional)"
  explain \
    "Der Bot kann jetzt einen DM-Raum mit einem oder mehreren Usern erstellen." \
    "So hast du sofort einen 1-zu-1-Chat mit dem neuen Bot. Du gibst eine oder" \
    "mehrere Matrix-IDs an (kommasepariert), z.B.:" \
    "  @marc:${SERVER_DOMAIN:-example.org}" \
    "  marc                       (Kurzform — wird zu @marc:${SERVER_DOMAIN:-example.org})" \
    "Der Bot legt pro User EINEN DM-Raum an und schickt eine Begruessung." \
    "Die Einladung musst du in deinem Matrix-Client noch annehmen."

  # Bereits per --dm gegeben? Sonst interaktiv fragen.
  if [[ ${#DMS[@]} -eq 0 && "$NON_INTERACTIVE" == "false" ]]; then
    local input
    input=$(ask "User-MXIDs (leer = ueberspringen)" "")
    if [[ -n "$input" ]]; then
      mapfile -t DMS < <(csv_split "$input")
    fi
  fi

  if [[ ${#DMS[@]} -eq 0 ]]; then
    log_info "Kein DM angelegt."
    return 0
  fi

  # Begruessungstext optional interaktiv anpassen (nur wenn nicht via Flag/no-message).
  if [[ "$DM_NO_MESSAGE" != "true" && -z "$DM_MESSAGE" && "$NON_INTERACTIVE" == "false" ]]; then
    local default_text
    default_text=$(default_dm_message)
    echo "  Default-Begruessung: \"${default_text}\""
    if ask_yes_no "Eigenen Begruessungstext eingeben?" "n"; then
      DM_MESSAGE=$(ask "Text" "")
      [[ -z "$DM_MESSAGE" ]] && DM_NO_MESSAGE="true"
    fi
  fi

  local target failed=0
  for target in "${DMS[@]}"; do
    if ! dm_with_user "$target"; then
      failed=$((failed + 1))
    fi
  done
  if (( failed > 0 )); then
    log_warn "${failed} von ${#DMS[@]} DM-Erstellungen uebersprungen/fehlgeschlagen."
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
  printf '  %s dm %s @marc:domain            # DM mit User starten\n' "$0" "$BOT_LOCALPART"
  printf '  %s rotate-token %s               # neuen Token holen\n' "$0" "$BOT_LOCALPART"
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
  step_13_direct_messages
  step_14_summary
}

# =============================================================================
#  Subcommand: invite
# =============================================================================

cmd_invite() {
  banner
  require_tools

  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: invite <bot> <raum>..."
  normalize_bot_localpart_or_fatal
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
#  Subcommand: dm
# =============================================================================

cmd_dm() {
  banner
  require_tools
  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: dm <bot> <user>..."
  normalize_bot_localpart_or_fatal
  [[ ${#DMS[@]} -gt 0 ]]    || fatal "Mindestens einen User angeben. Aufruf: dm <bot> <user>..."

  section_header "Direkt-Chat mit User starten"
  explain \
    "Wir laden die Bot-Config und der Bot legt fuer jeden angegebenen User" \
    "einen 1-zu-1-DM an, taggt ihn als m.direct und sendet (sofern nicht" \
    "--dm-no-message) eine Begruessungsnachricht. Der User muss die Einladung" \
    "in seinem Matrix-Client annehmen."

  read_config "$BOT_LOCALPART"
  check_server_reachable

  local target failed=0
  for target in "${DMS[@]}"; do
    if ! dm_with_user "$target"; then
      failed=$((failed + 1))
    fi
  done

  if (( failed > 0 )); then
    log_warn "${failed} von ${#DMS[@]} DM-Erstellungen uebersprungen/fehlgeschlagen."
    exit 2
  fi
  log_ok "Alle DMs angelegt."
}

# =============================================================================
#  Subcommand: rotate-token
# =============================================================================

cmd_rotate_token() {
  banner
  require_tools
  [[ -n "$BOT_LOCALPART" ]] || fatal "Bot-Localpart fehlt. Aufruf: rotate-token <bot>"
  normalize_bot_localpart_or_fatal

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
  normalize_bot_localpart_or_fatal

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
#  CLI-Parsing
# =============================================================================

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}
  Interaktiver Assistent fuer Bot-Accounts auf einem Synapse-Homeserver.

Verwendung:
  $0 [register] [optionen]            # Default: neuen Bot registrieren
  $0 invite <bot> <raum> [<raum>...]  # Bot in Raeume joinen (Admin force-join)
  $0 dm <bot> <user> [<user>...]      # Direkt-Chat mit einem oder mehreren Usern
  $0 rotate-token <bot>               # Neuen Access-Token holen
  $0 deactivate <bot> [--erase]       # Bot deaktivieren
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
  --dm "@u1:dom,@u2:dom"         User, mit denen ein DM-Raum erstellt wird
  --dm-message TEXT              Eigene Begruessungsnachricht (statt Default)
  --dm-no-message                Keine Begruessungsnachricht senden

Optionen fuer 'deactivate':
  --erase                        Profil-Daten zusaetzlich loeschen (irreversibel)

Beispiele:
  # Interaktiv (empfohlen beim ersten Mal):
  $0

  # Non-interaktiv komplett:
  $0 register --server https://matrix.example.org \\
              --admin-token \$ADMIN_TOKEN \\
              --bot wetterbot --displayname "Wetter Bot" \\
              --generate-password \\
              --rooms "#general:example.org,!abc123:example.org" \\
              --dm "@marc:example.org" \\
              --non-interactive

  # Bot spaeter in einen Raum joinen:
  $0 invite wetterbot "#meldungen:example.org" --admin-user alice --admin-pass ...

  # Direkt-Chat mit User starten (Bot leitet ein):
  $0 dm wetterbot @marc:example.org
  $0 dm wetterbot marc anna                  # Kurzformen, gleicher HS

  # Token erneuern (kein Admin-Token noetig — Bot-Passwort steht in der Config):
  $0 rotate-token wetterbot --server https://matrix.example.org

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
      --rooms)               mapfile -t -O "${#ROOMS[@]}" ROOMS < <(csv_split "$2"); shift 2 ;;
      --rooms=*)             mapfile -t -O "${#ROOMS[@]}" ROOMS < <(csv_split "${1#*=}"); shift ;;
      --erase)               ERASE_DATA="true"; shift ;;
      --dm)                  mapfile -t -O "${#DMS[@]}" DMS < <(csv_split "$2"); shift 2 ;;
      --dm=*)                mapfile -t -O "${#DMS[@]}" DMS < <(csv_split "${1#*=}"); shift ;;
      --dm-message)          DM_MESSAGE="$2"; shift 2 ;;
      --dm-message=*)        DM_MESSAGE="${1#*=}"; shift ;;
      --dm-no-message)       DM_NO_MESSAGE="true"; shift ;;
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
    dm)
      # Erstes Pos-Arg = Bot, der Rest = User-MXIDs.
      if [[ ${#REMAINING_ARGS[@]} -gt 0 && -z "$BOT_LOCALPART" ]]; then
        BOT_LOCALPART="${REMAINING_ARGS[0]}"
        REMAINING_ARGS=("${REMAINING_ARGS[@]:1}")
      fi
      if [[ ${#REMAINING_ARGS[@]} -gt 0 ]]; then
        DMS+=("${REMAINING_ARGS[@]}")
      fi
      ;;
    rotate-token|deactivate)
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
      register|invite|dm|rotate-token|deactivate)
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
    dm)            cmd_dm ;;
    rotate-token)  cmd_rotate_token ;;
    deactivate)    cmd_deactivate ;;
  esac
}

main "$@"
