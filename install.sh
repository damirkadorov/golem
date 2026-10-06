#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Golem Provider Auto Installer
# Version: 1.0
# Provider image: golemfactory/provider:0.18.0
# ============================================================

GOLEM_VERSION="0.18.0"
INSTALL_DIR="/opt/golem"
CONTAINER="golem-provider"

# -----------------------------
# Настройки заработка
# -----------------------------
CPU_PRICE="0.009"
ENV_PRICE="0.001"
START_PRICE="0"

# Сколько оставляем системе
MIN_FREE_RAM_GIB="1.0"
MIN_FREE_DISK_GIB="10"

# -----------------------------
# Цвета
# -----------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo
echo "=============================================="
echo "     Golem Provider Auto Installer"
echo "     Version ${GOLEM_VERSION}"
echo "=============================================="
echo

# ============================================================
# ROOT
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    fail "Запусти скрипт от root."
fi

# ============================================================
# OS
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    fail "Не удалось определить ОС."
fi

source /etc/os-release

echo "OS: ${PRETTY_NAME:-unknown}"

case "${ID:-}" in
    ubuntu|debian)
        ok "Поддерживаемая ОС: ${PRETTY_NAME}"
        ;;
    *)
        fail "Поддерживаются Ubuntu/Debian. Обнаружено: ${ID:-unknown}"
        ;;
esac

# ============================================================
# ARCH
# ============================================================

ARCH="$(uname -m)"

if [[ "${ARCH}" != "x86_64" ]]; then
    fail "Нужна x86_64. Обнаружено: ${ARCH}"
fi

ok "Architecture: x86_64"

# ============================================================
# CPU
# ============================================================

CPU_COUNT="$(nproc)"

if (( CPU_COUNT < 2 )); then
    fail "Слишком мало CPU: ${CPU_COUNT}. Нужно минимум 2."
fi

ok "CPU: ${CPU_COUNT}"

# ============================================================
# VIRTUALIZATION
# ============================================================

VIRT_COUNT="$(grep -Ec '(vmx|svm)' /proc/cpuinfo || true)"

if (( VIRT_COUNT == 0 )); then
    fail "Nested virtualization недоступна: vmx/svm не обнаружен."
fi

ok "Nested virtualization: detected (${VIRT_COUNT} CPU flags)"

if [[ ! -e /dev/kvm ]]; then
    fail "/dev/kvm отсутствует. Этот VPS не подходит для Golem VM."
fi

ok "/dev/kvm exists"

# ============================================================
# RAM
# ============================================================

RAM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
RAM_GIB="$(awk "BEGIN {printf \"%.1f\", ${RAM_KIB}/1024/1024}")"

echo "RAM: ${RAM_GIB} GiB"

RAM_INT="$(awk "BEGIN {printf \"%d\", ${RAM_KIB}/1024/1024}")"

if (( RAM_INT < 3 )); then
    fail "Слишком мало RAM. Нужно минимум примерно 3 GiB."
fi

ok "RAM подходит"

# ============================================================
# DISK
# ============================================================

DISK_GIB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"

echo "Free disk: ${DISK_GIB} GiB"

if (( DISK_GIB < 20 )); then
    fail "Слишком мало свободного диска. Нужно минимум 20 GiB."
fi

ok "Disk подходит"

# ============================================================
# CALCULATE RESOURCES
# ============================================================

# Отдаём CPU - 1 системе
PROVIDER_CPU=$((CPU_COUNT - 1))

if (( PROVIDER_CPU < 1 )); then
    PROVIDER_CPU=1
fi

# RAM: оставляем примерно 1 GiB системе
PROVIDER_RAM="$(awk "BEGIN {
    r=${RAM_KIB}/1024/1024 - ${MIN_FREE_RAM_GIB};
    if (r > 12) r=12;
    if (r < 1.5) r=1.5;
    printf \"%.1f\", r;
}")"

# Disk: оставляем 10 GiB
PROVIDER_DISK=$((DISK_GIB - 10))

if (( PROVIDER_DISK > 100 )); then
    PROVIDER_DISK=100
fi

if (( PROVIDER_DISK < 10 )); then
    fail "Недостаточно диска после резерва."
fi

echo
echo "----------------------------------------------"
echo "Golem resources:"
echo "  CPU : ${PROVIDER_CPU}"
echo "  RAM : ${PROVIDER_RAM} GiB"
echo "  Disk: ${PROVIDER_DISK} GiB"
echo "----------------------------------------------"
echo

# ============================================================
# WALLET / PAYMENT ADDRESS
# ============================================================

ACCOUNT="${GOLEM_ACCOUNT:-}"

if [[ -z "${ACCOUNT}" ]]; then

    echo "Укажи общий Ethereum/GLM адрес для выплат."
    echo
    echo "Если хочешь новый адрес именно для этого VPS,"
    echo "просто нажми Enter."
    echo

    read -r -p "Golem payment address [Enter = internal wallet]: " ACCOUNT

fi

if [[ -n "${ACCOUNT}" ]]; then

    if [[ ! "${ACCOUNT}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        fail "Некорректный Ethereum address."
    fi

    ok "Payment address: ${ACCOUNT}"

else

    warn "Будет создан/использован internal Golem wallet этого VPS."

fi

# ============================================================
# DOCKER
# ============================================================

if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен"
else

    echo "Docker не найден. Устанавливаю..."

    if command -v apt-get >/dev/null 2>&1; then

        apt-get update -y
        apt-get install -y ca-certificates curl

        curl -fsSL https://get.docker.com | sh

        systemctl enable --now docker

    else
        fail "Не найден apt-get. Установи Docker вручную."
    fi

fi

if ! docker compose version >/dev/null 2>&1; then

    echo "Docker Compose plugin не найден."

    apt-get update -y
    apt-get install -y docker-compose-plugin

fi

ok "Docker Compose работает"

# ============================================================
# INSTALL DIRECTORY
# ============================================================

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# ============================================================
# DON'T DESTROY EXISTING VOLUMES
# ============================================================

if docker volume ls --format '{{.Name}}' | grep -qx 'golem_golem-yagna'; then
    warn "Existing golem_golem-yagna volume detected."
    warn "Wallet will NOT be deleted."
fi

if docker volume ls --format '{{.Name}}' | grep -qx 'golem_golem-provider'; then
    warn "Existing golem_golem-provider volume detected."
    warn "Provider data will NOT be deleted."
fi

# ============================================================
# NODE NAME
# ============================================================

HOSTNAME_VALUE="$(hostname -s | tr -cd 'A-Za-z0-9_-')"

if [[ -z "${HOSTNAME_VALUE}" ]]; then
    HOSTNAME_VALUE="vps"
fi

NODE_NAME="golem-${HOSTNAME_VALUE}"

# ============================================================
# COMPOSE
# ============================================================

cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  provider:
    image: golemfactory/provider:${GOLEM_VERSION}
    container_name: ${CONTAINER}
    command: ["golemsp", "run", "--no-interactive"]
    restart: unless-stopped
    network_mode: host

    devices:
      - /dev/kvm:/dev/kvm

    volumes:
      - golem-yagna:/root/.local/share/yagna
      - golem-provider:/root/.local/share/ya-provider

    environment:
      NODE_NAME: "${NODE_NAME}"
      YA_PAYMENT_NETWORK_GROUP: "mainnet"
      SUBNET: "public"
      YA_RT_CORES: "${PROVIDER_CPU}"
      YA_RT_MEM: "${PROVIDER_RAM}"
      YA_RT_STORAGE: "${PROVIDER_DISK}"
EOF

if [[ -n "${ACCOUNT}" ]]; then
cat >> "${INSTALL_DIR}/docker-compose.yml" <<EOF
      YA_ACCOUNT: "${ACCOUNT}"
EOF
fi

cat >> "${INSTALL_DIR}/docker-compose.yml" <<'EOF'

volumes:
  golem-yagna:
  golem-provider:
EOF

ok "docker-compose.yml created"

# ============================================================
# PULL IMAGE
# ============================================================

echo
echo "Downloading Golem Provider ${GOLEM_VERSION}..."

docker compose pull

ok "Golem image downloaded"

# ============================================================
# START
# ============================================================

echo
echo "Starting provider..."

docker compose up -d

sleep 15

# ============================================================
# APPLY PRICING
# ============================================================

echo
echo "Configuring pricing..."

docker compose exec -T provider \
    golemsp settings set \
    --cpu-per-hour "${CPU_PRICE}" \
    --env-per-hour "${ENV_PRICE}" \
    --starting-fee "${START_PRICE}" \
    >/dev/null

ok "Pricing configured"

# ============================================================
# RESTART AFTER SETTINGS
# ============================================================

docker compose restart >/dev/null

sleep 15

# ============================================================
# STATUS
# ============================================================

echo
echo "=============================================="
echo "             PROVIDER STATUS"
echo "=============================================="
echo

docker compose ps

echo

docker compose exec provider golemsp status || true

# ============================================================
# FINAL CHECK
# ============================================================

STATUS="$(docker compose exec -T provider golemsp status 2>/dev/null || true)"

if echo "${STATUS}" | grep -q "Service.*is running"; then
    ok "Provider service is running"
else
    warn "Provider service status could not be confirmed."
fi

if echo "${STATUS}" | grep -q "VM.*valid"; then
    ok "VM is valid"
else
    warn "VM is not yet reported as valid."
fi

if echo "${STATUS}" | grep -q "Driver.*Ok"; then
    ok "Driver is OK"
else
    warn "Driver status is not OK yet."
fi

echo
echo "=============================================="
echo "                 DONE"
echo "=============================================="
echo
echo "Provider directory:"
echo "  ${INSTALL_DIR}"
echo
echo "Node:"
echo "  ${NODE_NAME}"
echo
echo "Resources:"
echo "  CPU : ${PROVIDER_CPU}"
echo "  RAM : ${PROVIDER_RAM} GiB"
echo "  Disk: ${PROVIDER_DISK} GiB"
echo
echo "Price:"
echo "  CPU : ${CPU_PRICE} GLM / CPU-hour"
echo "  ENV : ${ENV_PRICE} GLM / hour"
echo
echo "Autostart:"
echo "  unless-stopped"
echo
echo "Useful commands:"
echo
echo "  cd ${INSTALL_DIR}"
echo "  docker compose exec provider golemsp status"
echo "  docker compose logs --tail=100 provider"
echo
echo "IMPORTANT:"
echo "  Do NOT run: docker compose down -v"
echo
