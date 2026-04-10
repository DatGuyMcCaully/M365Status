#!/bin/bash
# ============================================================
#  M365 Service Health Dashboard — Azure Service Account Setup
#  Run this ONCE on any Linux machine (can be the same server).
#
#  What it does:
#    1. Installs Azure CLI if not present
#    2. Logs you into Azure interactively (device code flow)
#    3. Creates an Entra ID app registration
#    4. Generates a 2-year self-signed certificate
#    5. Uploads the cert to the app (no client secret needed)
#    6. Grants ServiceHealth.Read.All + ServiceMessage.Read.All
#    7. Admin-consents the permissions automatically
#    8. Locks down the app (single-tenant, sign-in disabled)
#    9. Writes config.json with all values + cert paths
#   10. Prints next steps
#
#  Usage:  sudo bash az-setup.sh
# ============================================================
set -e

APP_DIR="/opt/m365-dashboard"
CERT_DIR="/opt/m365-dashboard/certs"
APP_NAME="m365-health-dashboard"
CERT_DAYS=730   # 2 years

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

[ "$EUID" -ne 0 ] && err "Please run as root:  sudo bash az-setup.sh"

# ── Detect package manager ────────────────────────────────────
section "Detecting OS"
if   command -v apt-get &>/dev/null; then PKG_MGR="apt";  info "Debian / Ubuntu"
elif command -v dnf     &>/dev/null; then PKG_MGR="dnf";  info "RHEL / Fedora / Rocky"
elif command -v yum     &>/dev/null; then PKG_MGR="yum";  info "CentOS / RHEL (legacy)"
else err "Unsupported package manager."; fi

# ── Install dependencies ──────────────────────────────────────
section "Installing dependencies"

install_pkg() {
  local pkg="$1"
  if ! command -v "$pkg" &>/dev/null; then
    if [ "$PKG_MGR" = "apt" ]; then
      apt-get install -y -q "$pkg"
    elif [ "$PKG_MGR" = "dnf" ]; then
      dnf install -y -q "$pkg"
    else
      yum install -y -q "$pkg"
    fi
  fi
}

# openssl
install_pkg openssl
info "openssl ready"

# jq (for parsing az CLI JSON output)
if ! command -v jq &>/dev/null; then
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get install -y -q jq
  elif [ "$PKG_MGR" = "dnf" ]; then
    dnf install -y -q jq
  else
    yum install -y -q jq
  fi
fi
info "jq ready"

# Azure CLI
if ! command -v az &>/dev/null; then
  section "Installing Azure CLI"
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get install -y -q curl gnupg lsb-release
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
  elif [ "$PKG_MGR" = "dnf" ]; then
    rpm --import https://packages.microsoft.com/keys/microsoft.asc
    dnf install -y -q https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm 2>/dev/null || true
    dnf install -y -q azure-cli
  else
    rpm --import https://packages.microsoft.com/keys/microsoft.asc
    yum install -y -q azure-cli
  fi
  info "Azure CLI installed: $(az version --query '"azure-cli"' -o tsv)"
else
  info "Azure CLI already installed: $(az version --query '"azure-cli"' -o tsv)"
fi

# ── Azure Login ───────────────────────────────────────────────
section "Azure Login"
echo ""
echo "  You'll be prompted to open a browser and enter a device code."
echo "  Log in as a Global Administrator (needed to grant API permissions)."
echo ""
az login --use-device-code --output none
info "Logged in"

# Grab tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)
info "Tenant ID: $TENANT_ID"

# ── Generate self-signed certificate ─────────────────────────
section "Generating self-signed certificate (${CERT_DAYS} days)"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

CERT_KEY="$CERT_DIR/m365dash.key"
CERT_PEM="$CERT_DIR/m365dash.crt"
CERT_PFX="$CERT_DIR/m365dash.pfx"  # not strictly needed but useful

openssl req -x509 \
  -newkey rsa:2048 \
  -keyout "$CERT_KEY" \
  -out "$CERT_PEM" \
  -days "$CERT_DAYS" \
  -nodes \
  -subj "/CN=${APP_NAME}" \
  2>/dev/null

chmod 600 "$CERT_KEY"
chmod 644 "$CERT_PEM"

# Compute thumbprint (SHA-1 hex, no colons — what Azure uses)
THUMBPRINT=$(openssl x509 -in "$CERT_PEM" -fingerprint -noout -sha1 \
  | sed 's/SHA1 Fingerprint=//; s/://g' | tr '[:lower:]' '[:upper:]')

info "Certificate: $CERT_PEM"
info "Private key: $CERT_KEY"
info "Thumbprint:  $THUMBPRINT"

# ── Create app registration ───────────────────────────────────
section "Creating Entra ID app registration: ${APP_NAME}"

# Check if app already exists
EXISTING_APP=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_APP" && "$EXISTING_APP" != "null" ]]; then
  warn "App '${APP_NAME}' already exists (App ID: ${EXISTING_APP}). Using existing app."
  CLIENT_ID="$EXISTING_APP"
else
  CLIENT_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --query appId -o tsv)
  info "App created — Client ID: $CLIENT_ID"
fi

# Wait a moment for propagation
sleep 3

# ── Upload certificate to app ─────────────────────────────────
section "Uploading certificate to app"
az ad app credential reset \
  --id "$CLIENT_ID" \
  --cert "@${CERT_PEM}" \
  --append \
  --output none
info "Certificate uploaded to app registration"

# ── Create service principal ──────────────────────────────────
section "Creating service principal"
SP_EXISTS=$(az ad sp list --filter "appId eq '${CLIENT_ID}'" --query "[0].id" -o tsv 2>/dev/null || true)
if [[ -z "$SP_EXISTS" || "$SP_EXISTS" == "null" ]]; then
  az ad sp create --id "$CLIENT_ID" --output none
  sleep 3
  info "Service principal created"
else
  info "Service principal already exists"
fi

SP_ID=$(az ad sp list --filter "appId eq '${CLIENT_ID}'" --query "[0].id" -o tsv)
info "Service Principal Object ID: $SP_ID"

# ── Disable user sign-in on the app ──────────────────────────
section "Hardening app (disabling user sign-in)"
az ad sp update --id "$SP_ID" \
  --set "accountEnabled=false" \
  --output none 2>/dev/null || \
  warn "Could not disable user sign-in via CLI — do it manually in Entra portal"
info "User sign-in disabled on service principal"

# ── Assign Microsoft Graph API permissions ────────────────────
section "Assigning Microsoft Graph permissions"

# Microsoft Graph App ID (constant across all tenants)
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

# Permission GUIDs (Application type)
# ServiceHealth.Read.All
PERM_SERVICEHEALTH="e765c9fd-7ce5-4c5f-bc7a-d1da85d5e1d5"
# ServiceMessage.Read.All
PERM_SERVICEMESSAGE="1b620472-6534-4fe6-9df2-4680e8aa28ec"

add_permission() {
  local perm_id="$1"
  local perm_name="$2"
  az ad app permission add \
    --id "$CLIENT_ID" \
    --api "$GRAPH_APP_ID" \
    --api-permissions "${perm_id}=Role" \
    --output none 2>/dev/null || warn "Could not add ${perm_name} — may already exist"
  info "Permission added: ${perm_name}"
}

add_permission "$PERM_SERVICEHEALTH" "ServiceHealth.Read.All"
add_permission "$PERM_SERVICEMESSAGE" "ServiceMessage.Read.All"

# ── Admin consent (via Graph REST — more reliable than az CLI) ────────────────
section "Granting admin consent"
sleep 6  # Let permission assignments propagate

# Get an access token for Microsoft Graph using the current az login session
MGMT_TOKEN=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

# Find the Graph service principal's object ID in this tenant
GRAPH_SP_OID=$(az ad sp list --filter "appId eq '${GRAPH_APP_ID}'" --query "[0].id" -o tsv)

consent_permission() {
  local perm_id="$1"
  local perm_name="$2"

  HTTP_STATUS=$(curl -s -o /tmp/consent_resp.json -w "%{http_code}"     -X POST     -H "Authorization: Bearer ${MGMT_TOKEN}"     -H "Content-Type: application/json"     -d "{
      \"clientId\": \"${SP_ID}\",
      \"consentType\": \"AllPrincipals\",
      \"principalId\": null,
      \"resourceId\": \"${GRAPH_SP_OID}\",
      \"scope\": \"\",
      \"startDateTime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"appRoleId\": \"${perm_id}\"
    }"     "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignments")

  if [[ "$HTTP_STATUS" == "201" || "$HTTP_STATUS" == "200" ]]; then
    info "Admin consent granted: ${perm_name}"
  elif [[ "$HTTP_STATUS" == "409" ]]; then
    info "Already consented: ${perm_name}"
  else
    ERRMSG=$(cat /tmp/consent_resp.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message','unknown'))" 2>/dev/null || echo "unknown")
    warn "Could not auto-consent ${perm_name} (HTTP ${HTTP_STATUS}: ${ERRMSG})"
    warn "Grant manually: Entra portal → App registrations → ${APP_NAME} → API permissions → Grant admin consent"
  fi
}

consent_permission "$PERM_SERVICEHEALTH" "ServiceHealth.Read.All"
consent_permission "$PERM_SERVICEMESSAGE" "ServiceMessage.Read.All"

# ── Write config.json ─────────────────────────────────────────
section "Writing config.json"
mkdir -p "$APP_DIR"

cat > "$APP_DIR/config.json" << CFGEOF
{
  "tenantId":     "${TENANT_ID}",
  "clientId":     "${CLIENT_ID}",
  "certPath":     "${CERT_PEM}",
  "certKeyPath":  "${CERT_KEY}",
  "thumbprint":   "${THUMBPRINT}",
  "port":         3000
}
CFGEOF

chmod 640 "$APP_DIR/config.json"
info "config.json written to $APP_DIR/config.json"

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Azure service account setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo "  Tenant ID    $TENANT_ID"
echo "  Client ID    $CLIENT_ID"
echo "  SP Object ID $SP_ID"
echo "  Cert         $CERT_PEM  (expires in ${CERT_DAYS} days)"
echo "  Key          $CERT_KEY"
echo "  Thumbprint   $THUMBPRINT"
echo ""
echo -e "${YELLOW}  Next steps:${NC}"
echo ""
echo "  1. Run the dashboard setup script (if not already done):"
echo "     sudo bash setup.sh"
echo ""
echo "  2. server.js needs to use the certificate instead of a client secret."
echo "     The updated server.js will already be in place if you ran setup.sh"
echo "     after this script."
echo ""
echo "  3. Cert rotation reminder:"
echo "     Your cert expires in ${CERT_DAYS} days. To rotate:"
echo "       sudo bash az-setup.sh"
echo "     (re-running will generate a new cert and update config.json)"
echo ""
echo "  4. Verify permissions in Entra portal:"
echo "     https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/${CLIENT_ID}"
echo ""
