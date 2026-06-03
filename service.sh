#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="au-login-service"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/${SERVICE_NAME}"
SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="keepalive.sh"
USERNAME_FILE="username.txt"
PASSWORD_FILE="password.txt"
NETWORK_SERVICE=""
NETWORK_WAIT_SERVICE=""
VPN_USERNAME_FILE="vpn_username.txt"
VPN_PASSWORD_FILE="vpn_password.txt"
VPN_ENABLED_VALUE="false"
VPN_SERVER_VALUE=""
VPN_PROTOCOL_VALUE="anyconnect"
VPN_SERVERCERT_VALUE=""

print_header() {
  echo
  echo "========================================"
  echo "   ${SERVICE_NAME} service manager"
  echo "========================================"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

unit_exists() {
  local unit_name="$1"
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit_name"
}

detect_network_units() {
  NETWORK_SERVICE=""
  NETWORK_WAIT_SERVICE=""

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NETWORK_SERVICE="NetworkManager.service"
    if unit_exists "NetworkManager-wait-online.service"; then
      NETWORK_WAIT_SERVICE="NetworkManager-wait-online.service"
    fi
    return
  fi

  if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    NETWORK_SERVICE="systemd-networkd.service"
    if unit_exists "systemd-networkd-wait-online.service"; then
      NETWORK_WAIT_SERVICE="systemd-networkd-wait-online.service"
    fi
    return
  fi

  # Fallback: active service yoksa kurulu olana gore sec.
  if unit_exists "NetworkManager.service"; then
    NETWORK_SERVICE="NetworkManager.service"
    if unit_exists "NetworkManager-wait-online.service"; then
      NETWORK_WAIT_SERVICE="NetworkManager-wait-online.service"
    fi
    return
  fi

  if unit_exists "systemd-networkd.service"; then
    NETWORK_SERVICE="systemd-networkd.service"
    if unit_exists "systemd-networkd-wait-online.service"; then
      NETWORK_WAIT_SERVICE="systemd-networkd-wait-online.service"
    fi
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bu islem root yetkisi gerektirir. Lutfen sudo ile calistirin:"
    echo "sudo bash service.sh"
    exit 1
  fi
}

read_existing_value() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    tr -d '\r\n' < "$file_path"
  fi
}

prompt_and_save_credentials() {
  local target_dir="$1"
  local username_path="${target_dir}/${USERNAME_FILE}"
  local password_path="${target_dir}/${PASSWORD_FILE}"
  local existing_username existing_password username_input password_input

  mkdir -p "$target_dir"
  existing_username="$(read_existing_value "$username_path")"
  existing_password="$(read_existing_value "$password_path")"

  echo "OAuth bilgilerini girin (bos birakirsaniz mevcut deger korunur)."
  read -r -p "Username: " username_input
  read -r -s -p "Password: " password_input
  echo

  if [[ -z "$username_input" ]]; then
    username_input="$existing_username"
  fi

  if [[ -z "$password_input" ]]; then
    password_input="$existing_password"
  fi

  if [[ -z "$username_input" || -z "$password_input" ]]; then
    echo "Username/Password bos olamaz."
    exit 1
  fi

  printf '%s\n' "$username_input" > "$username_path"
  printf '%s\n' "$password_input" > "$password_path"
  chmod 600 "$username_path" "$password_path"
}

prompt_and_save_vpn_config() {
  local target_dir="$1"
  local vpn_username_path="${target_dir}/${VPN_USERNAME_FILE}"
  local vpn_password_path="${target_dir}/${VPN_PASSWORD_FILE}"
  local vpn_choice proto_choice vpn_username_input vpn_password_input

  echo
  read -r -p "OpenConnect VPN'i etkinlestirmek ister misiniz? (e/H): " vpn_choice
  if [[ "${vpn_choice,,}" != "e" ]]; then
    VPN_ENABLED_VALUE="false"
    echo "VPN atlanmistir."
    return 0
  fi

  VPN_ENABLED_VALUE="true"

  read -r -p "VPN sunucu adresi (ornek: vpn.amasya.edu.tr): " VPN_SERVER_VALUE
  if [[ -z "$VPN_SERVER_VALUE" ]]; then
    echo "VPN sunucu adresi bos olamaz."
    exit 1
  fi

  echo "VPN protokolu secin:"
  echo "  1) anyconnect (Cisco AnyConnect - varsayilan)"
  echo "  2) gp (GlobalProtect / Palo Alto)"
  echo "  3) nc (Juniper NetConnect)"
  echo "  4) pulse (Pulse Secure)"
  echo "  5) fortinet (Fortinet SSL VPN)"
  read -r -p "Secim (1-5, varsayilan 1): " proto_choice
  case "${proto_choice}" in
    2) VPN_PROTOCOL_VALUE="gp" ;;
    3) VPN_PROTOCOL_VALUE="nc" ;;
    4) VPN_PROTOCOL_VALUE="pulse" ;;
    5) VPN_PROTOCOL_VALUE="fortinet" ;;
    *) VPN_PROTOCOL_VALUE="anyconnect" ;;
  esac

  read -r -p "Sunucu sertifika parmak izi (bos birakilabilir, ornek: pin-sha256:...): " VPN_SERVERCERT_VALUE

  echo "VPN kimlik bilgilerini girin:"
  read -r -p "VPN Username: " vpn_username_input
  read -r -s -p "VPN Password: " vpn_password_input
  echo

  if [[ -z "$vpn_username_input" || -z "$vpn_password_input" ]]; then
    echo "VPN Username/Password bos olamaz."
    exit 1
  fi

  printf '%s\n' "$vpn_username_input" > "$vpn_username_path"
  printf '%s\n' "$vpn_password_input" > "$vpn_password_path"
  chmod 600 "$vpn_username_path" "$vpn_password_path"
  echo "VPN yapilandirmasi kaydedildi."
}

install_service() {
  require_root
  local after_line wants_line

  if [[ ! -f "${SCRIPT_SOURCE_DIR}/${RUN_SCRIPT}" ]]; then
    echo "Eksik dosya: ${RUN_SCRIPT}"
    exit 1
  fi

  echo "[1/5] ${INSTALL_DIR} olusturuluyor..."
  mkdir -p "${INSTALL_DIR}"

  echo "[2/5] keepalive betigi kopyalaniyor..."
  cp -f "${SCRIPT_SOURCE_DIR}/${RUN_SCRIPT}" "${INSTALL_DIR}/${RUN_SCRIPT}"
  chmod +x "${INSTALL_DIR}/${RUN_SCRIPT}"

  echo "[3/5] Credential ve VPN dosyalari /opt altina kaydediliyor..."
  prompt_and_save_credentials "${INSTALL_DIR}"
  prompt_and_save_vpn_config "${INSTALL_DIR}"

  detect_network_units

  after_line="After=network-online.target"
  wants_line="Wants=network-online.target"

  if [[ -n "$NETWORK_SERVICE" ]]; then
    after_line="After=${NETWORK_SERVICE} network-online.target"
  fi

  if [[ -n "$NETWORK_WAIT_SERVICE" ]]; then
    wants_line="Wants=network-online.target ${NETWORK_WAIT_SERVICE}"
  fi

  echo "Ağ backend secimi: ${NETWORK_SERVICE:-bilinmiyor}"
  echo "Bekleme servisi: ${NETWORK_WAIT_SERVICE:-yok}"

  echo "[4/5] systemd unit yaziliyor: ${UNIT_FILE}"
  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=AU OAuth Login Keepalive Service
${after_line}
${wants_line}

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/bin/bash ${INSTALL_DIR}/${RUN_SCRIPT}
Restart=always
RestartSec=15
StartLimitIntervalSec=0
Environment=CHECK_INTERVAL_SECONDS=60
Environment=LOGIN_THRESHOLD_SECONDS=18000
Environment=NETWORK_RETRY_SECONDS=15
Environment=PING_HOST=internet.amasya.edu.tr
Environment=USERNAME_FILE=${INSTALL_DIR}/${USERNAME_FILE}
Environment=PASSWORD_FILE=${INSTALL_DIR}/${PASSWORD_FILE}
Environment=VPN_ENABLED=${VPN_ENABLED_VALUE}
Environment=VPN_SERVER=${VPN_SERVER_VALUE}
Environment=VPN_PROTOCOL=${VPN_PROTOCOL_VALUE}
Environment=VPN_SERVERCERT=${VPN_SERVERCERT_VALUE}
Environment=VPN_USERNAME_FILE=${INSTALL_DIR}/${VPN_USERNAME_FILE}
Environment=VPN_PASSWORD_FILE=${INSTALL_DIR}/${VPN_PASSWORD_FILE}

[Install]
WantedBy=multi-user.target
EOF

  echo "[5/5] daemon-reload ve service enable/start..."
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

uninstall_service() {
  require_root

  echo "[1/5] Servis durduruluyor ve disable ediliyor..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

  echo "[2/5] Unit dosyasi siliniyor..."
  rm -f "${UNIT_FILE}"

  echo "[3/5] Kurulum klasoru siliniyor..."
  rm -rf "${INSTALL_DIR}"

  echo "[4/5] Yerel credential dosyalari siliniyor..."
  rm -f "${SCRIPT_SOURCE_DIR}/${USERNAME_FILE}" "${SCRIPT_SOURCE_DIR}/${PASSWORD_FILE}" \
        "${SCRIPT_SOURCE_DIR}/${VPN_USERNAME_FILE}" "${SCRIPT_SOURCE_DIR}/${VPN_PASSWORD_FILE}"

  echo "[5/5] daemon-reload..."
  systemctl daemon-reload

  echo "Kaldirma tamamlandi."
}

update_credentials() {
  require_root

  prompt_and_save_credentials "${INSTALL_DIR}"
  echo "Credential dosyalari /opt altinda guncellendi."

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
    systemctl restart "${SERVICE_NAME}" || true
    echo "Servis yeniden baslatildi."
  fi
}

update_vpn_credentials() {
  require_root

  local vpn_username_path="${INSTALL_DIR}/${VPN_USERNAME_FILE}"
  local vpn_password_path="${INSTALL_DIR}/${VPN_PASSWORD_FILE}"
  local existing_vpn_username existing_vpn_password vpn_username_input vpn_password_input

  existing_vpn_username="$(read_existing_value "$vpn_username_path")"
  existing_vpn_password="$(read_existing_value "$vpn_password_path")"

  echo "VPN kimlik bilgilerini girin (bos birakirsaniz mevcut deger korunur)."
  read -r -p "VPN Username: " vpn_username_input
  read -r -s -p "VPN Password: " vpn_password_input
  echo

  if [[ -z "$vpn_username_input" ]]; then
    vpn_username_input="$existing_vpn_username"
  fi

  if [[ -z "$vpn_password_input" ]]; then
    vpn_password_input="$existing_vpn_password"
  fi

  if [[ -z "$vpn_username_input" || -z "$vpn_password_input" ]]; then
    echo "VPN Username/Password bos olamaz."
    exit 1
  fi

  printf '%s\n' "$vpn_username_input" > "$vpn_username_path"
  printf '%s\n' "$vpn_password_input" > "$vpn_password_path"
  chmod 600 "$vpn_username_path" "$vpn_password_path"
  echo "VPN credential dosyalari /opt altinda guncellendi."

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
    systemctl restart "${SERVICE_NAME}" || true
    echo "Servis yeniden baslatildi."
  fi
}

service_status() {
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
    systemctl --no-pager --full status "${SERVICE_NAME}" || true
  else
    echo "Servis kayitli gorunmuyor: ${SERVICE_NAME}"
  fi
}

main_menu() {
  while true; do
    print_header
    echo "1) Kurulum yap ( /opt + systemd )"
    echo "2) Kurulumu kaldir"
    echo "3) Servis durumu"
    echo "4) Username/Password guncelle"
    echo "5) VPN Username/Password guncelle"
    echo "6) Cikis"
    echo
    read -r -p "Seciminiz (1-6): " choice

    case "${choice}" in
      1)
        install_service
        ;;
      2)
        uninstall_service
        ;;
      3)
        service_status
        ;;
      4)
        update_credentials
        ;;
      5)
        update_vpn_credentials
        ;;
      6)
        echo "Cikis yapildi."
        exit 0
        ;;
      *)
        echo "Gecersiz secim. 1-6 arasinda bir deger girin."
        ;;
    esac

    echo
    read -r -p "Menuye donmek icin Enter tusuna basin..."
  done
}

main_menu
