#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERNAME_FILE="${USERNAME_FILE:-$SCRIPT_DIR/username.txt}"
PASSWORD_FILE="${PASSWORD_FILE:-$SCRIPT_DIR/password.txt}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-${INTERVAL_SECONDS:-60}}"
LOGIN_THRESHOLD_SECONDS="${LOGIN_THRESHOLD_SECONDS:-18000}"
PING_HOST="${PING_HOST:-internet.amasya.edu.tr}"
NETWORK_RETRY_SECONDS="${NETWORK_RETRY_SECONDS:-15}"
BASE_URL="${BASE_URL:-https://internet.amasya.edu.tr:8000}"
LOGIN_ENDPOINT="${LOGIN_ENDPOINT:-/api/v1/auth/login}"
CHECK_ENDPOINT="${CHECK_ENDPOINT:-/api/v1/auth/check-ip}"
LOG_PREFIX="${LOG_PREFIX:-[au-login-keepalive]}"
NETWORK_BACKEND="unknown"
NETWORK_BACKEND_REASON="not-detected"
VPN_ENABLED="${VPN_ENABLED:-false}"
VPN_SERVER="${VPN_SERVER:-}"
VPN_PROTOCOL="${VPN_PROTOCOL:-anyconnect}"
VPN_SERVERCERT="${VPN_SERVERCERT:-}"
VPN_USERNAME_FILE="${VPN_USERNAME_FILE:-}"
VPN_PASSWORD_FILE="${VPN_PASSWORD_FILE:-}"
VPN_PID_FILE="${VPN_PID_FILE:-/run/openconnect-au.pid}"

if ! command -v curl >/dev/null 2>&1; then
  echo "$LOG_PREFIX curl is required but not found. Install curl and retry." >&2
  exit 1
fi

if [[ ! -f "$USERNAME_FILE" ]]; then
  echo "$LOG_PREFIX Username file not found: $USERNAME_FILE" >&2
  exit 1
fi

if [[ ! -f "$PASSWORD_FILE" ]]; then
  echo "$LOG_PREFIX Password file not found: $PASSWORD_FILE" >&2
  exit 1
fi

if ! [[ "$CHECK_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$CHECK_INTERVAL_SECONDS" -lt 60 ]]; then
  echo "$LOG_PREFIX CHECK_INTERVAL_SECONDS must be an integer >= 60" >&2
  exit 1
fi

if ! [[ "$LOGIN_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] || [[ "$LOGIN_THRESHOLD_SECONDS" -lt 60 ]]; then
  echo "$LOG_PREFIX LOGIN_THRESHOLD_SECONDS must be an integer >= 60" >&2
  exit 1
fi

if ! [[ "$NETWORK_RETRY_SECONDS" =~ ^[0-9]+$ ]] || [[ "$NETWORK_RETRY_SECONDS" -lt 5 ]]; then
  echo "$LOG_PREFIX NETWORK_RETRY_SECONDS must be an integer >= 5" >&2
  exit 1
fi

if [[ "$VPN_ENABLED" == "true" ]]; then
  if [[ -z "$VPN_SERVER" ]]; then
    echo "$LOG_PREFIX VPN_SERVER must be set when VPN_ENABLED=true" >&2
    exit 1
  fi
  if [[ ! -f "$VPN_USERNAME_FILE" ]]; then
    echo "$LOG_PREFIX VPN username file not found: $VPN_USERNAME_FILE" >&2
    exit 1
  fi
  if [[ ! -f "$VPN_PASSWORD_FILE" ]]; then
    echo "$LOG_PREFIX VPN password file not found: $VPN_PASSWORD_FILE" >&2
    exit 1
  fi
fi

read_secret_value() {
  local file_path="$1"
  tr -d '\r\n' < "$file_path"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

detect_network_backend() {
  local nmcli_available=0
  local networkctl_available=0
  local nm_active=0
  local networkd_active=0

  if has_command nmcli; then
    nmcli_available=1
  fi

  if has_command networkctl; then
    networkctl_available=1
  fi

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    nm_active=1
  fi

  if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    networkd_active=1
  fi

  if [[ "$nm_active" -eq 1 && "$nmcli_available" -eq 1 ]]; then
    NETWORK_BACKEND="networkmanager"
    NETWORK_BACKEND_REASON="NetworkManager active"
  elif [[ "$networkd_active" -eq 1 && "$networkctl_available" -eq 1 ]]; then
    NETWORK_BACKEND="networkd"
    NETWORK_BACKEND_REASON="systemd-networkd active"
  elif [[ "$nmcli_available" -eq 1 ]]; then
    NETWORK_BACKEND="networkmanager"
    NETWORK_BACKEND_REASON="nmcli available"
  elif [[ "$networkctl_available" -eq 1 ]]; then
    NETWORK_BACKEND="networkd"
    NETWORK_BACKEND_REASON="networkctl available"
  else
    NETWORK_BACKEND="unknown"
    NETWORK_BACKEND_REASON="neither tool found"
  fi
}

get_wireless_interface() {
  local iface

  if has_command iw; then
    iface="$(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2; exit }')"
    if [[ -n "$iface" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  fi

  if has_command networkctl; then
    iface="$(networkctl --no-legend --no-pager list 2>/dev/null | awk '$2 ~ /^wl/ { print $2; exit }')"
    if [[ -n "$iface" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  fi

  # Fallback: herhangi bir araç olmadan /sys/class/net/ üzerinden kablosuz arayüz tespiti
  local net_dir
  for net_dir in /sys/class/net/*/; do
    iface="$(basename "$net_dir")"
    if [[ -d "${net_dir}wireless" ]] || [[ -d "${net_dir}phy80211" ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  done
}

escape_json_string() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/}"
  raw="${raw//$'\r'/}"
  printf '%s' "$raw"
}

build_login_payload() {
  local username password
  username="$(read_secret_value "$USERNAME_FILE")"
  password="$(read_secret_value "$PASSWORD_FILE")"

  if [[ -z "$username" || -z "$password" ]]; then
    echo "$LOG_PREFIX Username/Password value is empty." >&2
    return 1
  fi

  printf '{"username":"%s","password":"%s","user_type":"student"}' \
    "$(escape_json_string "$username")" \
    "$(escape_json_string "$password")"
}

run_check_ip_request() {
  curl -sS "${BASE_URL}${CHECK_ENDPOINT}" \
    -H 'Accept: application/json, text/plain, */*' \
    -H 'Accept-Language: tr' \
    -H 'Connection: keep-alive' \
    -H 'Origin: https://internet.amasya.edu.tr' \
    -H 'Referer: https://internet.amasya.edu.tr/' \
    -H 'Sec-Fetch-Dest: empty' \
    -H 'Sec-Fetch-Mode: cors' \
    -H 'Sec-Fetch-Site: same-site' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 OPR/130.0.0.0' \
    -H 'sec-ch-ua: "Chromium";v="146", "Not-A.Brand";v="24", "Opera";v="130"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Linux"'
}

run_login() {
  local payload
  local now

  now="$(date '+%Y-%m-%d %H:%M:%S')"

  # Only run login if connected to AmasyaUniversitesi network
  if ! is_connected_to_amasya_network; then
    local ssid
    ssid="$(get_current_wifi_ssid)"
    echo "$LOG_PREFIX [$now] Not connected to AmasyaUniversitesi network (connected to: ${ssid:-unknown}). Skipping login."
    return 0
  fi

  [[ "$VPN_ENABLED" == "true" ]] && disconnect_vpn

  payload="$(build_login_payload)" || {
    echo "$LOG_PREFIX [$now] Login payload could not be built." >&2
    return 1
  }

  echo "$LOG_PREFIX [$now] Sending login request..."

  if curl -sS "${BASE_URL}${LOGIN_ENDPOINT}" \
    -H 'Accept: application/json, text/plain, */*' \
    -H 'Accept-Language: tr' \
    -H 'Connection: keep-alive' \
    -H 'Content-Type: application/json' \
    -H 'Origin: https://internet.amasya.edu.tr' \
    -H 'Referer: https://internet.amasya.edu.tr/' \
    -H 'Sec-Fetch-Dest: empty' \
    -H 'Sec-Fetch-Mode: cors' \
    -H 'Sec-Fetch-Site: same-site' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 OPR/130.0.0.0' \
    -H 'sec-ch-ua: "Chromium";v="146", "Not-A.Brand";v="24", "Opera";v="130"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Linux"' \
    --data-raw "$payload" >/dev/null; then
    echo "$LOG_PREFIX [$now] Login request completed."
    # Sync system time after successful login
    sleep 2
    sync_system_time
  else
    echo "$LOG_PREFIX [$now] Login request failed." >&2
  fi
}

run_logout() {
  [[ "$VPN_ENABLED" == "true" ]] && disconnect_vpn

  local now

  now="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$LOG_PREFIX [$now] Sending logout request..."

  if curl -sS "${BASE_URL}/api/v1/auth/logout" \
    -X POST \
    -H 'Accept: application/json, text/plain, */*' \
    -H 'Accept-Language: tr' \
    -H 'Connection: keep-alive' \
    -H 'Content-Length: 0' \
    -H 'Origin: https://internet.amasya.edu.tr' \
    -H 'Referer: https://internet.amasya.edu.tr/' \
    -H 'Sec-Fetch-Dest: empty' \
    -H 'Sec-Fetch-Mode: cors' \
    -H 'Sec-Fetch-Site: same-site' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 OPR/130.0.0.0' \
    -H 'sec-ch-ua: "Chromium";v="146", "Not-A.Brand";v="24", "Opera";v="130"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Linux"' >/dev/null; then
    echo "$LOG_PREFIX [$now] Logout request completed."
  else
    echo "$LOG_PREFIX [$now] Logout request failed." >&2
  fi
}

sync_system_time() {
  local now
  local wifi_ssid
  local target_host
  local date_header
  local parsed_time

  now="$(date '+%Y-%m-%d %H:%M:%S')"

  # Aktif backend'e gore SSID tespit et.
  wifi_ssid="$(get_current_wifi_ssid)"

  if [[ "$wifi_ssid" == "AmasyaUniversitesi" ]]; then
    target_host="internet.amasya.edu.tr"
  else
    target_host="google.com"
  fi

  echo "$LOG_PREFIX [$now] Syncing system time from ${target_host}..."

  # HTTP Date header'ını al
  date_header="$(curl -sI "https://${target_host}" 2>/dev/null | grep -i '^date:' | sed 's/^[dD]ate: //' | tr -d '\r')" || true

  if [[ -z "$date_header" ]]; then
    echo "$LOG_PREFIX [$now] Could not fetch Date header from ${target_host}. Skipping time sync." >&2
    return 1
  fi

  # Date header'ını parse et ve sistem zamanını ayarla
  parsed_time="$(date -d "$date_header" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || {
    echo "$LOG_PREFIX [$now] Could not parse Date header: $date_header" >&2
    return 1
  }

  echo "$LOG_PREFIX [$now] Setting system time to: ${parsed_time}"

  if timedatectl set-ntp false 2>/dev/null && \
     timedatectl set-time "$parsed_time" 2>/dev/null; then
    echo "$LOG_PREFIX [$now] System time synchronized successfully."
  else
    echo "$LOG_PREFIX [$now] Failed to set system time. (May require root privileges)" >&2
    return 1
  fi
}

randomize_reconnect_interval() {
  # 2 saat = 7200 saniye, 5 saat = 18000 saniye
  local min_seconds=7200
  local max_seconds=18000
  local random_offset

  random_offset=$((RANDOM % (max_seconds - min_seconds + 1) + min_seconds))
  NEXT_RECONNECT_TIME=$(($(date +%s) + random_offset))

  local hours=$((random_offset / 3600))
  local minutes=$((random_offset % 3600 / 60))

  echo "$LOG_PREFIX Random reconnect scheduled in ${hours}h ${minutes}m"
}

logout_and_login() {
  run_logout
  
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  
  echo "$LOG_PREFIX [$now] Waiting 2 seconds before login..."
  sleep 2
  
  run_login
}

extract_timeout() {
  local response="$1"
  local timeout
  timeout="$(sed -nE 's/.*"timeout"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<< "$response")"

  if [[ -n "$timeout" ]]; then
    printf '%s\n' "$timeout"
  fi
}

extract_status() {
  local response="$1"
  local status
  status="$(sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<< "$response")"

  if [[ -n "$status" ]]; then
    printf '%s\n' "$status"
  fi
}

network_ready() {
  ping -c 1 -W 2 "$PING_HOST" >/dev/null 2>&1
}

wait_for_network() {
  local now
  while ! network_ready; do
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "$LOG_PREFIX [$now] Network not ready (ping ${PING_HOST} failed). Waiting ${NETWORK_RETRY_SECONDS}s..."
    sleep "$NETWORK_RETRY_SECONDS"
  done
}

get_current_wifi_ssid() {
  local ssid=""
  local wifi_iface=""

  case "$NETWORK_BACKEND" in
    networkmanager)
      ssid="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1 == "yes" { print $2; exit }')"
      ;;
    networkd)
      if has_command iwgetid; then
        ssid="$(iwgetid -r 2>/dev/null || true)"
      fi

      if [[ -z "$ssid" ]] && has_command iw; then
        wifi_iface="$(get_wireless_interface)"
        if [[ -n "$wifi_iface" ]]; then
          ssid="$(iw dev "$wifi_iface" link 2>/dev/null | sed -nE 's/^[[:space:]]*SSID:[[:space:]]*(.*)$/\1/p' | head -n 1)"
        fi
      fi
      ;;
    *)
      if has_command iwgetid; then
        ssid="$(iwgetid -r 2>/dev/null || true)"
      fi

      if [[ -z "$ssid" ]] && has_command iw; then
        wifi_iface="$(get_wireless_interface)"
        if [[ -n "$wifi_iface" ]]; then
          ssid="$(iw dev "$wifi_iface" link 2>/dev/null | sed -nE 's/^[[:space:]]*SSID:[[:space:]]*(.*)$/\1/p' | head -n 1)"
        fi
      fi
      ;;
  esac

  printf '%s\n' "$ssid"
}

is_connected_to_amasya_network() {
  local current_ssid
  current_ssid="$(get_current_wifi_ssid)"
  [[ "$current_ssid" == "AmasyaUniversitesi" ]]
}

vpn_is_connected() {
  [[ -f "$VPN_PID_FILE" ]] && kill -0 "$(cat "$VPN_PID_FILE")" 2>/dev/null
}

connect_vpn() {
  local now vpn_username vpn_password extra_args
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  if ! has_command openconnect; then
    echo "$LOG_PREFIX [$now] openconnect not found. Skipping VPN connection." >&2
    return 1
  fi

  if vpn_is_connected; then
    echo "$LOG_PREFIX [$now] VPN already connected (pid: $(cat "$VPN_PID_FILE"))."
    return 0
  fi

  vpn_username="$(read_secret_value "$VPN_USERNAME_FILE")"
  vpn_password="$(read_secret_value "$VPN_PASSWORD_FILE")"

  if [[ -z "$vpn_username" || -z "$vpn_password" ]]; then
    echo "$LOG_PREFIX [$now] VPN credentials are empty. Skipping." >&2
    return 1
  fi

  echo "$LOG_PREFIX [$now] Connecting to VPN: ${VPN_SERVER} (protocol: ${VPN_PROTOCOL})..."

  extra_args=()
  if [[ -n "$VPN_SERVERCERT" ]]; then
    extra_args+=("--servercert=${VPN_SERVERCERT}")
  fi

  if printf '%s\n' "$vpn_password" | openconnect \
      --user="$vpn_username" \
      --passwd-on-stdin \
      --background \
      --pid-file="$VPN_PID_FILE" \
      --protocol="$VPN_PROTOCOL" \
      "${extra_args[@]}" \
      "$VPN_SERVER" >/dev/null 2>&1; then
    echo "$LOG_PREFIX [$now] VPN connected."
  else
    echo "$LOG_PREFIX [$now] VPN connection failed." >&2
    return 1
  fi
}

disconnect_vpn() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  if ! vpn_is_connected; then
    return 0
  fi

  echo "$LOG_PREFIX [$now] Disconnecting VPN..."
  kill "$(cat "$VPN_PID_FILE")" 2>/dev/null || true
  rm -f "$VPN_PID_FILE"
  echo "$LOG_PREFIX [$now] VPN disconnected."
}

manage_vpn() {
  [[ "$VPN_ENABLED" != "true" ]] && return 0

  if is_connected_to_amasya_network; then
    connect_vpn
  else
    disconnect_vpn
  fi
}

manage_tailscaled_service() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  echo "$LOG_PREFIX [$now] Managing tailscaled service..."

  if systemctl is-active --quiet tailscaled 2>/dev/null; then
    echo "$LOG_PREFIX [$now] Restarting tailscaled service..."
    systemctl restart tailscaled 2>/dev/null || {
      echo "$LOG_PREFIX [$now] Failed to restart tailscaled (may require root privileges)" >&2
    }
  else
    echo "$LOG_PREFIX [$now] Starting tailscaled service..."
    systemctl start tailscaled 2>/dev/null || {
      echo "$LOG_PREFIX [$now] Failed to start tailscaled (may require root privileges)" >&2
    }
  fi

  sleep 1
  if systemctl is-active --quiet tailscaled 2>/dev/null; then
    echo "$LOG_PREFIX [$now] tailscaled service is now active."
  else
    echo "$LOG_PREFIX [$now] tailscaled service is not running (may not be installed)" >&2
  fi
}

initial_setup() {
  echo "$LOG_PREFIX Initial setup: syncing time and checking network..."

  sync_system_time

  if is_connected_to_amasya_network; then
    echo "$LOG_PREFIX Connected to AmasyaUniversitesi network. Performing initial login..."
    run_login
    manage_vpn
  else
    local ssid
    ssid="$(get_current_wifi_ssid)"
    echo "$LOG_PREFIX Not connected to AmasyaUniversitesi network (connected to: ${ssid:-unknown}). Skipping initial login."
  fi

  manage_tailscaled_service
  randomize_reconnect_interval
}

echo "$LOG_PREFIX Starting keepalive loop."
echo "$LOG_PREFIX Username file: $USERNAME_FILE"
echo "$LOG_PREFIX Password file: $PASSWORD_FILE"
echo "$LOG_PREFIX Ping host: $PING_HOST"
echo "$LOG_PREFIX Check interval: ${CHECK_INTERVAL_SECONDS}s"
echo "$LOG_PREFIX Login threshold: ${LOGIN_THRESHOLD_SECONDS}s"
echo "$LOG_PREFIX Network retry: ${NETWORK_RETRY_SECONDS}s"

detect_network_backend
echo "$LOG_PREFIX Network backend: ${NETWORK_BACKEND} (${NETWORK_BACKEND_REASON})"
echo "$LOG_PREFIX VPN enabled: ${VPN_ENABLED}"
if [[ "$VPN_ENABLED" == "true" ]]; then
  echo "$LOG_PREFIX VPN server: ${VPN_SERVER}"
  echo "$LOG_PREFIX VPN protocol: ${VPN_PROTOCOL}"
fi

# Initialize next reconnect time
NEXT_RECONNECT_TIME=0

echo "$LOG_PREFIX Waiting for network..."
wait_for_network

initial_setup

while true; do
  NOW="$(date '+%Y-%m-%d %H:%M:%S')"
  if ! network_ready; then
    echo "$LOG_PREFIX [$NOW] Network lost. Waiting until network is reachable..."
    [[ "$VPN_ENABLED" == "true" ]] && disconnect_vpn
    wait_for_network
  fi

  echo "$LOG_PREFIX [$NOW] Checking current session status..."

  CHECK_RESPONSE="$(run_check_ip_request 2>/dev/null || true)"
  STATUS_VALUE="$(extract_status "$CHECK_RESPONSE")"
  TIMEOUT_VALUE="$(extract_timeout "$CHECK_RESPONSE")"

  if [[ "$STATUS_VALUE" != "active" ]]; then
    echo "$LOG_PREFIX [$NOW] Session status is '${STATUS_VALUE:-unknown}'. Running login."
    run_login
    randomize_reconnect_interval
  elif [[ -z "$TIMEOUT_VALUE" ]]; then
    echo "$LOG_PREFIX [$NOW] Timeout could not be parsed. Keeping active session and skipping login."
  elif [[ "$TIMEOUT_VALUE" -lt 7200 ]]; then
    echo "$LOG_PREFIX [$NOW] Timeout is ${TIMEOUT_VALUE}s (< 2h). Refreshing session."
    run_login
    randomize_reconnect_interval
  else
    # Timeout >= 2 saat
    CURRENT_TIME=$(date +%s)
    if [[ $CURRENT_TIME -ge $NEXT_RECONNECT_TIME ]]; then
      echo "$LOG_PREFIX [$NOW] Random reconnect time reached. Timeout is ${TIMEOUT_VALUE}s. Performing random reconnect."
      logout_and_login
      randomize_reconnect_interval
    else
      SECONDS_UNTIL_RECONNECT=$((NEXT_RECONNECT_TIME - CURRENT_TIME))
      echo "$LOG_PREFIX [$NOW] Session active, timeout ${TIMEOUT_VALUE}s. Next random reconnect in ${SECONDS_UNTIL_RECONNECT}s."
    fi
  fi

  [[ "$VPN_ENABLED" == "true" ]] && manage_vpn

  sleep "$CHECK_INTERVAL_SECONDS"
done
