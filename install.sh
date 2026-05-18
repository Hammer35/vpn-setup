#!/bin/bash
# =============================================================
# Скрипт установки VPN-сервера на базе 3x-ui + XRay (VLESS+Reality)
# Совместимость: Ubuntu 22.04 / 24.04
# =============================================================

set -e

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[•]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# --- Проверка прав ---
[[ $EUID -ne 0 ]] && err "Скрипт нужно запускать от root. Войди через: ssh root@IP"

# --- Определяем IP сервера ---
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "================================================"
echo -e "${GREEN}   Установка VPN-сервера (VLESS + Reality)${NC}"
echo "================================================"
echo ""
info "IP этого сервера: $SERVER_IP"
echo ""

# --- Генерация случайных учётных данных ---
# Каждая установка уникальна — пароль и путь к панели генерируются случайно
ADMIN_USER="admin"
ADMIN_PASS=$(openssl rand -base64 12 | tr -d '/+=')
PANEL_PATH="/$(openssl rand -hex 6)/"
PANEL_PORT=2053
CLIENT_NAME="user1"

echo "================================================"
echo -e "${YELLOW}  ЭТАП 1/6 — Обновление системы${NC}"
echo "================================================"
info "Обновляем список пакетов..."
apt-get update -qq
info "Устанавливаем зависимости (curl, python3, openssl, sqlite3)..."
apt-get install -y -qq curl wget unzip python3 python3-pip sqlite3 openssl

# bcrypt нужен для хеширования пароля администратора
info "Устанавливаем библиотеку bcrypt для хеширования паролей..."
pip3 install bcrypt -q 2>/dev/null || pip install bcrypt -q 2>/dev/null || true
ok "Система готова"

echo ""
echo "================================================"
echo -e "${YELLOW}  ЭТАП 2/6 — Установка панели 3x-ui${NC}"
echo "================================================"
info "Скачиваем и устанавливаем панель управления 3x-ui..."
info "Это может занять 1-2 минуты..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "" || true

info "Останавливаем x-ui для настройки..."
systemctl stop x-ui 2>/dev/null || true
sleep 3
ok "3x-ui установлен"

echo ""
echo "================================================"
echo -e "${YELLOW}  ЭТАП 3/6 — Генерация ключей Reality${NC}"
echo "================================================"
# Reality — современный протокол маскировки, сложнее заблокировать чем обычный VPN
info "Генерируем уникальную пару ключей Reality (приватный + публичный)..."

# Ищем xray бинарник — путь может отличаться в зависимости от версии x-ui
XRAY_BIN=$(find /usr/local/x-ui/bin -name "xray-linux-*" 2>/dev/null | head -1)
[[ -z "$XRAY_BIN" ]] && XRAY_BIN=$(find /usr/local/x-ui -name "xray*" -type f 2>/dev/null | head -1)
[[ -z "$XRAY_BIN" ]] && err "Не нашёл xray бинарник. Убедись что 3x-ui установился корректно."

KEY_OUTPUT=$("$XRAY_BIN" x25519 2>/dev/null) || KEY_OUTPUT=""
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key:" | awk '{print $3}' || true)
PUBLIC_KEY=$(echo  "$KEY_OUTPUT" | grep "Public key:"  | awk '{print $3}' || true)

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "Не удалось сгенерировать Reality ключи. Бинарник: $XRAY_BIN\nВывод: $KEY_OUTPUT"
fi

ok "Ключи сгенерированы"

echo ""
echo "================================================"
echo -e "${YELLOW}  ЭТАП 4/6 — SSL сертификат${NC}"
echo "================================================"
# SSL нужен для шифрования панели управления
info "Устанавливаем acme.sh для автоматического выпуска сертификата..."
curl -sL https://get.acme.sh | bash -s email=vpn@example.com > /dev/null 2>&1 || true
export PATH="$PATH:/root/.acme.sh"

info "Запрашиваем SSL сертификат для IP $SERVER_IP..."
~/.acme.sh/acme.sh --register-account -m vpn@example.com 2>/dev/null || true

mkdir -p /root/cert/ip

if ~/.acme.sh/acme.sh --issue -d "$SERVER_IP" --standalone --keylength ec-256 2>/dev/null && \
   ~/.acme.sh/acme.sh --install-cert -d "$SERVER_IP" --ecc \
       --key-file       /root/cert/ip/privkey.pem \
       --fullchain-file /root/cert/ip/fullchain.pem 2>/dev/null; then
    ok "SSL сертификат выпущен и установлен"
else
    # Если выпуск сертификата не удался — создаём самоподписанный
    warn "Не удалось получить сертификат от Let's Encrypt/ZeroSSL"
    info "Создаём самоподписанный сертификат (браузер покажет предупреждение — это нормально)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout /root/cert/ip/privkey.pem \
        -out    /root/cert/ip/fullchain.pem \
        -days 3650 -nodes \
        -subj "/CN=$SERVER_IP" 2>/dev/null
    ok "Самоподписанный сертификат создан"
fi

echo ""
echo "================================================"
echo -e "${YELLOW}  ЭТАП 5/6 — Настройка панели и VPN${NC}"
echo "================================================"
info "Настраиваем базу данных x-ui..."
info "  — Создаём аккаунт администратора"
info "  — Задаём порт и секретный путь панели"
info "  — Создаём VPN подключение (VLESS + Reality)"

DB="/etc/x-ui/x-ui.db"

# Хешируем пароль (bcrypt, как требует x-ui)
HASHED_PASS=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$ADMIN_PASS', bcrypt.gensalt(10)).decode())" 2>/dev/null || echo "$ADMIN_PASS")

# Уникальные идентификаторы клиента
SHORT_ID=$(openssl rand -hex 4)
CLIENT_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
SUB_ID=$(openssl rand -hex 8)

python3 - <<PYEOF
import sqlite3, json

db = sqlite3.connect('$DB')

# Обновляем пароль администратора
db.execute("UPDATE users SET username=?, password=? WHERE id=1",
           ('$ADMIN_USER', '$HASHED_PASS'))

# Настройки панели
for key, val in {
    'webPort':      '$PANEL_PORT',
    'webBasePath':  '$PANEL_PATH',
    'webCertFile':  '/root/cert/ip/fullchain.pem',
    'webKeyFile':   '/root/cert/ip/privkey.pem',
}.items():
    db.execute("UPDATE settings SET value=? WHERE key=?", (val, key))

# Конфигурация VPN подключения (VLESS + XTLS-Reality)
inbound_settings = json.dumps({
    "clients": [{
        "id": "$CLIENT_UUID",
        "flow": "xtls-rprx-vision",
        "email": "$CLIENT_NAME",
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": True,
        "tgId": 0,
        "subId": "$SUB_ID",
        "comment": "",
        "reset": 0
    }],
    "decryption": "none",
    "encryption": "none"
})

stream_settings = json.dumps({
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
        "show": False,
        "xver": 0,
        "target": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"],
        "settings": {
            "publicKey": "$PUBLIC_KEY",
            "fingerprint": "chrome",
            "serverName": "",
            "spiderX": "/"
        }
    },
    "tcpSettings": {
        "acceptProxyProtocol": False,
        "header": {"type": "none"}
    }
})

sniffing = json.dumps({
    "enabled": True,
    "destOverride": ["http", "tls", "quic", "fakedns"]
})

db.execute("DELETE FROM inbounds")
db.execute("""
    INSERT INTO inbounds
    (user_id, up, down, total, remark, enable, expiry_time, listen, port,
     protocol, settings, stream_settings, tag, sniffing)
    VALUES (1, 0, 0, 0, 'VPN', 1, 0, '', 443, 'vless', ?, ?, 'inbound-443', ?)
""", (inbound_settings, stream_settings, sniffing))

db.commit()
db.close()
PYEOF

ok "Настройка завершена"

echo ""
echo "================================================"
echo -e "${YELLOW}  ЭТАП 6/6 — Запуск сервера${NC}"
echo "================================================"
info "Запускаем x-ui и XRay..."
systemctl start x-ui
sleep 4

# Проверяем что всё запустилось
if systemctl is-active --quiet x-ui; then
    ok "x-ui запущен и работает"
else
    warn "x-ui не запустился — проверь логи: journalctl -u x-ui -n 50"
fi

# Формируем VPN ссылку для импорта в клиент (v2rayN, Hiddify и др.)
VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VPN-${SERVER_IP}"

echo ""
echo "================================================"
echo -e "${GREEN}       ВСЁ ГОТОВО! СОХРАНИ ДАННЫЕ!${NC}"
echo "================================================"
echo ""
echo -e "${YELLOW}  Панель управления VPN:${NC}"
echo "  https://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}"
echo ""
echo -e "${YELLOW}  Логин:${NC}  $ADMIN_USER"
echo -e "${YELLOW}  Пароль:${NC} $ADMIN_PASS"
echo ""
echo -e "${YELLOW}  VPN ссылка — скопируй в v2rayN / Hiddify:${NC}"
echo ""
echo "  $VLESS_LINK"
echo ""
echo "================================================"
echo -e "${RED}  ВАЖНО: Сохрани эти данные сейчас!${NC}"
echo -e "${RED}  После закрытия окна они не будут показаны!${NC}"
echo "================================================"
echo ""
