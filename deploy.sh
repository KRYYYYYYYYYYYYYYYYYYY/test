#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Automated Xray client deployment script
# Downloads ech.dat, prompts for credentials, patches config.json,
# validates with xray -test, and restarts the xray service.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
ECH_URL="https://github.com/Akiyamov/singbox-ech-list/releases/latest/download/ech.dat"
REPO_URL_SINGLE="https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/config.json"
REPO_URL_DUAL="https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/config-dual.json"

echo -e "${CYAN}=======================================${NC}"
echo -e "${CYAN}  Xray Stability Config — Deployment   ${NC}"
echo -e "${CYAN}=======================================${NC}"
echo ""

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root (sudo).${NC}"
    exit 1
fi

# --- Check xray installed ---
if ! command -v xray &>/dev/null; then
    echo -e "${YELLOW}[INFO] Xray not found. Installing latest version...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    echo ""
fi

XRAY_VER=$(xray version 2>/dev/null | head -1 || echo "unknown")
echo -e "${GREEN}[OK] Xray: ${XRAY_VER}${NC}"

# --- Step 1: Download ech.dat ---
echo ""
echo -e "${CYAN}[1/5] Downloading ech.dat (ECH domain database)...${NC}"
mkdir -p "${XRAY_ASSET_DIR}"
if wget -qO "${XRAY_ASSET_DIR}/ech.dat" "${ECH_URL}"; then
    ECH_SIZE=$(du -h "${XRAY_ASSET_DIR}/ech.dat" | cut -f1)
    echo -e "${GREEN}[OK] ech.dat downloaded (${ECH_SIZE}) → ${XRAY_ASSET_DIR}/ech.dat${NC}"
else
    echo -e "${YELLOW}[WARN] Failed to download ech.dat. ECH routing will not work.${NC}"
    echo -e "${YELLOW}       You can download it manually later.${NC}"
fi

# --- Also ensure geoip.dat and geosite.dat exist ---
for geo in geoip.dat geosite.dat; do
    if [[ ! -f "${XRAY_ASSET_DIR}/${geo}" ]]; then
        # Try to copy from xray binary directory
        for src_dir in /usr/local/bin /usr/bin /usr/share/xray; do
            if [[ -f "${src_dir}/${geo}" ]]; then
                cp "${src_dir}/${geo}" "${XRAY_ASSET_DIR}/${geo}"
                echo -e "${GREEN}[OK] ${geo} copied from ${src_dir}${NC}"
                break
            fi
        done
    fi
done

# --- Step 2: Choose config mode ---
echo ""
echo -e "${CYAN}[2/6] Choose deployment mode:${NC}"
echo ""
echo -e "  ${GREEN}1)${NC} xHTTP only (single outbound, Cloudflare Worker or direct)"
echo -e "  ${GREEN}2)${NC} Reality + xHTTP DUAL (auto-failover: Reality primary, xHTTP fallback)"
echo ""
read -rp "    Choose mode [1/2] (default: 1): " CONFIG_MODE
CONFIG_MODE=${CONFIG_MODE:-1}

if [[ "${CONFIG_MODE}" == "2" ]]; then
    REPO_URL="${REPO_URL_DUAL}"
    echo -e "${GREEN}[OK] Mode: DUAL (Reality + xHTTP failover)${NC}"
else
    REPO_URL="${REPO_URL_SINGLE}"
    echo -e "${GREEN}[OK] Mode: SINGLE (xHTTP only)${NC}"
fi

# --- Step 3: Prompt for credentials ---
echo ""
echo -e "${CYAN}[3/6] Enter your server credentials:${NC}"
echo ""

if [[ "${CONFIG_MODE}" == "2" ]]; then
    # Dual mode: need server IP, Worker URL, Reality keys
    read -rp "    Server IP (e.g., 87.242.119.137): " USER_SERVER_IP
    while [[ -z "${USER_SERVER_IP}" ]]; do
        echo -e "${RED}    Server IP cannot be empty.${NC}"
        read -rp "    Server IP: " USER_SERVER_IP
    done

    read -rp "    Cloudflare Worker URL (e.g., my-api.user.workers.dev): " USER_WORKER_URL
    while [[ -z "${USER_WORKER_URL}" ]]; do
        echo -e "${RED}    Worker URL cannot be empty.${NC}"
        read -rp "    Worker URL: " USER_WORKER_URL
    done

    read -rp "    Client UUID (from 3X-UI panel): " USER_UUID
    while [[ -z "${USER_UUID}" ]]; do
        echo -e "${RED}    UUID cannot be empty.${NC}"
        read -rp "    Client UUID: " USER_UUID
    done

    read -rp "    Secret path (from inbound, without leading /): " USER_PATH
    while [[ -z "${USER_PATH}" ]]; do
        echo -e "${RED}    Path cannot be empty.${NC}"
        read -rp "    Secret path: " USER_PATH
    done

    read -rp "    Reality public key (from 3X-UI): " USER_REALITY_PK
    while [[ -z "${USER_REALITY_PK}" ]]; do
        echo -e "${RED}    Public key cannot be empty.${NC}"
        read -rp "    Reality public key: " USER_REALITY_PK
    done

    read -rp "    Reality short ID (from 3X-UI): " USER_SHORT_ID
    while [[ -z "${USER_SHORT_ID}" ]]; do
        echo -e "${RED}    Short ID cannot be empty.${NC}"
        read -rp "    Reality short ID: " USER_SHORT_ID
    done

    echo ""
    echo -e "${GREEN}    Server IP:    ${USER_SERVER_IP}${NC}"
    echo -e "${GREEN}    Worker URL:   ${USER_WORKER_URL}${NC}"
    echo -e "${GREEN}    UUID:         ${USER_UUID}${NC}"
    echo -e "${GREEN}    Path:         /${USER_PATH}${NC}"
    echo -e "${GREEN}    Reality PK:   ${USER_REALITY_PK}${NC}"
    echo -e "${GREEN}    Short ID:     ${USER_SHORT_ID}${NC}"
else
    # Single mode: need domain, UUID, path
    read -rp "    Server domain (e.g., example.com): " USER_DOMAIN
    while [[ -z "${USER_DOMAIN}" ]]; do
        echo -e "${RED}    Domain cannot be empty.${NC}"
        read -rp "    Server domain: " USER_DOMAIN
    done

    read -rp "    Client UUID (from 3X-UI panel): " USER_UUID
    while [[ -z "${USER_UUID}" ]]; do
        echo -e "${RED}    UUID cannot be empty.${NC}"
        read -rp "    Client UUID: " USER_UUID
    done

    read -rp "    Secret path (from inbound, without leading /): " USER_PATH
    while [[ -z "${USER_PATH}" ]]; do
        echo -e "${RED}    Path cannot be empty.${NC}"
        read -rp "    Secret path: " USER_PATH
    done

    echo ""
    echo -e "${GREEN}    Domain: ${USER_DOMAIN}${NC}"
    echo -e "${GREEN}    UUID:   ${USER_UUID}${NC}"
    echo -e "${GREEN}    Path:   /${USER_PATH}${NC}"
fi
echo ""

# --- Step 4: Download and patch config.json ---
echo -e "${CYAN}[4/6] Downloading and patching config.json...${NC}"
mkdir -p "${XRAY_CONFIG_DIR}"

# Download the template config from the repo
if ! curl -sSfL "${REPO_URL}" -o "${XRAY_CONFIG}.template"; then
    echo -e "${RED}[ERROR] Failed to download config from repository.${NC}"
    echo -e "${RED}        URL: ${REPO_URL}${NC}"
    exit 1
fi

# Substitute placeholders based on mode
if [[ "${CONFIG_MODE}" == "2" ]]; then
    sed \
        -e "s|<SERVER_IP>|${USER_SERVER_IP}|g" \
        -e "s|<WORKER_URL>|${USER_WORKER_URL}|g" \
        -e "s|<YOUR_UUID>|${USER_UUID}|g" \
        -e "s|<SECRET_PATH>|${USER_PATH}|g" \
        -e "s|<REALITY_PUBLIC_KEY>|${USER_REALITY_PK}|g" \
        -e "s|<SHORT_ID>|${USER_SHORT_ID}|g" \
        "${XRAY_CONFIG}.template" > "${XRAY_CONFIG}"
else
    sed \
        -e "s|<SERVER_DOMAIN>|${USER_DOMAIN}|g" \
        -e "s|<YOUR_UUID>|${USER_UUID}|g" \
        -e "s|<SECRET_PATH>|${USER_PATH}|g" \
        "${XRAY_CONFIG}.template" > "${XRAY_CONFIG}"
fi

rm -f "${XRAY_CONFIG}.template"
echo -e "${GREEN}[OK] config.json patched → ${XRAY_CONFIG}${NC}"

# --- Step 5: Validate config ---
echo ""
echo -e "${CYAN}[5/6] Validating config with xray -test...${NC}"

export XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}"
if xray -test -config "${XRAY_CONFIG}" 2>&1; then
    echo -e "${GREEN}[OK] Configuration is valid!${NC}"
else
    echo -e "${RED}[ERROR] Configuration validation failed!${NC}"
    echo -e "${RED}        Check ${XRAY_CONFIG} for errors.${NC}"
    exit 1
fi

# --- Step 6: Restart xray service ---
echo ""
echo -e "${CYAN}[6/6] Restarting xray service...${NC}"

# Set XRAY_LOCATION_ASSET in the systemd service environment
SYSTEMD_ENV_DIR="/etc/systemd/system/xray.service.d"
mkdir -p "${SYSTEMD_ENV_DIR}"
cat > "${SYSTEMD_ENV_DIR}/asset-path.conf" <<EOF
[Service]
Environment="XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}"
EOF

systemctl daemon-reload

if systemctl restart xray 2>/dev/null; then
    echo -e "${GREEN}[OK] xray service restarted.${NC}"
elif systemctl restart xray.service 2>/dev/null; then
    echo -e "${GREEN}[OK] xray.service restarted.${NC}"
else
    echo -e "${YELLOW}[WARN] Could not restart xray service.${NC}"
    echo -e "${YELLOW}       You may need to restart it manually:${NC}"
    echo -e "${YELLOW}       systemctl restart xray${NC}"
fi

# --- Setup ech.dat auto-update cron ---
CRON_FILE="/etc/cron.d/ech-update"
if [[ ! -f "${CRON_FILE}" ]]; then
    echo ""
    echo -e "${CYAN}[+] Setting up ech.dat auto-update (every 12 hours)...${NC}"
    cat > "${CRON_FILE}" <<EOF
# Auto-update ECH domain database every 12 hours
0 */12 * * * root wget -qO ${XRAY_ASSET_DIR}/ech.dat ${ECH_URL} && systemctl restart xray 2>/dev/null
EOF
    chmod 644 "${CRON_FILE}"
    echo -e "${GREEN}[OK] Cron job created: ${CRON_FILE}${NC}"
fi

# --- Done ---
echo ""
echo -e "${CYAN}=======================================${NC}"
echo -e "${GREEN}  Deployment complete!${NC}"
echo -e "${CYAN}=======================================${NC}"
echo ""
echo -e "  Config:  ${XRAY_CONFIG}"
echo -e "  Assets:  ${XRAY_ASSET_DIR}/"
echo -e "  ECH DB:  ${XRAY_ASSET_DIR}/ech.dat"
echo ""
echo -e "${YELLOW}  Test connection:${NC}"
echo -e "  curl -x socks5h://127.0.0.1:10808 https://ifconfig.me"
echo ""
if [[ "${CONFIG_MODE}" == "2" ]]; then
    echo -e "${YELLOW}  Mode: DUAL (auto-failover)${NC}"
    echo -e "  Reality → primary (Wi-Fi, stable)"
    echo -e "  xHTTP   → fallback (mobile, TSPU blocks)"
    echo -e ""
    echo -e "${YELLOW}  burstObservatory pings every ~1 min.${NC}"
    echo -e "  If Reality is down, traffic auto-switches to xHTTP."
fi
echo ""
echo -e "${YELLOW}  Don't forget to configure server-side noise!${NC}"
echo -e "  Run on VPS: sudo bash -c \"\$(curl -sSfL https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/deploy-server.sh)\""
echo ""
