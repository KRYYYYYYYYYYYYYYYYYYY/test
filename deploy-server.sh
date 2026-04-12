#!/usr/bin/env bash
# =============================================================================
# deploy-server.sh — Server-side automation for 3X-UI
# Injects noise configuration into 3X-UI's xray template,
# downloads ech.dat, and restarts the panel.
#
# One-liner:
#   sudo bash -c "$(curl -sSfL https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/deploy-server.sh)"
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_ASSET_DIR="/usr/local/share/xray"
ECH_URL="https://github.com/Akiyamov/singbox-ech-list/releases/latest/download/ech.dat"

# 3X-UI database paths (check multiple locations)
DB_PATHS=(
    "/etc/x-ui/x-ui.db"
    "/usr/local/x-ui/db/x-ui.db"
)

# Noise JSON to inject into Freedom outbound
NOISE_JSON='[
    {
      "type": "rand",
      "packet": "10-50",
      "delay": "10-16"
    },
    {
      "type": "rand",
      "packet": "50-200",
      "delay": "10-16"
    },
    {
      "type": "str",
      "packet": "GET / HTTP/1.1\r\nHost: ads.x5.ru\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n",
      "delay": "1-2"
    },
    {
      "type": "base64",
      "packet": "7nQBAAABAAAAAAAABnQtcmluZwZtc2VkZ2UDbmV0AAABAAE=",
      "delay": "10-16"
    }
  ]'

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  3X-UI Server - Noise & ECH Deployment      ${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# --- Check root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root (sudo).${NC}"
    exit 1
fi

# --- Install dependencies ---
for cmd in jq sqlite3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}[INFO] Installing ${cmd}...${NC}"
        apt-get update -qq && apt-get install -y -qq "$cmd" >/dev/null 2>&1
    fi
done

# --- Step 1: Download ech.dat ---
echo -e "${CYAN}[1/4] Downloading ech.dat (ECH domain database)...${NC}"
mkdir -p "${XRAY_ASSET_DIR}"
if wget -qO "${XRAY_ASSET_DIR}/ech.dat" "${ECH_URL}" 2>/dev/null || \
   curl -sSfL "${ECH_URL}" -o "${XRAY_ASSET_DIR}/ech.dat" 2>/dev/null; then
    ECH_SIZE=$(du -h "${XRAY_ASSET_DIR}/ech.dat" | cut -f1)
    echo -e "${GREEN}[OK] ech.dat downloaded (${ECH_SIZE}) -> ${XRAY_ASSET_DIR}/ech.dat${NC}"
else
    echo -e "${YELLOW}[WARN] Failed to download ech.dat. Continuing without it.${NC}"
fi

# --- Step 2: Find 3X-UI database ---
echo ""
echo -e "${CYAN}[2/4] Looking for 3X-UI database...${NC}"

XUI_DB=""
for db_path in "${DB_PATHS[@]}"; do
    if [[ -f "$db_path" ]]; then
        XUI_DB="$db_path"
        break
    fi
done

if [[ -z "$XUI_DB" ]]; then
    # Try to find it
    FOUND_DB=$(find / -name "x-ui.db" -type f 2>/dev/null | head -1)
    if [[ -n "$FOUND_DB" ]]; then
        XUI_DB="$FOUND_DB"
    fi
fi

if [[ -z "$XUI_DB" ]]; then
    echo -e "${RED}[ERROR] 3X-UI database not found!${NC}"
    echo -e "${RED}        Checked: ${DB_PATHS[*]}${NC}"
    echo -e ""
    echo -e "${YELLOW}If 3X-UI is not installed, install it first:${NC}"
    echo -e "${YELLOW}  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)${NC}"
    echo -e ""
    echo -e "${YELLOW}Or apply noise manually - copy this JSON into${NC}"
    echo -e "${YELLOW}3X-UI -> Panel Settings -> Xray Configuration -> Outbounds:${NC}"
    echo -e ""
    echo -e "${CYAN}${NOISE_JSON}${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Found database: ${XUI_DB}${NC}"

# --- Step 3: Backup and inject noise into xray template ---
echo ""
echo -e "${CYAN}[3/4] Injecting noise into xray template config...${NC}"

# Backup the database
BACKUP="${XUI_DB}.backup.$(date +%s)"
cp "$XUI_DB" "$BACKUP"
echo -e "${GREEN}[OK] Database backup: ${BACKUP}${NC}"

# Read current xray template config from the settings table
CURRENT_CONFIG=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || echo "")

if [[ -z "$CURRENT_CONFIG" ]]; then
    echo -e "${YELLOW}[INFO] No custom xray template found. Using 3X-UI default config.${NC}"
    echo -e "${YELLOW}       Will inject noise via alternative method...${NC}"

    # For fresh 3X-UI installs, we need to get the default config and modify it
    # The default template is embedded in the 3X-UI binary, but we can read the
    # runtime config that xray is currently using
    RUNTIME_CONFIG=""
    for cfg_path in /usr/local/x-ui/bin/config.json /etc/x-ui/config.json; do
        if [[ -f "$cfg_path" ]]; then
            RUNTIME_CONFIG=$(cat "$cfg_path")
            break
        fi
    done

    if [[ -z "$RUNTIME_CONFIG" ]]; then
        echo -e "${RED}[ERROR] Cannot find xray runtime config.${NC}"
        echo -e "${YELLOW}Apply noise manually in 3X-UI panel:${NC}"
        echo -e "${YELLOW}Panel Settings -> Xray Configuration Template${NC}"
        echo -e "${YELLOW}Add to outbounds section a Freedom outbound with noises.${NC}"
        echo ""
        echo -e "${CYAN}${NOISE_JSON}${NC}"
        exit 1
    fi

    CURRENT_CONFIG="$RUNTIME_CONFIG"
fi

# Use jq to check if Freedom outbound already has noise
HAS_NOISE=$(echo "$CURRENT_CONFIG" | jq '
    .outbounds // [] | map(select(.protocol == "freedom" and .settings.noises != null)) | length
' 2>/dev/null || echo "0")

if [[ "$HAS_NOISE" -gt 0 ]]; then
    echo -e "${YELLOW}[INFO] Freedom outbound already has noise configured.${NC}"
    read -rp "    Overwrite existing noise config? [y/N]: " OVERWRITE
    if [[ ! "${OVERWRITE,,}" =~ ^y ]]; then
        echo -e "${GREEN}[OK] Skipping noise injection.${NC}"
    else
        # Replace existing noise in the first Freedom outbound
        UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq --argjson noise "$NOISE_JSON" '
            .outbounds |= map(
                if .protocol == "freedom" and .tag == "direct" then
                    .settings.noises = $noise
                else .
                end
            )
        ' 2>/dev/null)

        if [[ $? -eq 0 && -n "$UPDATED_CONFIG" ]]; then
            # Escape for SQLite
            ESCAPED_CONFIG=$(echo "$UPDATED_CONFIG" | sed "s/'/''/g")
            sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayTemplateConfig', '${ESCAPED_CONFIG}');"
            echo -e "${GREEN}[OK] Noise configuration updated.${NC}"
        else
            echo -e "${RED}[ERROR] Failed to patch config with jq.${NC}"
            exit 1
        fi
    fi
else
    # No existing noise — inject into the first Freedom outbound (tag: "direct")
    # If no "direct" Freedom outbound exists, create one
    HAS_FREEDOM=$(echo "$CURRENT_CONFIG" | jq '
        .outbounds // [] | map(select(.protocol == "freedom")) | length
    ' 2>/dev/null || echo "0")

    if [[ "$HAS_FREEDOM" -gt 0 ]]; then
        # Add noise to the first Freedom outbound
        UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq --argjson noise "$NOISE_JSON" '
            (.outbounds[] | select(.protocol == "freedom") | .settings) += {"noises": $noise}
        ' 2>/dev/null)
    else
        # Create a new Freedom outbound with noise
        NEW_OUTBOUND=$(jq -n --argjson noise "$NOISE_JSON" '{
            "tag": "direct-noise",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "AsIs",
                "noises": $noise
            }
        }')
        UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq --argjson ob "$NEW_OUTBOUND" '
            .outbounds += [$ob]
        ' 2>/dev/null)
    fi

    if [[ $? -eq 0 && -n "$UPDATED_CONFIG" ]]; then
        # Write updated config back to the database
        ESCAPED_CONFIG=$(echo "$UPDATED_CONFIG" | sed "s/'/''/g")
        sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayTemplateConfig', '${ESCAPED_CONFIG}');"
        echo -e "${GREEN}[OK] Noise injected into Freedom outbound.${NC}"
    else
        echo -e "${RED}[ERROR] Failed to patch config with jq.${NC}"
        echo -e "${YELLOW}Restoring backup...${NC}"
        cp "$BACKUP" "$XUI_DB"
        echo -e "${YELLOW}Apply noise manually - JSON block:${NC}"
        echo -e "${CYAN}${NOISE_JSON}${NC}"
        exit 1
    fi
fi

# --- Step 4: Restart x-ui ---
echo ""
echo -e "${CYAN}[4/4] Restarting 3X-UI panel...${NC}"

if systemctl restart x-ui 2>/dev/null; then
    echo -e "${GREEN}[OK] x-ui service restarted.${NC}"
elif systemctl restart 3x-ui 2>/dev/null; then
    echo -e "${GREEN}[OK] 3x-ui service restarted.${NC}"
else
    echo -e "${YELLOW}[WARN] Could not restart x-ui service.${NC}"
    echo -e "${YELLOW}       Restart it manually: systemctl restart x-ui${NC}"
fi

# Verify xray is running
sleep 2
if pgrep -x xray >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] xray process is running.${NC}"
else
    echo -e "${YELLOW}[WARN] xray process not detected. Check x-ui panel for errors.${NC}"
fi

# --- Setup ech.dat auto-update cron ---
CRON_FILE="/etc/cron.d/ech-update"
if [[ ! -f "${CRON_FILE}" ]]; then
    echo ""
    echo -e "${CYAN}[+] Setting up ech.dat auto-update (every 12 hours)...${NC}"
    cat > "${CRON_FILE}" <<EOF
# Auto-update ECH domain database every 12 hours
0 */12 * * * root wget -qO ${XRAY_ASSET_DIR}/ech.dat ${ECH_URL} 2>/dev/null && systemctl restart x-ui 2>/dev/null
EOF
    chmod 644 "${CRON_FILE}"
    echo -e "${GREEN}[OK] Cron job created: ${CRON_FILE}${NC}"
fi

# --- Done ---
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${GREEN}  Server deployment complete!${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "  Database:  ${XUI_DB}"
echo -e "  Backup:    ${BACKUP}"
echo -e "  ECH DB:    ${XRAY_ASSET_DIR}/ech.dat"
echo ""
echo -e "${YELLOW}  Noise packets injected:${NC}"
echo -e "    - rand 10-50 bytes   (entropy padding)"
echo -e "    - rand 50-200 bytes  (bulk padding)"
echo -e "    - HTTP GET ads.x5.ru (traffic mimicry)"
echo -e "    - DNS query base64   (protocol mimicry)"
echo ""
echo -e "${YELLOW}  Verify in 3X-UI panel:${NC}"
echo -e "  Panel Settings -> Xray Configuration Template -> outbounds"
echo -e "  Look for \"noises\" array in Freedom outbound."
echo ""
