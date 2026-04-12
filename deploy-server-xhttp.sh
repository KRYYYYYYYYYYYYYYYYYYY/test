#!/usr/bin/env bash
# =============================================================================
# deploy-server-xhttp.sh — Automated xHTTP inbound creation for 3X-UI
# Creates a VLESS+xHTTP inbound via the 3X-UI API so Cloudflare Worker
# can proxy traffic to the server. Also runs deploy-server.sh for noise.
#
# One-liner:
#   sudo bash -c "$(curl -sSfL https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/deploy-server-xhttp.sh)"
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

COOKIE_FILE=$(mktemp)
trap "rm -f ${COOKIE_FILE}" EXIT

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  3X-UI: Automated xHTTP Inbound + Noise Setup        ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo ""

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root (sudo).${NC}"
    exit 1
fi

# --- Check dependencies ---
for cmd in curl jq openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}[+] Installing ${cmd}...${NC}"
        apt-get update -qq && apt-get install -y -qq "$cmd" >/dev/null 2>&1
    fi
done

# =========================================================================
# Step 1: Collect 3X-UI panel credentials
# =========================================================================
echo -e "${CYAN}[1/5] 3X-UI Panel credentials${NC}"
echo ""

read -rp "    Panel address (e.g., https://87.242.119.137:2053): " PANEL_URL
while [[ -z "${PANEL_URL}" ]]; do
    echo -e "${RED}    Panel address cannot be empty.${NC}"
    read -rp "    Panel address: " PANEL_URL
done
# Remove trailing slash
PANEL_URL="${PANEL_URL%/}"

# Detect panel base path (some setups use /panel prefix, some use custom path)
read -rp "    Panel base path (press Enter if none, e.g., /mysecretpath): " PANEL_BASE_PATH
PANEL_BASE_PATH="${PANEL_BASE_PATH%/}"

read -rp "    Panel username: " PANEL_USER
while [[ -z "${PANEL_USER}" ]]; do
    echo -e "${RED}    Username cannot be empty.${NC}"
    read -rp "    Panel username: " PANEL_USER
done

read -rsp "    Panel password: " PANEL_PASS
echo ""
while [[ -z "${PANEL_PASS}" ]]; do
    echo -e "${RED}    Password cannot be empty.${NC}"
    read -rsp "    Panel password: " PANEL_PASS
    echo ""
done

echo ""

# =========================================================================
# Step 2: Login to 3X-UI
# =========================================================================
echo -e "${CYAN}[2/5] Logging in to 3X-UI panel...${NC}"

LOGIN_RESP=$(curl -sk -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${PANEL_USER}&password=${PANEL_PASS}" \
    -c "${COOKIE_FILE}" \
    "${PANEL_URL}${PANEL_BASE_PATH}/login")

LOGIN_HTTP=$(echo "$LOGIN_RESP" | tail -1)
LOGIN_BODY=$(echo "$LOGIN_RESP" | head -n -1)
LOGIN_SUCCESS=$(echo "$LOGIN_BODY" | jq -r '.success // false' 2>/dev/null || echo "false")

if [[ "$LOGIN_SUCCESS" != "true" ]]; then
    echo -e "${RED}[ERROR] Login failed (HTTP ${LOGIN_HTTP}).${NC}"
    echo -e "${RED}        Response: ${LOGIN_BODY}${NC}"
    echo -e "${RED}        Check your credentials and panel URL.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Logged in successfully${NC}"

# =========================================================================
# Step 3: Collect xHTTP inbound parameters
# =========================================================================
echo ""
echo -e "${CYAN}[3/5] xHTTP Inbound configuration${NC}"
echo ""

# Generate random secret path
DEFAULT_PATH=$(openssl rand -hex 16)
read -rp "    Secret path (Enter for random: ${DEFAULT_PATH}): " XHTTP_PATH
XHTTP_PATH="${XHTTP_PATH:-${DEFAULT_PATH}}"

# Port
read -rp "    Inbound port (default: 8443): " XHTTP_PORT
XHTTP_PORT="${XHTTP_PORT:-8443}"

# UUID — reuse existing or generate new
read -rp "    UUID (Enter to reuse 48fd91f7-aaf1-4772-bb97-74880143bfff or paste new): " XHTTP_UUID
XHTTP_UUID="${XHTTP_UUID:-48fd91f7-aaf1-4772-bb97-74880143bfff}"

# Client email (identifier in 3X-UI)
DEFAULT_EMAIL="xhttp-worker-$(openssl rand -hex 4)"
read -rp "    Client email/tag (default: ${DEFAULT_EMAIL}): " CLIENT_EMAIL
CLIENT_EMAIL="${CLIENT_EMAIL:-${DEFAULT_EMAIL}}"

# Remark
read -rp "    Inbound name/remark (default: xhttp-cloudflare): " INBOUND_REMARK
INBOUND_REMARK="${INBOUND_REMARK:-xhttp-cloudflare}"

echo ""
echo -e "${GREEN}    Remark:  ${INBOUND_REMARK}${NC}"
echo -e "${GREEN}    Port:    ${XHTTP_PORT}${NC}"
echo -e "${GREEN}    UUID:    ${XHTTP_UUID}${NC}"
echo -e "${GREEN}    Path:    /${XHTTP_PATH}${NC}"
echo -e "${GREEN}    Email:   ${CLIENT_EMAIL}${NC}"
echo ""

# =========================================================================
# Step 4: Create xHTTP inbound via API
# =========================================================================
echo -e "${CYAN}[4/5] Creating xHTTP inbound...${NC}"

# Build the settings JSON (must be a JSON string inside the payload)
SETTINGS_JSON=$(jq -n -c \
    --arg uuid "$XHTTP_UUID" \
    --arg email "$CLIENT_EMAIL" \
    '{
        clients: [{
            id: $uuid,
            flow: "",
            email: $email,
            limitIp: 0,
            totalGB: 0,
            expiryTime: 0,
            enable: true,
            tgId: "",
            subId: ($uuid | split("-") | .[0]),
            reset: 0
        }],
        decryption: "none",
        fallbacks: []
    }')

# Build streamSettings JSON
STREAM_JSON=$(jq -n -c \
    --arg path "/${XHTTP_PATH}" \
    '{
        network: "xhttp",
        security: "none",
        externalProxy: [],
        xhttpSettings: {
            path: $path,
            host: "",
            mode: "auto",
            xPaddingBytes: "100-1000",
            xmux: {
                maxConcurrency: "16-32",
                cMaxReuseTimes: "64-128",
                hMaxRequestTimes: "600-900",
                hMaxReusableSecs: "1800-3000",
                hKeepAlivePeriod: 0
            },
            scMaxEachPostBytes: "500000-1000000",
            scMinPostsIntervalMs: "10-50",
            noGRPCHeader: false,
            noSSEHeader: false
        }
    }')

# Build sniffing JSON
SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

# Build allocate JSON
ALLOCATE_JSON='{"strategy":"always","refresh":5,"concurrency":3}'

# Build the full payload
PAYLOAD=$(jq -n -c \
    --arg remark "$INBOUND_REMARK" \
    --argjson port "$XHTTP_PORT" \
    --arg settings "$SETTINGS_JSON" \
    --arg stream "$STREAM_JSON" \
    --arg sniffing "$SNIFFING_JSON" \
    --arg allocate "$ALLOCATE_JSON" \
    --arg tag "inbound-${XHTTP_PORT}" \
    '{
        up: 0,
        down: 0,
        total: 0,
        remark: $remark,
        enable: true,
        expiryTime: 0,
        listen: "",
        port: $port,
        protocol: "vless",
        settings: $settings,
        streamSettings: $stream,
        tag: $tag,
        sniffing: $sniffing,
        allocate: $allocate
    }')

# Send the request
ADD_RESP=$(curl -sk -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -b "${COOKIE_FILE}" \
    -d "${PAYLOAD}" \
    "${PANEL_URL}${PANEL_BASE_PATH}/panel/api/inbounds/add")

ADD_HTTP=$(echo "$ADD_RESP" | tail -1)
ADD_BODY=$(echo "$ADD_RESP" | head -n -1)
ADD_SUCCESS=$(echo "$ADD_BODY" | jq -r '.success // false' 2>/dev/null || echo "false")

if [[ "$ADD_SUCCESS" != "true" ]]; then
    echo -e "${RED}[ERROR] Failed to create inbound (HTTP ${ADD_HTTP}).${NC}"
    ADD_MSG=$(echo "$ADD_BODY" | jq -r '.msg // "Unknown error"' 2>/dev/null || echo "$ADD_BODY")
    echo -e "${RED}        Message: ${ADD_MSG}${NC}"

    # Check if port conflict
    if echo "$ADD_MSG" | grep -qi "port\|already\|exist"; then
        echo -e "${YELLOW}[HINT] Port ${XHTTP_PORT} may already be in use. Try a different port.${NC}"
    fi
    exit 1
fi

# Extract inbound ID from response
INBOUND_ID=$(echo "$ADD_BODY" | jq -r '.obj.id // "?"' 2>/dev/null || echo "?")
echo -e "${GREEN}[OK] Inbound '${INBOUND_REMARK}' created (ID: ${INBOUND_ID})${NC}"

# =========================================================================
# Step 5: Run deploy-server.sh for noise injection
# =========================================================================
echo ""
echo -e "${CYAN}[5/5] Running server-side noise injection...${NC}"
echo ""

NOISE_SCRIPT_URL="https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/deploy-server.sh"
if curl -sSfL "${NOISE_SCRIPT_URL}" -o /tmp/deploy-server.sh 2>/dev/null; then
    bash /tmp/deploy-server.sh
    rm -f /tmp/deploy-server.sh
else
    echo -e "${YELLOW}[WARN] Could not download deploy-server.sh. Run it manually later:${NC}"
    echo -e "${YELLOW}       sudo bash -c \"\$(curl -sSfL ${NOISE_SCRIPT_URL})\"${NC}"
fi

# =========================================================================
# Done
# =========================================================================
echo ""
echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${CYAN}======================================================${NC}"
echo ""
echo -e "  ${GREEN}xHTTP Inbound created:${NC}"
echo -e "    Remark:    ${INBOUND_REMARK}"
echo -e "    Port:      ${XHTTP_PORT}"
echo -e "    UUID:      ${XHTTP_UUID}"
echo -e "    Path:      /${XHTTP_PATH}"
echo -e "    Inbound ID: ${INBOUND_ID}"
echo ""
echo -e "${CYAN}  Используй эти значения для deploy.sh (режим DUAL):${NC}"
echo ""
echo -e "    Server IP:    $(hostname -I | awk '{print $1}')"
echo -e "    Worker URL:   <твой-worker>.workers.dev"
echo -e "    UUID:         ${XHTTP_UUID}"
echo -e "    Secret path:  ${XHTTP_PATH}"
echo ""
echo -e "${CYAN}  Или клиентский one-liner:${NC}"
echo -e "  sudo bash -c \"\$(curl -sSfL https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/deploy.sh)\""
echo -e "  → Выбери режим 2 (DUAL)"
echo ""
echo -e "${YELLOW}  Важно: Security = none (TLS терминируется на Cloudflare).${NC}"
echo -e "${YELLOW}  Worker проксирует HTTPS → HTTP на порт ${XHTTP_PORT}.${NC}"
echo -e "${YELLOW}  Если нужен TLS на этом порту, настройте сертификат в 3X-UI.${NC}"
echo ""
