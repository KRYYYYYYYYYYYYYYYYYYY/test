#!/usr/bin/env bash
# =============================================================================
# deploy-cf-worker.sh — Automated Cloudflare Worker deployment for Xray proxy
# Creates a Worker, uploads cf-worker-proxy.js, sets BACKEND_HOST, deploys.
# Returns the Worker URL for use in config.json / config-dual.json.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

WORKER_SCRIPT_URL="https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/cf-worker-proxy.js"

echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}  Cloudflare Worker Proxy — Automated Deployment ${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""

# --- Step 1: Collect credentials ---
echo -e "${CYAN}[1/4] Credentials${NC}"
echo ""

if [[ -n "${CF_API_TOKEN:-}" ]]; then
    echo -e "${GREEN}[OK] CF_API_TOKEN found in environment${NC}"
else
    echo -e "${YELLOW}  Get your API token at: https://dash.cloudflare.com/profile/api-tokens${NC}"
    echo -e "${YELLOW}  Use template: 'Edit Cloudflare Workers'${NC}"
    echo ""
    read -rsp "    Cloudflare API Token: " CF_API_TOKEN
    echo ""
    while [[ -z "${CF_API_TOKEN}" ]]; do
        echo -e "${RED}    Token cannot be empty.${NC}"
        read -rsp "    Cloudflare API Token: " CF_API_TOKEN
        echo ""
    done
fi

if [[ -n "${CF_ACCOUNT_ID:-}" ]]; then
    echo -e "${GREEN}[OK] CF_ACCOUNT_ID found in environment${NC}"
else
    # Try to auto-detect Account ID from API
    echo -e "${YELLOW}[+] Auto-detecting Account ID...${NC}"
    AUTO_ACCOUNT=$(curl -s \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/accounts" \
        | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if len(r)==1 else '')" 2>/dev/null || echo "")
    
    if [[ -n "${AUTO_ACCOUNT}" ]]; then
        CF_ACCOUNT_ID="${AUTO_ACCOUNT}"
        echo -e "${GREEN}[OK] Account ID auto-detected: ${CF_ACCOUNT_ID}${NC}"
    else
        echo -e "${YELLOW}  Could not auto-detect. Enter manually.${NC}"
        echo -e "${YELLOW}  Find your Account ID on the Cloudflare Dashboard main page (bottom-right)${NC}"
        echo -e "${YELLOW}  or in the URL: dash.cloudflare.com/<ACCOUNT_ID>${NC}"
        echo ""
        read -rp "    Cloudflare Account ID: " CF_ACCOUNT_ID
        while [[ -z "${CF_ACCOUNT_ID}" ]]; do
            echo -e "${RED}    Account ID cannot be empty.${NC}"
            read -rp "    Cloudflare Account ID: " CF_ACCOUNT_ID
        done
    fi
fi

echo ""

# --- Verify token ---
echo -e "${CYAN}[+] Verifying API token...${NC}"
VERIFY_RESP=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify")
VERIFY_HTTP=$(echo "$VERIFY_RESP" | tail -1)
VERIFY_BODY=$(echo "$VERIFY_RESP" | head -n -1)

if [[ "$VERIFY_HTTP" != "200" ]]; then
    echo -e "${RED}[ERROR] API token verification failed (HTTP ${VERIFY_HTTP}).${NC}"
    echo -e "${RED}        Check your token and try again.${NC}"
    echo "$VERIFY_BODY" | head -5
    exit 1
fi
echo -e "${GREEN}[OK] API token is valid${NC}"
echo ""

# --- Step 2: Collect Worker config ---
echo -e "${CYAN}[2/4] Worker configuration${NC}"
echo ""

read -rp "    Worker name (e.g., my-xray-proxy): " WORKER_NAME
WORKER_NAME=${WORKER_NAME:-my-xray-proxy}
# Sanitize: lowercase, replace spaces with hyphens
WORKER_NAME=$(echo "${WORKER_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')

read -rp "    Backend host (VPS IP or domain, e.g., 87.242.119.137): " BACKEND_HOST
while [[ -z "${BACKEND_HOST}" ]]; do
    echo -e "${RED}    Backend host cannot be empty.${NC}"
    read -rp "    Backend host: " BACKEND_HOST
done

echo ""
echo -e "${GREEN}    Worker name:   ${WORKER_NAME}${NC}"
echo -e "${GREEN}    Backend host:  ${BACKEND_HOST}${NC}"
echo ""

# --- Step 3: Download and upload Worker script ---
echo -e "${CYAN}[3/4] Deploying Worker script...${NC}"
echo ""

# Download the worker script
WORKER_JS=$(curl -sSfL "${WORKER_SCRIPT_URL}" 2>/dev/null)
if [[ -z "${WORKER_JS}" ]]; then
    echo -e "${RED}[ERROR] Failed to download cf-worker-proxy.js from repository.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Worker script downloaded${NC}"

# Create metadata for the Worker (bindings for environment variables)
METADATA=$(cat <<METAEOF
{
  "main_module": "worker.js",
  "bindings": [
    {
      "type": "plain_text",
      "name": "BACKEND_HOST",
      "text": "${BACKEND_HOST}"
    }
  ],
  "compatibility_date": "2024-01-01"
}
METAEOF
)

# Create a temporary directory for the multipart upload
TMPDIR=$(mktemp -d)
echo "${WORKER_JS}" > "${TMPDIR}/worker.js"
echo "${METADATA}" > "${TMPDIR}/metadata.json"

# Upload the Worker using the Cloudflare API (multipart form)
UPLOAD_RESP=$(curl -s -w "\n%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -F "metadata=@${TMPDIR}/metadata.json;type=application/json" \
    -F "worker.js=@${TMPDIR}/worker.js;type=application/javascript+module" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}")

UPLOAD_HTTP=$(echo "$UPLOAD_RESP" | tail -1)
UPLOAD_BODY=$(echo "$UPLOAD_RESP" | head -n -1)

rm -rf "${TMPDIR}"

if [[ "$UPLOAD_HTTP" != "200" ]]; then
    echo -e "${RED}[ERROR] Failed to upload Worker (HTTP ${UPLOAD_HTTP}).${NC}"
    echo "$UPLOAD_BODY" | python3 -m json.tool 2>/dev/null || echo "$UPLOAD_BODY"
    exit 1
fi
echo -e "${GREEN}[OK] Worker '${WORKER_NAME}' uploaded successfully${NC}"

# --- Step 4: Enable the Worker on workers.dev subdomain ---
echo ""
echo -e "${CYAN}[4/4] Enabling workers.dev subdomain...${NC}"

# Enable the workers.dev route
SUBDOMAIN_RESP=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"enabled": true}' \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain")

SUBDOMAIN_HTTP=$(echo "$SUBDOMAIN_RESP" | tail -1)

# Get the workers.dev subdomain for this account
SUBDOMAIN_INFO=$(curl -s \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/subdomain")
WORKERS_SUBDOMAIN=$(echo "$SUBDOMAIN_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('subdomain',''))" 2>/dev/null || echo "")

if [[ -n "${WORKERS_SUBDOMAIN}" ]]; then
    WORKER_URL="${WORKER_NAME}.${WORKERS_SUBDOMAIN}.workers.dev"
else
    WORKER_URL="${WORKER_NAME}.<your-subdomain>.workers.dev"
    echo -e "${YELLOW}[WARN] Could not detect workers.dev subdomain automatically.${NC}"
    echo -e "${YELLOW}       Check your Cloudflare dashboard for the exact URL.${NC}"
fi

echo -e "${GREEN}[OK] Worker enabled on workers.dev${NC}"

# --- Done ---
echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${GREEN}  Deployment complete!${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""
echo -e "  ${GREEN}Worker URL:  https://${WORKER_URL}${NC}"
echo -e "  Backend:    ${BACKEND_HOST}"
echo -e "  Worker:     ${WORKER_NAME}"
echo ""
echo -e "${CYAN}  Используй этот URL в config-dual.json:${NC}"
echo -e "  Замени ${YELLOW}<WORKER_URL>${NC} → ${GREEN}${WORKER_URL}${NC}"
echo ""
echo -e "${CYAN}  Или запусти deploy.sh в режиме DUAL (2):${NC}"
echo -e "  sudo bash -c \"\$(curl -sSfL https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/deploy.sh)\""
echo -e "  → Выбери режим 2 → Введи Worker URL: ${WORKER_URL}"
echo ""
echo -e "${YELLOW}  Проверка Worker:${NC}"
echo -e "  curl -I https://${WORKER_URL}"
echo ""
