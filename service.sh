#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="au-login-service"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/${SERVICE_NAME}"
SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="keepalive.sh"
USERNAME_FILE="username.txt"
PASSWORD_FILE="password.txt"

print_header() {
  echo
  echo "========================================"
  echo "   ${SERVICE_NAME} service manager"
  echo "========================================"
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

install_service() {
  require_root

  if [[ ! -f "${SCRIPT_SOURCE_DIR}/${RUN_SCRIPT}" ]]; then
    echo "Eksik dosya: ${RUN_SCRIPT}"
    exit 1
  fi

  echo "[1/5] ${INSTALL_DIR} olusturuluyor..."
  mkdir -p "${INSTALL_DIR}"

  echo "[2/5] keepalive betigi kopyalaniyor..."
  cp -f "${SCRIPT_SOURCE_DIR}/${RUN_SCRIPT}" "${INSTALL_DIR}/${RUN_SCRIPT}"
  chmod +x "${INSTALL_DIR}/${RUN_SCRIPT}"

  echo "[3/5] Credential dosyalari /opt altina kaydediliyor..."
  prompt_and_save_credentials "${INSTALL_DIR}"

  echo "[4/5] systemd unit yaziliyor: ${UNIT_FILE}"
  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=AU OAuth Login Keepalive Service
After=NetworkManager.service network-online.target
Wants=network-online.target NetworkManager-wait-online.service

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
  rm -f "${SCRIPT_SOURCE_DIR}/${USERNAME_FILE}" "${SCRIPT_SOURCE_DIR}/${PASSWORD_FILE}"

  echo "[5/5] daemon-reload..."
  systemctl daemon-reload

  echo "Kaldirma tamamlandi."
}

update_credentials() {
  require_root

  prompt_and_save_credentials "${INSTALL_DIR}"
  echo "Credential dosyalari /opt altinda guncellendi."

  if systemctl list-unit-files | rg -q "^${SERVICE_NAME}\\.service"; then
    systemctl restart "${SERVICE_NAME}" || true
    echo "Servis yeniden baslatildi."
  fi
}

service_status() {
  if systemctl list-unit-files | rg -q "^${SERVICE_NAME}\\.service"; then
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
    echo "5) Cikis"
    echo
    read -r -p "Seciminiz (1-5): " choice

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
        echo "Cikis yapildi."
        exit 0
        ;;
      *)
        echo "Gecersiz secim. 1-5 arasinda bir deger girin."
        ;;
    esac

    echo
    read -r -p "Menuye donmek icin Enter tusuna basin..."
  done
}

main_menu
