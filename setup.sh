#!/bin/bash
# ============================================================
#  M365 Service Health Dashboard — Automated Linux Setup
#  Supports: Ubuntu 20.04+, Debian 11+, RHEL/CentOS/Rocky 8+
#  Installs Node.js 20, nginx, optional Let's Encrypt TLS,
#  creates a dedicated user, writes all app files, and registers
#  a systemd service that auto-starts.
#
#  Usage:  sudo bash setup.sh
#
#  For automated Azure service account creation, run first:
#    sudo bash az-setup.sh
# ============================================================
set -e

APP_DIR="/opt/m365-dashboard"
SERVICE_NAME="m365-dashboard"
SERVICE_USER="m365dash"
PORT=3000

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}══ $1 ══${NC}"; }

[ "$EUID" -ne 0 ] && err "Please run as root:  sudo bash setup.sh"

# ── Detect package manager ────────────────────────────────────
section "Detecting OS"
if   command -v apt-get &>/dev/null; then PKG_MGR="apt";  info "Debian / Ubuntu"
elif command -v dnf     &>/dev/null; then PKG_MGR="dnf";  info "RHEL / Fedora / Rocky"
elif command -v yum     &>/dev/null; then PKG_MGR="yum";  info "CentOS / RHEL (legacy)"
else err "Unsupported package manager. Install Node.js 18+ manually then re-run."; fi

# ── Ask about TLS ─────────────────────────────────────────────
section "TLS / HTTPS Setup"
echo ""
echo "  Do you want to enable HTTPS via Let's Encrypt?"
echo "  Requirements: a domain name pointed at this server's public IP"
echo "                and port 80 + 443 open in your firewall."
echo ""
read -rp "  Enable Let's Encrypt? [y/N]: " USE_TLS
USE_TLS="${USE_TLS,,}"

DOMAIN=""
EMAIL_LE=""
if [[ "$USE_TLS" == "y" || "$USE_TLS" == "yes" ]]; then
  read -rp "  Domain name (e.g. m365.example.com): " DOMAIN
  read -rp "  Email for Let's Encrypt notices:    " EMAIL_LE
  [[ -z "$DOMAIN" ]] && err "Domain name is required for Let's Encrypt."
  [[ -z "$EMAIL_LE" ]] && err "Email address is required for Let's Encrypt."
  info "Will request certificate for: $DOMAIN"
else
  warn "Skipping TLS — dashboard will be served over plain HTTP on port $PORT"
fi

# ── Node.js 20 ────────────────────────────────────────────────
section "Installing Node.js 20"
NODE_OK=false
if command -v node &>/dev/null; then
  NODEVER=$(node -e "process.exit(parseInt(process.version.slice(1)) >= 18 ? 0 : 1)" 2>/dev/null && echo "ok" || true)
  [ "$NODEVER" = "ok" ] && NODE_OK=true && info "Node.js $(node -v) already installed"
fi
if [ "$NODE_OK" = false ]; then
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get update -qq
    apt-get install -y -q curl ca-certificates
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    apt-get install -y -q nodejs
  else
    [ "$PKG_MGR" = "dnf" ] && dnf install -y -q curl || yum install -y -q curl
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    [ "$PKG_MGR" = "dnf" ] && dnf install -y -q nodejs || yum install -y -q nodejs
  fi
  info "Node.js $(node -v) installed"
fi

# ── nginx ─────────────────────────────────────────────────────
section "Installing nginx"
if ! command -v nginx &>/dev/null; then
  if [ "$PKG_MGR" = "apt" ]; then
    apt-get install -y -q nginx
  elif [ "$PKG_MGR" = "dnf" ]; then
    dnf install -y -q nginx
  else
    yum install -y -q nginx
  fi
  info "nginx installed"
else
  info "nginx already installed"
fi
systemctl enable nginx >/dev/null 2>&1 || true

# ── App directory ─────────────────────────────────────────────
section "Creating app directory"
mkdir -p "$APP_DIR/public"
info "Directory: $APP_DIR"

# ── Write server.js ───────────────────────────────────────────
section "Writing server.js"
cat > "$APP_DIR/server.js" << 'SERVEREOF'
/**
 * M365 Service Health Dashboard — Proxy Server
 * Keeps credentials server-side. Clients call /api/* and this
 * server fetches from Microsoft Graph using the client_credentials flow.
 *
 * Supports two auth modes (auto-detected from config.json):
 *   - Certificate  — set certPath + certKeyPath  (recommended, no expiry issues)
 *   - Client secret — set clientSecret           (legacy / quick setup)
 *
 * Requires Node.js 18+. Zero npm dependencies.
 *
 * Usage:  node server.js
 * Default port: 3000  (override with PORT env var or config.json port field)
 */

const http   = require('http');
const https  = require('https');
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const { URLSearchParams } = require('url');

// ── Load config ───────────────────────────────────────────────────────────────
const cfgPath = path.join(__dirname, 'config.json');
if (!fs.existsSync(cfgPath)) {
  console.error('ERROR: config.json not found. Run az-setup.sh or copy config.example.json.');
  process.exit(1);
}
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
const { tenantId, clientId, clientSecret, certPath, certKeyPath, thumbprint, port: cfgPort } = cfg;

if (!tenantId || !clientId) {
  console.error('ERROR: config.json must contain tenantId and clientId.');
  process.exit(1);
}

const USE_CERT = !!(certPath && certKeyPath);
const USE_SECRET = !!clientSecret;

if (!USE_CERT && !USE_SECRET) {
  console.error('ERROR: config.json must contain either (certPath + certKeyPath) or clientSecret.');
  process.exit(1);
}

if (USE_CERT) {
  if (!fs.existsSync(certPath))    { console.error(`ERROR: cert not found: ${certPath}`);    process.exit(1); }
  if (!fs.existsSync(certKeyPath)) { console.error(`ERROR: key not found:  ${certKeyPath}`); process.exit(1); }
  console.log(`Auth mode: certificate  (${certPath})`);
} else {
  console.log('Auth mode: client secret');
}

const PORT = process.env.PORT || cfgPort || 3000;

// ── Token cache ───────────────────────────────────────────────────────────────
let cachedToken = null;
let tokenExpiry = 0;

// ── Certificate JWT assertion (RFC 7523 / MSAL style) ────────────────────────
function base64urlEncode(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function buildClientAssertion() {
  // Derive x5t (base64url SHA-1 thumbprint of DER cert) if not in config
  const certPem = fs.readFileSync(certPath, 'utf8');
  const certKey = fs.readFileSync(certKeyPath, 'utf8');

  let x5t;
  if (thumbprint) {
    // thumbprint from az-setup.sh is hex, convert to base64url
    const hexClean = thumbprint.replace(/:/g, '');
    x5t = base64urlEncode(Buffer.from(hexClean, 'hex'));
  } else {
    // Compute from cert
    const der = crypto.createHash('sha1')
      .update(Buffer.from(
        certPem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''),
        'base64'
      ))
      .digest();
    x5t = base64urlEncode(der);
  }

  const tokenUrl = `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`;
  const now = Math.floor(Date.now() / 1000);

  const header = base64urlEncode(Buffer.from(JSON.stringify({
    alg: 'RS256',
    typ: 'JWT',
    x5t,
  })));

  const payload = base64urlEncode(Buffer.from(JSON.stringify({
    aud: tokenUrl,
    iss: clientId,
    sub: clientId,
    jti: crypto.randomUUID(),
    nbf: now,
    exp: now + 600,   // 10 min validity
    iat: now,
  })));

  const sigInput = `${header}.${payload}`;
  const sig = base64urlEncode(
    crypto.sign('sha256', Buffer.from(sigInput), { key: certKey, dsaEncoding: 'ieee-p1363' })
  );

  return `${sigInput}.${sig}`;
}

// ── Token acquisition ─────────────────────────────────────────────────────────
async function getToken() {
  if (cachedToken && Date.now() < tokenExpiry) return cachedToken;

  let body;
  if (USE_CERT) {
    const assertion = buildClientAssertion();
    body = new URLSearchParams({
      grant_type:            'client_credentials',
      client_id:             clientId,
      client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
      client_assertion:      assertion,
      scope:                 'https://graph.microsoft.com/.default',
    }).toString();
  } else {
    body = new URLSearchParams({
      grant_type:    'client_credentials',
      client_id:     clientId,
      client_secret: clientSecret,
      scope:         'https://graph.microsoft.com/.default',
    }).toString();
  }

  const data = await httpsPost(
    `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`,
    { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  );

  if (!data.access_token) {
    throw new Error(data.error_description || data.error || 'Failed to acquire token');
  }

  cachedToken = data.access_token;
  tokenExpiry = Date.now() + (data.expires_in - 60) * 1000;
  return cachedToken;
}

// ── HTTPS helpers ─────────────────────────────────────────────────────────────
function httpsPost(url, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const opts = {
      hostname: u.hostname,
      path:     u.pathname + u.search,
      method:   'POST',
      headers:  { ...headers, 'Content-Length': Buffer.byteLength(body) },
    };
    const req = https.request(opts, res => {
      let raw = '';
      res.on('data', c => raw += c);
      res.on('end', () => { try { resolve(JSON.parse(raw)); } catch(e) { reject(e); } });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function httpsGet(url, headers) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const opts = { hostname: u.hostname, path: u.pathname + u.search, method: 'GET', headers };
    const req = https.request(opts, res => {
      let raw = '';
      res.on('data', c => raw += c);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(raw) }); }
        catch(e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

// ── Graph API calls ───────────────────────────────────────────────────────────
async function graphGet(urlPath) {
  const token = await getToken();
  const result = await httpsGet(
    `https://graph.microsoft.com/v1.0${urlPath}`,
    { Authorization: `Bearer ${token}`, Accept: 'application/json' }
  );
  if (result.status === 401) {
    cachedToken = null;
    throw new Error('Unauthorized — check app permissions or cert validity');
  }
  return result.body;
}

// ── Static file server ────────────────────────────────────────────────────────
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css':  'text/css',
  '.js':   'application/javascript',
  '.json': 'application/json',
  '.ico':  'image/x-icon',
  '.png':  'image/png',
  '.svg':  'image/svg+xml',
};

function serveStatic(res, filePath) {
  const ext  = path.extname(filePath);
  const mime = MIME[ext] || 'application/octet-stream';
  try {
    const content = fs.readFileSync(filePath);
    res.writeHead(200, { 'Content-Type': mime });
    res.end(content);
  } catch {
    res.writeHead(404);
    res.end('Not found');
  }
}

// ── Request router ────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];

  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  if (url === '/api/health') {
    try {
      const data = await graphGet('/admin/serviceAnnouncement/healthOverviews');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (url === '/api/issues') {
    try {
      const data = await graphGet(
        '/admin/serviceAnnouncement/issues?$filter=isResolved eq false&$orderby=lastModifiedDateTime desc&$top=25'
      );
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  // Static files
  let filePath;
  if (url === '/' || url === '/index.html') {
    filePath = path.join(__dirname, 'public', 'index.html');
  } else {
    filePath = path.join(__dirname, 'public', url);
  }

  const publicDir = path.resolve(__dirname, 'public');
  if (!path.resolve(filePath).startsWith(publicDir)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }

  serveStatic(res, filePath);
});

server.listen(PORT, () => {
  console.log(`M365 Health Dashboard running at http://localhost:${PORT}`);
  console.log(`Tenant: ${tenantId}  |  App: ${clientId}`);
});
SERVEREOF
info "server.js written"

# ── Write index.html (embedded as base64) ─────────────────────
section "Writing public/index.html"
echo "PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIiBkYXRhLXRoZW1lPSJkYXJrIj4KPGhlYWQ+CiAgPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CiAgPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiIC8+CiAgPHRpdGxlPk0zNjUgU2VydmljZSBIZWFsdGg8L3RpdGxlPgogIDxsaW5rIHJlbD0icHJlY29ubmVjdCIgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbSIgLz4KICA8bGluayByZWw9InByZWNvbm5lY3QiIGhyZWY9Imh0dHBzOi8vZm9udHMuZ3N0YXRpYy5jb20iIGNyb3Nzb3JpZ2luIC8+CiAgPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1JbnRlcjp3Z2h0QDMwMC4uNzAwJmZhbWlseT1KZXRCcmFpbnMrTW9ubzp3Z2h0QDQwMDs1MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiIC8+CiAgPHN0eWxlPgogICAgOnJvb3QgewogICAgICAtLXRleHQteHM6IGNsYW1wKDAuNzVyZW0sIDAuN3JlbSArIDAuMjV2dywgMC44NzVyZW0pOwogICAgICAtLXRleHQtc206IGNsYW1wKDAuODc1cmVtLCAwLjhyZW0gKyAwLjM1dncsIDFyZW0pOwogICAgICAtLXRleHQtYmFzZTogY2xhbXAoMXJlbSwgMC45NXJlbSArIDAuMjV2dywgMS4xMjVyZW0pOwogICAgICAtLXRleHQtbGc6IGNsYW1wKDEuMTI1cmVtLCAxcmVtICsgMC43NXZ3LCAxLjVyZW0pOwogICAgICAtLXNwYWNlLTE6IDAuMjVyZW07IC0tc3BhY2UtMjogMC41cmVtOyAtLXNwYWNlLTM6IDAuNzVyZW07CiAgICAgIC0tc3BhY2UtNDogMXJlbTsgICAgLS1zcGFjZS01OiAxLjI1cmVtOyAtLXNwYWNlLTY6IDEuNXJlbTsKICAgICAgLS1zcGFjZS04OiAycmVtOyAgICAtLXNwYWNlLTEwOiAyLjVyZW07CiAgICAgIC0tcmFkaXVzLXNtOiAwLjM3NXJlbTsgLS1yYWRpdXMtbWQ6IDAuNXJlbTsgLS1yYWRpdXMtbGc6IDAuNzVyZW07CiAgICAgIC0tdHJhbnNpdGlvbjogMTYwbXMgY3ViaWMtYmV6aWVyKDAuMTYsIDEsIDAuMywgMSk7CiAgICAgIC0tZm9udC1ib2R5OiAnSW50ZXInLCBzeXN0ZW0tdWksIHNhbnMtc2VyaWY7CiAgICAgIC0tZm9udC1tb25vOiAnSmV0QnJhaW5zIE1vbm8nLCBtb25vc3BhY2U7CiAgICB9CiAgICBbZGF0YS10aGVtZT0nZGFyayddIHsKICAgICAgLS1jb2xvci1iZzogICAgICAgICAgIzBkMTExNzsKICAgICAgLS1jb2xvci1zdXJmYWNlOiAgICAgIzE2MWIyMjsKICAgICAgLS1jb2xvci1zdXJmYWNlLTI6ICAgIzFjMjEyODsKICAgICAgLS1jb2xvci1ib3JkZXI6ICAgICAgIzMwMzYzZDsKICAgICAgLS1jb2xvci1kaXZpZGVyOiAgICAgIzIxMjYyZDsKICAgICAgLS1jb2xvci10ZXh0OiAgICAgICAgI2U2ZWRmMzsKICAgICAgLS1jb2xvci10ZXh0LW11dGVkOiAgIzhiOTQ5ZTsKICAgICAgLS1jb2xvci10ZXh0LWZhaW50OiAgIzQ4NGY1ODsKICAgICAgLS1jb2xvci1wcmltYXJ5OiAgICAgIzM4OGJmZDsKICAgICAgLS1jb2xvci1wcmltYXJ5LWRpbTogIzFmM2Y2ZTsKICAgICAgLS1jb2xvci1zdWNjZXNzOiAgICAgIzNmYjk1MDsKICAgICAgLS1jb2xvci1zdWNjZXNzLWRpbTogIzFhM2QyNDsKICAgICAgLS1jb2xvci13YXJuaW5nOiAgICAgI2QyOTkyMjsKICAgICAgLS1jb2xvci13YXJuaW5nLWRpbTogIzNkMmYwZTsKICAgICAgLS1jb2xvci1lcnJvcjogICAgICAgI2Y4NTE0OTsKICAgICAgLS1jb2xvci1lcnJvci1kaW06ICAgIzRhMWExYTsKICAgICAgLS1zaGFkb3ctc206IDAgMXB4IDNweCByZ2JhKDAsMCwwLDAuNCk7CiAgICAgIC0tc2hhZG93LW1kOiAwIDRweCAxNnB4IHJnYmEoMCwwLDAsMC41KTsKICAgIH0KICAgIFtkYXRhLXRoZW1lPSdsaWdodCddIHsKICAgICAgLS1jb2xvci1iZzogICAgICAgICAgI2YwZjJmNTsKICAgICAgLS1jb2xvci1zdXJmYWNlOiAgICAgI2ZmZmZmZjsKICAgICAgLS1jb2xvci1zdXJmYWNlLTI6ICAgI2Y2ZjhmYTsKICAgICAgLS1jb2xvci1ib3JkZXI6ICAgICAgI2QwZDdkZTsKICAgICAgLS1jb2xvci1kaXZpZGVyOiAgICAgI2U0ZThlZDsKICAgICAgLS1jb2xvci10ZXh0OiAgICAgICAgIzFmMjMyODsKICAgICAgLS1jb2xvci10ZXh0LW11dGVkOiAgIzY1NmQ3NjsKICAgICAgLS1jb2xvci10ZXh0LWZhaW50OiAgIzkxOThhMTsKICAgICAgLS1jb2xvci1wcmltYXJ5OiAgICAgIzA5NjlkYTsKICAgICAgLS1jb2xvci1wcmltYXJ5LWRpbTogI2RkZjRmZjsKICAgICAgLS1jb2xvci1zdWNjZXNzOiAgICAgIzFhN2YzNzsKICAgICAgLS1jb2xvci1zdWNjZXNzLWRpbTogI2RhZmJlMTsKICAgICAgLS1jb2xvci13YXJuaW5nOiAgICAgIzlhNjcwMDsKICAgICAgLS1jb2xvci13YXJuaW5nLWRpbTogI2ZmZjhjNTsKICAgICAgLS1jb2xvci1lcnJvcjogICAgICAgI2QxMjQyZjsKICAgICAgLS1jb2xvci1lcnJvci1kaW06ICAgI2ZmZWJlOTsKICAgICAgLS1zaGFkb3ctc206IDAgMXB4IDNweCByZ2JhKDAsMCwwLDAuMDgpOwogICAgICAtLXNoYWRvdy1tZDogMCA0cHggMTZweCByZ2JhKDAsMCwwLDAuMTApOwogICAgfQogICAgKiwgKjo6YmVmb3JlLCAqOjphZnRlciB7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogMDsgcGFkZGluZzogMDsgfQogICAgaHRtbCB7IC13ZWJraXQtZm9udC1zbW9vdGhpbmc6IGFudGlhbGlhc2VkOyB0ZXh0LXJlbmRlcmluZzogb3B0aW1pemVMZWdpYmlsaXR5OyBzY3JvbGwtYmVoYXZpb3I6IHNtb290aDsgfQogICAgYm9keSB7IGZvbnQtZmFtaWx5OiB2YXIoLS1mb250LWJvZHkpOyBmb250LXNpemU6IHZhcigtLXRleHQtc20pOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLWJnKTsgbWluLWhlaWdodDogMTAwZHZoOyBsaW5lLWhlaWdodDogMS42OyB9CiAgICBidXR0b24geyBjdXJzb3I6IHBvaW50ZXI7IGJhY2tncm91bmQ6IG5vbmU7IGJvcmRlcjogbm9uZTsgZm9udDogaW5oZXJpdDsgY29sb3I6IGluaGVyaXQ7IH0KICAgIGEsIGJ1dHRvbiB7IHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyYW5zaXRpb24pLCBiYWNrZ3JvdW5kIHZhcigtLXRyYW5zaXRpb24pLCBib3JkZXItY29sb3IgdmFyKC0tdHJhbnNpdGlvbiksIG9wYWNpdHkgdmFyKC0tdHJhbnNpdGlvbik7IH0KICAgIC5hcHAgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBtaW4taGVpZ2h0OiAxMDBkdmg7IH0KCiAgICAvKiBIZWFkZXIgKi8KICAgIC5oZWFkZXIgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47IHBhZGRpbmc6IHZhcigtLXNwYWNlLTMpIHZhcigtLXNwYWNlLTYpOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IHBvc2l0aW9uOiBzdGlja3k7IHRvcDogMDsgei1pbmRleDogMTAwOyBnYXA6IHZhcigtLXNwYWNlLTQpOyB9CiAgICAubG9nbyB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogdmFyKC0tc3BhY2UtMik7IH0KICAgIC5sb2dvLXRleHQgeyBmb250LXNpemU6IHZhcigtLXRleHQtc20pOyBmb250LXdlaWdodDogNjAwOyBsZXR0ZXItc3BhY2luZzogLTAuMDFlbTsgfQogICAgLmxvZ28tc3ViIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyB9CiAgICAuaGVhZGVyLXJpZ2h0IHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgfQogICAgLnJlZnJlc2gtaW5mbyB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgZm9udC1mYW1pbHk6IHZhcigtLWZvbnQtbW9ubyk7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogdmFyKC0tc3BhY2UtMik7IH0KICAgIC5wdWxzZS1kb3QgeyB3aWR0aDogNnB4OyBoZWlnaHQ6IDZweDsgYm9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdWNjZXNzKTsgYW5pbWF0aW9uOiBwdWxzZSAycyBlYXNlLWluLW91dCBpbmZpbml0ZTsgZmxleC1zaHJpbms6IDA7IH0KICAgIC5wdWxzZS1kb3QuZXJyb3IgICB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLWVycm9yKTsgICBhbmltYXRpb246IG5vbmU7IH0KICAgIC5wdWxzZS1kb3QubG9hZGluZyB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXByaW1hcnkpOyB9CiAgICBAa2V5ZnJhbWVzIHB1bHNlIHsgMCUsIDEwMCUgeyBvcGFjaXR5OiAxOyB9IDUwJSB7IG9wYWNpdHk6IDAuMzU7IH0gfQogICAgLmJ0biB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IHZhcigtLXNwYWNlLTIpOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0yKSB2YXIoLS1zcGFjZS0zKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLW1kKTsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDUwMDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZS0yKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyB3aGl0ZS1zcGFjZTogbm93cmFwOyB9CiAgICAuYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBib3JkZXItY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyB9CiAgICAudGhlbWUtdG9nZ2xlIHsgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1tZCk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UtMik7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgfQogICAgLnRoZW1lLXRvZ2dsZTpob3ZlciB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgfQoKICAgIC8qIE1haW4gKi8KICAgIC5tYWluIHsgcGFkZGluZzogdmFyKC0tc3BhY2UtNik7IG1heC13aWR0aDogMTIwMHB4OyBtYXJnaW46IDAgYXV0bzsgd2lkdGg6IDEwMCU7IGZsZXg6IDE7IH0KCiAgICAvKiBTdW1tYXJ5ICovCiAgICAuc3VtbWFyeS1iYXIgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47IGZsZXgtd3JhcDogd3JhcDsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgbWFyZ2luLWJvdHRvbTogdmFyKC0tc3BhY2UtNik7IH0KICAgIC5zdW1tYXJ5LXN0YXR1cyB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogdmFyKC0tc3BhY2UtMyk7IH0KICAgIC5zdGF0dXMtYmFkZ2UgeyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiB2YXIoLS1zcGFjZS0yKTsgcGFkZGluZzogdmFyKC0tc3BhY2UtMikgdmFyKC0tc3BhY2UtNCk7IGJvcmRlci1yYWRpdXM6IDk5OTlweDsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDYwMDsgbGV0dGVyLXNwYWNpbmc6IDAuMDNlbTsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsgfQogICAgLnN0YXR1cy1iYWRnZS5vayAgICAgIHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VjY2Vzcy1kaW0pOyBjb2xvcjogdmFyKC0tY29sb3Itc3VjY2Vzcyk7IH0KICAgIC5zdGF0dXMtYmFkZ2Uud2FybmluZyB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXdhcm5pbmctZGltKTsgY29sb3I6IHZhcigtLWNvbG9yLXdhcm5pbmcpOyB9CiAgICAuc3RhdHVzLWJhZGdlLmVycm9yICAgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1lcnJvci1kaW0pOyAgIGNvbG9yOiB2YXIoLS1jb2xvci1lcnJvcik7IH0KICAgIC5zdGF0dXMtYmFkZ2UubG9hZGluZyB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UtMik7ICAgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyB9CiAgICAubGFzdC11cGRhdGVkIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtZmFpbnQpOyBmb250LWZhbWlseTogdmFyKC0tZm9udC1tb25vKTsgfQoKICAgIC8qIFByb2dyZXNzIHJpbmcgKi8KICAgIC5wcm9ncmVzcy1yaW5nLXdyYXAgeyB3aWR0aDogMjBweDsgaGVpZ2h0OiAyMHB4OyBmbGV4LXNocmluazogMDsgZGlzcGxheTogbm9uZTsgfQogICAgLnByb2dyZXNzLXJpbmcgeyB0cmFuc2Zvcm06IHJvdGF0ZSgtOTBkZWcpOyB9CiAgICAucHJvZ3Jlc3MtcmluZy1jaXJjbGUgeyBzdHJva2UtZGFzaGFycmF5OiA1Ni41OyBzdHJva2UtZGFzaG9mZnNldDogNTYuNTsgc3Ryb2tlOiB2YXIoLS1jb2xvci1wcmltYXJ5KTsgdHJhbnNpdGlvbjogc3Ryb2tlLWRhc2hvZmZzZXQgMXMgbGluZWFyOyBmaWxsOiBub25lOyBzdHJva2UtbGluZWNhcDogcm91bmQ7IH0KICAgIC5wcm9ncmVzcy1yaW5nLWJnIHsgZmlsbDogbm9uZTsgc3Ryb2tlOiB2YXIoLS1jb2xvci1ib3JkZXIpOyB9CgogICAgLyogRmlsdGVycyAqLwogICAgLmZpbHRlci10YWJzIHsgZGlzcGxheTogZmxleDsgZ2FwOiB2YXIoLS1zcGFjZS0xKTsgbWFyZ2luLWJvdHRvbTogdmFyKC0tc3BhY2UtNCk7IGZsZXgtd3JhcDogd3JhcDsgfQogICAgLmZpbHRlci10YWIgeyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0yKSB2YXIoLS1zcGFjZS0zKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLW1kKTsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBib3JkZXI6IDFweCBzb2xpZCB0cmFuc3BhcmVudDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IH0KICAgIC5maWx0ZXItdGFiOmhvdmVyIHsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgfQogICAgLmZpbHRlci10YWIuYWN0aXZlIHsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1jb2xvci1ib3JkZXIpOyB9CgogICAgLyogU2VydmljZSBncmlkICovCiAgICAuc2VjdGlvbi10aXRsZSB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGZvbnQtd2VpZ2h0OiA2MDA7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7IGxldHRlci1zcGFjaW5nOiAwLjA3ZW07IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgbWFyZ2luLWJvdHRvbTogdmFyKC0tc3BhY2UtMyk7IH0KICAgIC5zZXJ2aWNlLWdyaWQgeyBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHJlcGVhdChhdXRvLWZpbGwsIG1pbm1heCgyMjBweCwgMWZyKSk7IGdhcDogdmFyKC0tc3BhY2UtMyk7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTgpOyB9CiAgICAuc2VydmljZS1jYXJkIHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZSk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1sZyk7IHBhZGRpbmc6IHZhcigtLXNwYWNlLTQpOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IHZhcigtLXNwYWNlLTMpOyB0cmFuc2l0aW9uOiBib3JkZXItY29sb3IgdmFyKC0tdHJhbnNpdGlvbiksIGJveC1zaGFkb3cgdmFyKC0tdHJhbnNpdGlvbiksIHRyYW5zZm9ybSB2YXIoLS10cmFuc2l0aW9uKTsgfQogICAgLnNlcnZpY2UtY2FyZDpob3ZlciB7IGJvcmRlci1jb2xvcjogdmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7IGJveC1zaGFkb3c6IHZhcigtLXNoYWRvdy1zbSk7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMXB4KTsgfQogICAgLnNlcnZpY2UtY2FyZC53YXJuaW5nIHsgYm9yZGVyLWNvbG9yOiB2YXIoLS1jb2xvci13YXJuaW5nKTsgfQogICAgLnNlcnZpY2UtY2FyZC5lcnJvciAgIHsgYm9yZGVyLWNvbG9yOiB2YXIoLS1jb2xvci1lcnJvcik7IH0KICAgIC5zZXJ2aWNlLWljb24geyB3aWR0aDogMzZweDsgaGVpZ2h0OiAzNnB4OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMtbWQpOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgZmxleC1zaHJpbms6IDA7IGZvbnQtc2l6ZTogMThweDsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZS0yKTsgfQogICAgLnNlcnZpY2UtaW5mbyB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgfQogICAgLnNlcnZpY2UtbmFtZSB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGZvbnQtd2VpZ2h0OiA2MDA7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgbGluZS1oZWlnaHQ6IDEuMzsgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtbGluZS1jbGFtcDogMjsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgb3ZlcmZsb3c6IGhpZGRlbjsgfQogICAgLnNlcnZpY2Utc3RhdHVzLXRleHQgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7IG1hcmdpbi10b3A6IDJweDsgfQogICAgLnNlcnZpY2Utc3RhdHVzLXRleHQub2sgICAgICB7IGNvbG9yOiB2YXIoLS1jb2xvci1zdWNjZXNzKTsgfQogICAgLnNlcnZpY2Utc3RhdHVzLXRleHQud2FybmluZyB7IGNvbG9yOiB2YXIoLS1jb2xvci13YXJuaW5nKTsgfQogICAgLnNlcnZpY2Utc3RhdHVzLXRleHQuZXJyb3IgICB7IGNvbG9yOiB2YXIoLS1jb2xvci1lcnJvcik7IH0KICAgIC5zZXJ2aWNlLWRvdCB7IHdpZHRoOiA4cHg7IGhlaWdodDogOHB4OyBib3JkZXItcmFkaXVzOiA1MCU7IGZsZXgtc2hyaW5rOiAwOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdWNjZXNzKTsgfQogICAgLnNlcnZpY2UtZG90Lndhcm5pbmcgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci13YXJuaW5nKTsgfQogICAgLnNlcnZpY2UtZG90LmVycm9yICAgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1lcnJvcik7IGFuaW1hdGlvbjogYmxpbmsgMS4ycyBzdGVwLWVuZCBpbmZpbml0ZTsgfQogICAgQGtleWZyYW1lcyBibGluayB7IDAlLCAxMDAlIHsgb3BhY2l0eTogMTsgfSA1MCUgeyBvcGFjaXR5OiAwLjE1OyB9IH0KCiAgICAvKiBJbmNpZGVudHMgKi8KICAgIC5pbmNpZGVudHMtc2VjdGlvbiB7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTgpOyB9CiAgICAuaW5jaWRlbnRzLWxpc3QgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IHZhcigtLXNwYWNlLTMpOyB9CiAgICAuaW5jaWRlbnQtY2FyZCB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UpOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMtbGcpOyBvdmVyZmxvdzogaGlkZGVuOyB9CiAgICAuaW5jaWRlbnQtY2FyZC5pbmNpZGVudCB7IGJvcmRlci1sZWZ0OiAzcHggc29saWQgdmFyKC0tY29sb3ItZXJyb3IpOyB9CiAgICAuaW5jaWRlbnQtY2FyZC5hZHZpc29yeSB7IGJvcmRlci1sZWZ0OiAzcHggc29saWQgdmFyKC0tY29sb3Itd2FybmluZyk7IH0KICAgIC5pbmNpZGVudC1oZWFkZXIgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS00KSB2YXIoLS1zcGFjZS01KTsgZ2FwOiB2YXIoLS1zcGFjZS00KTsgY3Vyc29yOiBwb2ludGVyOyB9CiAgICAuaW5jaWRlbnQtaGVhZGVyOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZS0yKTsgfQogICAgLmluY2lkZW50LW1haW4geyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IH0KICAgIC5pbmNpZGVudC10b3AgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IHZhcigtLXNwYWNlLTIpOyBmbGV4LXdyYXA6IHdyYXA7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTIpOyB9CiAgICAuaW5jaWRlbnQtaWQgeyBmb250LWZhbWlseTogdmFyKC0tZm9udC1tb25vKTsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlLTIpOyBwYWRkaW5nOiAxcHggdmFyKC0tc3BhY2UtMik7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1zbSk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IH0KICAgIC50eXBlLXBpbGwgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBmb250LXdlaWdodDogNjAwOyBwYWRkaW5nOiAxcHggdmFyKC0tc3BhY2UtMik7IGJvcmRlci1yYWRpdXM6IDk5OTlweDsgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsgbGV0dGVyLXNwYWNpbmc6IDAuMDRlbTsgfQogICAgLnR5cGUtcGlsbC5pbmNpZGVudCB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLWVycm9yLWRpbSk7IGNvbG9yOiB2YXIoLS1jb2xvci1lcnJvcik7IH0KICAgIC50eXBlLXBpbGwuYWR2aXNvcnkgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci13YXJuaW5nLWRpbSk7IGNvbG9yOiB2YXIoLS1jb2xvci13YXJuaW5nKTsgfQogICAgLnN0YXR1cy1waWxsIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDUwMDsgcGFkZGluZzogMXB4IHZhcigtLXNwYWNlLTIpOyBib3JkZXItcmFkaXVzOiA5OTk5cHg7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UtMik7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgfQogICAgLmluY2lkZW50LXRpdGxlIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXNtKTsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBsaW5lLWhlaWdodDogMS4zNTsgfQogICAgLmluY2lkZW50LXNlcnZpY2UgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7IG1hcmdpbi10b3A6IHZhcigtLXNwYWNlLTEpOyB9CiAgICAuaW5jaWRlbnQtbWV0YSB7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBmbGV4LWVuZDsgZ2FwOiB2YXIoLS1zcGFjZS0xKTsgZmxleC1zaHJpbms6IDA7IH0KICAgIC5pbmNpZGVudC10aW1lIHsgZm9udC1mYW1pbHk6IHZhcigtLWZvbnQtbW9ubyk7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LWZhaW50KTsgfQogICAgLmNoZXZyb24geyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dC1mYWludCk7IHRyYW5zaXRpb246IHRyYW5zZm9ybSB2YXIoLS10cmFuc2l0aW9uKTsgfQogICAgLmNoZXZyb24ub3BlbiB7IHRyYW5zZm9ybTogcm90YXRlKDE4MGRlZyk7IH0KICAgIC5pbmNpZGVudC1ib2R5IHsgcGFkZGluZzogMCB2YXIoLS1zcGFjZS01KSB2YXIoLS1zcGFjZS01KTsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWRpdmlkZXIpOyBkaXNwbGF5OiBub25lOyB9CiAgICAuaW5jaWRlbnQtYm9keS5vcGVuIHsgZGlzcGxheTogYmxvY2s7IH0KICAgIC5pbmNpZGVudC11cGRhdGVzIHsgbWFyZ2luLXRvcDogdmFyKC0tc3BhY2UtNCk7IH0KICAgIC51cGRhdGUtZW50cnkgeyBkaXNwbGF5OiBmbGV4OyBnYXA6IHZhcigtLXNwYWNlLTQpOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0zKSAwOyBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tY29sb3ItZGl2aWRlcik7IH0KICAgIC51cGRhdGUtZW50cnk6bGFzdC1jaGlsZCB7IGJvcmRlci1ib3R0b206IG5vbmU7IH0KICAgIC51cGRhdGUtdGltZSB7IGZvbnQtZmFtaWx5OiB2YXIoLS1mb250LW1vbm8pOyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7IGZsZXgtc2hyaW5rOiAwOyB3aWR0aDogMTQwcHg7IHBhZGRpbmctdG9wOiAycHg7IH0KICAgIC51cGRhdGUtdGV4dCB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgbGluZS1oZWlnaHQ6IDEuNjsgfQoKICAgIC8qIFN0YXRlcyAqLwogICAgLnN0YXRlLWJveCB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UpOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMtbGcpOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0xMCk7IHRleHQtYWxpZ246IGNlbnRlcjsgfQogICAgLnN0YXRlLWljb24geyBmb250LXNpemU6IDMycHg7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTMpOyB9CiAgICAuc3RhdGUtdGl0bGUgeyBmb250LXNpemU6IHZhcigtLXRleHQtc20pOyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTIpOyB9CiAgICAuc3RhdGUtZGVzYyB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgbWF4LXdpZHRoOiA0MmNoOyBtYXJnaW46IDAgYXV0bzsgfQogICAgLnNrZWxldG9uIHsgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCB2YXIoLS1jb2xvci1zdXJmYWNlKSAwJSwgdmFyKC0tY29sb3Itc3VyZmFjZS0yKSA1MCUsIHZhcigtLWNvbG9yLXN1cmZhY2UpIDEwMCUpOyBiYWNrZ3JvdW5kLXNpemU6IDIwMCUgMTAwJTsgYW5pbWF0aW9uOiBzaGltbWVyIDEuNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1tZCk7IH0KICAgIEBrZXlmcmFtZXMgc2hpbW1lciB7IDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMjAwJSAwOyB9IDEwMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAtMjAwJSAwOyB9IH0KCiAgICAvKiBGb290ZXIgKi8KICAgIC5mb290ZXIgeyBwYWRkaW5nOiB2YXIoLS1zcGFjZS00KSB2YXIoLS1zcGFjZS02KTsgYm9yZGVyLXRvcDogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWRpdmlkZXIpOyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47IGZsZXgtd3JhcDogd3JhcDsgZ2FwOiB2YXIoLS1zcGFjZS0yKTsgfQogICAgLmZvb3Rlci10ZXh0IHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtZmFpbnQpOyB9CiAgICAuZm9vdGVyLXRleHQgYSB7IGNvbG9yOiB2YXIoLS1jb2xvci1wcmltYXJ5KTsgdGV4dC1kZWNvcmF0aW9uOiBub25lOyB9CiAgICAuZm9vdGVyLXRleHQgYTpob3ZlciB7IHRleHQtZGVjb3JhdGlvbjogdW5kZXJsaW5lOyB9CgogICAgLyogVG9hc3QgKi8KICAgIC50b2FzdC1jb250YWluZXIgeyBwb3NpdGlvbjogZml4ZWQ7IGJvdHRvbTogdmFyKC0tc3BhY2UtNik7IHJpZ2h0OiB2YXIoLS1zcGFjZS02KTsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiB2YXIoLS1zcGFjZS0yKTsgei1pbmRleDogNTAwOyB9CiAgICAudG9hc3QgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLWxnKTsgcGFkZGluZzogdmFyKC0tc3BhY2UtMykgdmFyKC0tc3BhY2UtNSk7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGJveC1zaGFkb3c6IHZhcigtLXNoYWRvdy1tZCk7IG1heC13aWR0aDogMzIwcHg7IGFuaW1hdGlvbjogdG9hc3RJbiAwLjNzIGVhc2U7IH0KICAgIEBrZXlmcmFtZXMgdG9hc3RJbiB7IGZyb20geyBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoOHB4KTsgfSB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsgfSB9CiAgICAudG9hc3Quc3VjY2VzcyB7IGJvcmRlci1sZWZ0OiAzcHggc29saWQgdmFyKC0tY29sb3Itc3VjY2Vzcyk7IH0KICAgIC50b2FzdC5lcnJvciAgIHsgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCB2YXIoLS1jb2xvci1lcnJvcik7IH0KCiAgICBAbWVkaWEgKG1heC13aWR0aDogNjQwcHgpIHsKICAgICAgLm1haW4geyBwYWRkaW5nOiB2YXIoLS1zcGFjZS00KTsgfQogICAgICAuaGVhZGVyIHsgcGFkZGluZzogdmFyKC0tc3BhY2UtMykgdmFyKC0tc3BhY2UtNCk7IH0KICAgICAgLnNlcnZpY2UtZ3JpZCB7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyIDFmcjsgfQogICAgICAuaW5jaWRlbnQtbWV0YSB7IGRpc3BsYXk6IG5vbmU7IH0KICAgIH0KICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGNsYXNzPSJhcHAiPgogIDxoZWFkZXIgY2xhc3M9ImhlYWRlciI+CiAgICA8ZGl2IGNsYXNzPSJsb2dvIj4KICAgICAgPHN2ZyB3aWR0aD0iMjgiIGhlaWdodD0iMjgiIHZpZXdCb3g9IjAgMCAyOCAyOCIgZmlsbD0ibm9uZSIgYXJpYS1sYWJlbD0iTTM2NSBTdGF0dXMiPgogICAgICAgIDxyZWN0IHdpZHRoPSIyOCIgaGVpZ2h0PSIyOCIgcng9IjYiIGZpbGw9InZhcigtLWNvbG9yLXByaW1hcnkpIi8+CiAgICAgICAgPHJlY3QgeD0iNSIgeT0iNSIgd2lkdGg9IjgiIGhlaWdodD0iOCIgcng9IjEuNSIgZmlsbD0id2hpdGUiIG9wYWNpdHk9IjAuOTUiLz4KICAgICAgICA8cmVjdCB4PSIxNSIgeT0iNSIgd2lkdGg9IjgiIGhlaWdodD0iOCIgcng9IjEuNSIgZmlsbD0id2hpdGUiIG9wYWNpdHk9IjAuNyIvPgogICAgICAgIDxyZWN0IHg9IjUiIHk9IjE1IiB3aWR0aD0iOCIgaGVpZ2h0PSI4IiByeD0iMS41IiBmaWxsPSJ3aGl0ZSIgb3BhY2l0eT0iMC43Ii8+CiAgICAgICAgPHJlY3QgeD0iMTUiIHk9IjE1IiB3aWR0aD0iOCIgaGVpZ2h0PSI4IiByeD0iMS41IiBmaWxsPSJ3aGl0ZSIgb3BhY2l0eT0iMC41Ii8+CiAgICAgIDwvc3ZnPgogICAgICA8ZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxvZ28tdGV4dCI+TTM2NSBTZXJ2aWNlIEhlYWx0aDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxvZ28tc3ViIj5MaXZlIHN0YXR1cyBkYXNoYm9hcmQ8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImhlYWRlci1yaWdodCI+CiAgICAgIDxkaXYgY2xhc3M9InJlZnJlc2gtaW5mbyI+CiAgICAgICAgPGRpdiBjbGFzcz0icHVsc2UtZG90IGxvYWRpbmciIGlkPSJzdGF0dXNEb3QiPjwvZGl2PgogICAgICAgIDxzcGFuIGlkPSJyZWZyZXNoQ291bnRkb3duIj5Mb2FkaW5n4oCmPC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBpZD0icmVmcmVzaEJ0biI+CiAgICAgICAgPHN2ZyB3aWR0aD0iMTIiIGhlaWdodD0iMTIiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi41Ij4KICAgICAgICAgIDxwYXRoIGQ9Ik0yMyA0djZoLTZNMSAyMHYtNmg2Ii8+PHBhdGggZD0iTTMuNTEgOWE5IDkgMCAwIDEgMTQuODUtMy4zNkwyMyAxME0xIDE0bDQuNjQgNC4zNkE5IDkgMCAwIDAgMjAuNDkgMTUiLz4KICAgICAgICA8L3N2Zz4KICAgICAgICBSZWZyZXNoCiAgICAgIDwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJwcm9ncmVzcy1yaW5nLXdyYXAiIGlkPSJwcm9ncmVzc1JpbmdXcmFwIj4KICAgICAgICA8c3ZnIGNsYXNzPSJwcm9ncmVzcy1yaW5nIiB3aWR0aD0iMjAiIGhlaWdodD0iMjAiPgogICAgICAgICAgPGNpcmNsZSBjbGFzcz0icHJvZ3Jlc3MtcmluZy1iZyIgY3g9IjEwIiBjeT0iMTAiIHI9IjkiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICAgICAgPGNpcmNsZSBjbGFzcz0icHJvZ3Jlc3MtcmluZy1jaXJjbGUiIGlkPSJwcm9ncmVzc1JpbmciIGN4PSIxMCIgY3k9IjEwIiByPSI5IiBzdHJva2Utd2lkdGg9IjIiLz4KICAgICAgICA8L3N2Zz4KICAgICAgPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9InRoZW1lLXRvZ2dsZSIgaWQ9InRoZW1lVG9nZ2xlIiBhcmlhLWxhYmVsPSJUb2dnbGUgdGhlbWUiPgogICAgICAgIDxzdmcgd2lkdGg9IjE0IiBoZWlnaHQ9IjE0IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiIGlkPSJ0aGVtZUljb24iPgogICAgICAgICAgPHBhdGggZD0iTTIxIDEyLjc5QTkgOSAwIDEgMSAxMS4yMSAzIDcgNyAwIDAgMCAyMSAxMi43OXoiLz4KICAgICAgICA8L3N2Zz4KICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2hlYWRlcj4KCiAgPG1haW4gY2xhc3M9Im1haW4iPgogICAgPGRpdiBjbGFzcz0ic3VtbWFyeS1iYXIiPgogICAgICA8ZGl2IGNsYXNzPSJzdW1tYXJ5LXN0YXR1cyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3RhdHVzLWJhZGdlIGxvYWRpbmciIGlkPSJnbG9iYWxCYWRnZSI+CiAgICAgICAgICA8c3BhbiBpZD0iZ2xvYmFsQmFkZ2VUZXh0Ij5Mb2FkaW5n4oCmPC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJsYXN0LXVwZGF0ZWQiIGlkPSJsYXN0VXBkYXRlZCI+PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpbHRlci10YWJzIiBpZD0iZmlsdGVyVGFicyI+CiAgICAgIDxidXR0b24gY2xhc3M9ImZpbHRlci10YWIgYWN0aXZlIiBkYXRhLWZpbHRlcj0iYWxsIj5BbGwgU2VydmljZXM8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iZmlsdGVyLXRhYiIgZGF0YS1maWx0ZXI9Imlzc3VlcyI+SXNzdWVzIE9ubHk8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iZmlsdGVyLXRhYiIgZGF0YS1maWx0ZXI9IkV4Y2hhbmdlIE9ubGluZSI+RXhjaGFuZ2U8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iZmlsdGVyLXRhYiIgZGF0YS1maWx0ZXI9Ik1pY3Jvc29mdCBUZWFtcyI+VGVhbXM8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iZmlsdGVyLXRhYiIgZGF0YS1maWx0ZXI9IlNoYXJlUG9pbnQgT25saW5lIj5TaGFyZVBvaW50PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImZpbHRlci10YWIiIGRhdGEtZmlsdGVyPSJPbmVEcml2ZSBmb3IgQnVzaW5lc3MiPk9uZURyaXZlPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJzZXJ2aWNlc0NvbnRhaW5lciI+PC9kaXY+CgogICAgPGRpdiBjbGFzcz0iaW5jaWRlbnRzLXNlY3Rpb24iIGlkPSJpbmNpZGVudHNTZWN0aW9uIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjdGlvbi10aXRsZSIgaWQ9ImluY2lkZW50c1NlY3Rpb25UaXRsZSI+QWN0aXZlIElzc3VlczwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudHMtbGlzdCIgaWQ9ImluY2lkZW50c0xpc3QiPjwvZGl2PgogICAgPC9kaXY+CiAgPC9tYWluPgoKICA8Zm9vdGVyIGNsYXNzPSJmb290ZXIiPgogICAgPGRpdiBjbGFzcz0iZm9vdGVyLXRleHQiPkRhdGEgdmlhIDxhIGhyZWY9Imh0dHBzOi8vbGVhcm4ubWljcm9zb2Z0LmNvbS9lbi11cy9ncmFwaC9hcGkvcmVzb3VyY2VzL3NlcnZpY2UtY29tbXVuaWNhdGlvbnMtYXBpLW92ZXJ2aWV3IiB0YXJnZXQ9Il9ibGFuayI+TWljcm9zb2Z0IEdyYXBoIFNlcnZpY2UgQ29tbXVuaWNhdGlvbnMgQVBJPC9hPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iZm9vdGVyLXRleHQiPkF1dG8tcmVmcmVzaGVzIGV2ZXJ5IDYwIHNlY29uZHM8L2Rpdj4KICA8L2Zvb3Rlcj4KPC9kaXY+CjxkaXYgY2xhc3M9InRvYXN0LWNvbnRhaW5lciIgaWQ9InRvYXN0Q29udGFpbmVyIj48L2Rpdj4KCjxzY3JpcHQ+Ci8vIEFsbCBBUEkgY2FsbHMgZ28gdG8gdGhlIGxvY2FsIHByb3h5IHNlcnZlciDigJQgbm8gY3JlZGVudGlhbHMgaW4gdGhpcyBmaWxlLgpjb25zdCBBUEkgPSAnJzsgIC8vIHJlbGF0aXZlIOKAlCB3b3JrcyBvbiBhbnkgcG9ydC9ob3N0bmFtZQoKbGV0IGFsbFNlcnZpY2VzID0gW10sIGFsbElzc3VlcyA9IFtdOwpsZXQgcmVmcmVzaFRpbWVyID0gbnVsbCwgY291bnRkb3duVGltZXIgPSBudWxsLCBjb3VudGRvd25TZWMgPSA2MDsKbGV0IGFjdGl2ZUZpbHRlciA9ICdhbGwnOwpjb25zdCBSRUZSRVNIX0lOVEVSVkFMID0gNjA7CgovLyBUaGVtZQooZnVuY3Rpb24oKSB7CiAgY29uc3QgcHJlZiA9IG1hdGNoTWVkaWEoJyhwcmVmZXJzLWNvbG9yLXNjaGVtZTogZGFyayknKS5tYXRjaGVzID8gJ2RhcmsnIDogJ2xpZ2h0JzsKICBkb2N1bWVudC5kb2N1bWVudEVsZW1lbnQuc2V0QXR0cmlidXRlKCdkYXRhLXRoZW1lJywgcHJlZik7CiAgdXBkYXRlVGhlbWVJY29uKHByZWYpOwp9KSgpOwpmdW5jdGlvbiB1cGRhdGVUaGVtZUljb24odCkgewogIGNvbnN0IGljb24gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGhlbWVJY29uJyk7CiAgaWYgKCFpY29uKSByZXR1cm47CiAgaWNvbi5pbm5lckhUTUwgPSB0ID09PSAnZGFyaycKICAgID8gJzxwYXRoIGQ9Ik0yMSAxMi43OUE5IDkgMCAxIDEgMTEuMjEgMyA3IDcgMCAwIDAgMjEgMTIuNzl6Ii8+JwogICAgOiAnPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iNSIvPjxwYXRoIGQ9Ik0xMiAxdjJNMTIgMjF2Mk00LjIyIDQuMjJsMS40MiAxLjQyTTE4LjM2IDE4LjM2bDEuNDIgMS40Mk0xIDEyaDJNMjEgMTJoMk00LjIyIDE5Ljc4bDEuNDItMS40Mk0xOC4zNiA1LjY0bDEuNDItMS40MiIvPic7Cn0KZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RoZW1lVG9nZ2xlJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgY29uc3QgaHRtbCA9IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudDsKICBjb25zdCBuZXh0ID0gaHRtbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtdGhlbWUnKSA9PT0gJ2RhcmsnID8gJ2xpZ2h0JyA6ICdkYXJrJzsKICBodG1sLnNldEF0dHJpYnV0ZSgnZGF0YS10aGVtZScsIG5leHQpOwogIHVwZGF0ZVRoZW1lSWNvbihuZXh0KTsKfSk7CgovLyBGZXRjaCBmcm9tIGxvY2FsIHByb3h5CmFzeW5jIGZ1bmN0aW9uIGZldGNoSGVhbHRoKCkgewogIGNvbnN0IHJlcyA9IGF3YWl0IGZldGNoKEFQSSArICcvYXBpL2hlYWx0aCcpOwogIGlmICghcmVzLm9rKSB7IGNvbnN0IGUgPSBhd2FpdCByZXMuanNvbigpOyB0aHJvdyBuZXcgRXJyb3IoZS5lcnJvciB8fCBgSFRUUCAke3Jlcy5zdGF0dXN9YCk7IH0KICByZXR1cm4gKGF3YWl0IHJlcy5qc29uKCkpLnZhbHVlIHx8IFtdOwp9CmFzeW5jIGZ1bmN0aW9uIGZldGNoSXNzdWVzKCkgewogIGNvbnN0IHJlcyA9IGF3YWl0IGZldGNoKEFQSSArICcvYXBpL2lzc3VlcycpOwogIGlmICghcmVzLm9rKSB7IGNvbnN0IGUgPSBhd2FpdCByZXMuanNvbigpOyB0aHJvdyBuZXcgRXJyb3IoZS5lcnJvciB8fCBgSFRUUCAke3Jlcy5zdGF0dXN9YCk7IH0KICByZXR1cm4gKGF3YWl0IHJlcy5qc29uKCkpLnZhbHVlIHx8IFtdOwp9Cgphc3luYyBmdW5jdGlvbiBmZXRjaEFuZFJlbmRlcigpIHsKICBzZXREb3QoJ2xvYWRpbmcnKTsKICBzaG93U2tlbGV0b25zKCk7CiAgdHJ5IHsKICAgIGNvbnN0IFtzZXJ2aWNlcywgaXNzdWVzXSA9IGF3YWl0IFByb21pc2UuYWxsKFtmZXRjaEhlYWx0aCgpLCBmZXRjaElzc3VlcygpXSk7CiAgICBhbGxTZXJ2aWNlcyA9IHNlcnZpY2VzOwogICAgYWxsSXNzdWVzID0gaXNzdWVzOwogICAgcmVuZGVyQWxsKCk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGFzdFVwZGF0ZWQnKS50ZXh0Q29udGVudCA9IGBVcGRhdGVkICR7bmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoKX1gOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byb2dyZXNzUmluZ1dyYXAnKS5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICBzZXREb3QoJ29rJyk7CiAgfSBjYXRjaCAoZSkgewogICAgc2V0RG90KCdlcnJvcicpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlcnZpY2VzQ29udGFpbmVyJykuaW5uZXJIVE1MID0gYAogICAgICA8ZGl2IGNsYXNzPSJzdGF0ZS1ib3giPgogICAgICAgIDxkaXYgY2xhc3M9InN0YXRlLWljb24iPuKaoO+4jzwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0YXRlLXRpdGxlIj5Db3VsZCBub3QgbG9hZCBkYXRhPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3RhdGUtZGVzYyI+JHtlLm1lc3NhZ2V9PGJyPjxicj5NYWtlIHN1cmUgdGhlIHNlcnZlciBpcyBydW5uaW5nIGFuZCByZWFjaGFibGUuPC9kaXY+CiAgICAgIDwvZGl2PmA7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2xvYmFsQmFkZ2UnKS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIGVycm9yJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdnbG9iYWxCYWRnZVRleHQnKS50ZXh0Q29udGVudCA9ICdFcnJvcic7CiAgICBzaG93VG9hc3QoJ1JlZnJlc2ggZmFpbGVkOiAnICsgZS5tZXNzYWdlLCAnZXJyb3InKTsKICB9Cn0KCmZ1bmN0aW9uIHNjaGVkdWxlUmVmcmVzaCgpIHsKICBpZiAocmVmcmVzaFRpbWVyKSBjbGVhclRpbWVvdXQocmVmcmVzaFRpbWVyKTsKICBpZiAoY291bnRkb3duVGltZXIpIGNsZWFySW50ZXJ2YWwoY291bnRkb3duVGltZXIpOwogIGNvdW50ZG93blNlYyA9IFJFRlJFU0hfSU5URVJWQUw7CiAgc2V0UHJvZ3Jlc3NSaW5nKFJFRlJFU0hfSU5URVJWQUwsIFJFRlJFU0hfSU5URVJWQUwpOwogIGNvdW50ZG93blRpbWVyID0gc2V0SW50ZXJ2YWwoKCkgPT4gewogICAgY291bnRkb3duU2VjLS07CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmVmcmVzaENvdW50ZG93bicpLnRleHRDb250ZW50ID0gYCR7Y291bnRkb3duU2VjfXNgOwogICAgc2V0UHJvZ3Jlc3NSaW5nKGNvdW50ZG93blNlYywgUkVGUkVTSF9JTlRFUlZBTCk7CiAgICBpZiAoY291bnRkb3duU2VjIDw9IDApIGNsZWFySW50ZXJ2YWwoY291bnRkb3duVGltZXIpOwogIH0sIDEwMDApOwogIHJlZnJlc2hUaW1lciA9IHNldFRpbWVvdXQoYXN5bmMgKCkgPT4geyBhd2FpdCBmZXRjaEFuZFJlbmRlcigpOyBzY2hlZHVsZVJlZnJlc2goKTsgfSwgUkVGUkVTSF9JTlRFUlZBTCAqIDEwMDApOwp9Cgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmVmcmVzaEJ0bicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgYXN5bmMgKCkgPT4gewogIGlmIChyZWZyZXNoVGltZXIpIGNsZWFyVGltZW91dChyZWZyZXNoVGltZXIpOwogIGlmIChjb3VudGRvd25UaW1lcikgY2xlYXJJbnRlcnZhbChjb3VudGRvd25UaW1lcik7CiAgYXdhaXQgZmV0Y2hBbmRSZW5kZXIoKTsKICBzY2hlZHVsZVJlZnJlc2goKTsKfSk7CgpmdW5jdGlvbiBzZXRQcm9ncmVzc1JpbmcociwgdCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9ncmVzc1JpbmcnKS5zdHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gNTYuNSAqICgxIC0gciAvIHQpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyZWZyZXNoQ291bnRkb3duJykudGV4dENvbnRlbnQgPSBgJHtyfXNgOwp9CmZ1bmN0aW9uIHNldERvdChzKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0YXR1c0RvdCcpLmNsYXNzTmFtZSA9ICdwdWxzZS1kb3QnICsgKHMgPT09ICdlcnJvcicgPyAnIGVycm9yJyA6IHMgPT09ICdsb2FkaW5nJyA/ICcgbG9hZGluZycgOiAnJyk7Cn0KCi8vIFJlbmRlcgpmdW5jdGlvbiByZW5kZXJBbGwoKSB7IHJlbmRlclNlcnZpY2VzKCk7IHJlbmRlckluY2lkZW50cygpOyB1cGRhdGVHbG9iYWxTdGF0dXMoKTsgfQoKY29uc3QgSUNPTlMgPSB7CiAgJ0V4Y2hhbmdlJzon8J+TpycsJ1RlYW1zJzon8J+SrCcsJ1NoYXJlUG9pbnQnOifwn5OBJywnT25lRHJpdmUnOifimIHvuI8nLAogICdNaWNyb3NvZnQgMzY1Jzon8J+nqScsJ0VudHJhJzon8J+UkCcsJ0ludHVuZSc6J/Cfk7EnLCdQb3dlciBCSSc6J/Cfk4gnLAogICdQb3dlciBBdXRvbWF0ZSc6J+KaoScsJ1Bvd2VyIEFwcHMnOifwn5SnJywnRHluYW1pY3MnOifwn4+iJywnUGxhbm5lcic6J/Cfk4snLAogICdEZWZlbmRlcic6J/Cfm6HvuI8nLCdWaXZhJzon8J+MsScsJ0NvcGlsb3QnOifwn6SWJywnRm9ybXMnOifwn5OdJywnU3RyZWFtJzon8J+OrCcsCn07CmZ1bmN0aW9uIGdldEljb24obikgewogIGZvciAoY29uc3QgW2ssdl0gb2YgT2JqZWN0LmVudHJpZXMoSUNPTlMpKSBpZiAobi50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKGsudG9Mb3dlckNhc2UoKSkpIHJldHVybiB2OwogIHJldHVybiAn8J+UtSc7Cn0KZnVuY3Rpb24gc3RhdHVzQ2xzKHMpIHsKICBpZiAoIXMpIHJldHVybiAnb2snOwogIGNvbnN0IGwgPSBzLnRvTG93ZXJDYXNlKCk7CiAgaWYgKGwuaW5jbHVkZXMoJ29wZXJhdGlvbmFsJykgJiYgIWwuaW5jbHVkZXMoJ25vbicpKSByZXR1cm4gJ29rJzsKICBpZiAobC5pbmNsdWRlcygnZGVncmFkYXRpb24nKXx8bC5pbmNsdWRlcygnZGVncmFkZWQnKXx8bC5pbmNsdWRlcygnYWR2aXNvcnknKXx8CiAgICAgIGwuaW5jbHVkZXMoJ2ludmVzdGlnYXRpbmcnKXx8bC5pbmNsdWRlcygncmVzdG9yaW5nJyl8fGwuaW5jbHVkZXMoJ3Jlc3RvcmVkJyl8fAogICAgICBsLmluY2x1ZGVzKCdyZWR1Y2VkJyl8fGwuaW5jbHVkZXMoJ2V4dGVuZGVkJykpIHJldHVybiAnd2FybmluZyc7CiAgcmV0dXJuICdlcnJvcic7Cn0KZnVuY3Rpb24gc3RhdHVzTGFiZWwocykgewogIGlmICghcykgcmV0dXJuICdVbmtub3duJzsKICBjb25zdCBtID0gewogICAgc2VydmljZW9wZXJhdGlvbmFsOidPcGVyYXRpb25hbCcsIGludmVzdGlnYXRpbmc6J0ludmVzdGlnYXRpbmcnLAogICAgcmVzdG9yaW5nc2VydmljZTonUmVzdG9yaW5nJywgdmVyaWZ5aW5nc2VydmljZTonVmVyaWZ5aW5nJywKICAgIHNlcnZpY2VkZWdyYWRhdGlvbjonRGVncmFkZWQnLCBzZXJ2aWNlaW50ZXJydXB0aW9uOidPdXRhZ2UnLAogICAgZXh0ZW5kZWRyZWNvdmVyeTonRXh0ZW5kZWQgUmVjb3ZlcnknLCBmYWxzZXBvc2l0aXZlOidGYWxzZSBQb3NpdGl2ZScsCiAgICBpbnZlc3RpZ2F0aW9uc3VzcGVuZGVkOidTdXNwZW5kZWQnLCByZXNvbHZlZDonUmVzb2x2ZWQnLAogICAgcG9zdGluY2lkZW50cmV2aWV3cHVibGlzaGVkOidQSVIgUHVibGlzaGVkJywgc2VydmljZXJlZHVjZWQ6J1JlZHVjZWQnLAogIH07CiAgcmV0dXJuIG1bcy50b0xvd2VyQ2FzZSgpXSB8fCBzOwp9CgpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcygpIHsKICBsZXQgc3ZjcyA9IGFsbFNlcnZpY2VzOwogIGlmIChhY3RpdmVGaWx0ZXIgPT09ICdpc3N1ZXMnKSBzdmNzID0gc3Zjcy5maWx0ZXIocyA9PiBzdGF0dXNDbHMocy5zdGF0dXMpICE9PSAnb2snKTsKICBlbHNlIGlmIChhY3RpdmVGaWx0ZXIgIT09ICdhbGwnKSBzdmNzID0gc3Zjcy5maWx0ZXIocyA9PiBzLnNlcnZpY2UgPT09IGFjdGl2ZUZpbHRlcik7CiAgY29uc3QgY29udGFpbmVyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlcnZpY2VzQ29udGFpbmVyJyk7CiAgY29udGFpbmVyLmlubmVySFRNTCA9ICcnOwogIGlmICghc3Zjcy5sZW5ndGgpIHsKICAgIGNvbnRhaW5lci5pbm5lckhUTUwgPSBgPGRpdiBjbGFzcz0ic3RhdGUtYm94Ij48ZGl2IGNsYXNzPSJzdGF0ZS1pY29uIj7inIU8L2Rpdj48ZGl2IGNsYXNzPSJzdGF0ZS10aXRsZSI+QWxsIHNlcnZpY2VzIG9wZXJhdGlvbmFsPC9kaXY+PGRpdiBjbGFzcz0ic3RhdGUtZGVzYyI+Tm8gaXNzdWVzIG1hdGNoIHRoZSBjdXJyZW50IGZpbHRlci48L2Rpdj48L2Rpdj5gOwogICAgcmV0dXJuOwogIH0KICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgY29uc3QgaCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBoLmNsYXNzTmFtZSA9ICdzZWN0aW9uLXRpdGxlJzsKICBoLnRleHRDb250ZW50ID0gYFNlcnZpY2VzICgke3N2Y3MubGVuZ3RofSlgOyB3cmFwLmFwcGVuZENoaWxkKGgpOwogIGNvbnN0IGdyaWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZ3JpZC5jbGFzc05hbWUgPSAnc2VydmljZS1ncmlkJzsKICBzdmNzLmZvckVhY2goc3ZjID0+IHsKICAgIGNvbnN0IGNscyA9IHN0YXR1c0NscyhzdmMuc3RhdHVzKTsKICAgIGNvbnN0IGNhcmQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIGNhcmQuY2xhc3NOYW1lID0gYHNlcnZpY2UtY2FyZCR7Y2xzICE9PSAnb2snID8gJyAnK2NscyA6ICcnfWA7CiAgICBjYXJkLnRpdGxlID0gc3ZjLnNlcnZpY2U7CiAgICBjYXJkLmlubmVySFRNTCA9IGAKICAgICAgPGRpdiBjbGFzcz0ic2VydmljZS1pY29uIj4ke2dldEljb24oc3ZjLnNlcnZpY2UpfTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZXJ2aWNlLWluZm8iPgogICAgICAgIDxkaXYgY2xhc3M9InNlcnZpY2UtbmFtZSI+JHtzdmMuc2VydmljZX08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZXJ2aWNlLXN0YXR1cy10ZXh0ICR7Y2xzfSI+JHtzdGF0dXNMYWJlbChzdmMuc3RhdHVzKX08L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlcnZpY2UtZG90JHtjbHMgIT09ICdvaycgPyAnICcrY2xzIDogJyd9Ij48L2Rpdj5gOwogICAgZ3JpZC5hcHBlbmRDaGlsZChjYXJkKTsKICB9KTsKICB3cmFwLmFwcGVuZENoaWxkKGdyaWQpOwogIGNvbnRhaW5lci5hcHBlbmRDaGlsZCh3cmFwKTsKfQoKZnVuY3Rpb24gcmVuZGVySW5jaWRlbnRzKCkgewogIGNvbnN0IHNlY3Rpb24gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5jaWRlbnRzU2VjdGlvbicpOwogIGNvbnN0IGxpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5jaWRlbnRzTGlzdCcpOwogIGxpc3QuaW5uZXJIVE1MID0gJyc7CiAgbGV0IGlzc3VlcyA9IGFsbElzc3VlczsKICBpZiAoYWN0aXZlRmlsdGVyICE9PSAnYWxsJyAmJiBhY3RpdmVGaWx0ZXIgIT09ICdpc3N1ZXMnKSBpc3N1ZXMgPSBpc3N1ZXMuZmlsdGVyKGkgPT4gaS5zZXJ2aWNlID09PSBhY3RpdmVGaWx0ZXIpOwogIGlmICghaXNzdWVzLmxlbmd0aCkgeyBzZWN0aW9uLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7IHJldHVybjsgfQogIHNlY3Rpb24uc3R5bGUuZGlzcGxheSA9ICcnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbmNpZGVudHNTZWN0aW9uVGl0bGUnKS50ZXh0Q29udGVudCA9IGBBY3RpdmUgSXNzdWVzICgke2lzc3Vlcy5sZW5ndGh9KWA7CiAgaXNzdWVzLmZvckVhY2goaXNzdWUgPT4gewogICAgY29uc3QgY2xzID0gKGlzc3VlLmNsYXNzaWZpY2F0aW9ufHwnJykudG9Mb3dlckNhc2UoKSA9PT0gJ2luY2lkZW50JyA/ICdpbmNpZGVudCcgOiAnYWR2aXNvcnknOwogICAgY29uc3QgbW9kVGltZSA9IGlzc3VlLmxhc3RNb2RpZmllZERhdGVUaW1lID8gdGltZVNpbmNlKG5ldyBEYXRlKGlzc3VlLmxhc3RNb2RpZmllZERhdGVUaW1lKSkgOiAn4oCUJzsKICAgIGNvbnN0IHN0YXJ0VGltZSA9IGlzc3VlLnN0YXJ0RGF0ZVRpbWUgPyBuZXcgRGF0ZShpc3N1ZS5zdGFydERhdGVUaW1lKS50b0xvY2FsZVN0cmluZygpIDogJ+KAlCc7CiAgICBjb25zdCBwb3N0cyA9IChpc3N1ZS5wb3N0c3x8W10pLnNsaWNlKCkucmV2ZXJzZSgpLnNsaWNlKDAsNSkubWFwKHAgPT4gewogICAgICBjb25zdCB0eHQgPSBwLmRlc2NyaXB0aW9uPy5jb250ZW50ID8gc3RyaXBIdG1sKHAuZGVzY3JpcHRpb24uY29udGVudCkuc3Vic3RyaW5nKDAsNjAwKSA6ICcnOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVwZGF0ZS1lbnRyeSI+PGRpdiBjbGFzcz0idXBkYXRlLXRpbWUiPiR7bmV3IERhdGUocC5jcmVhdGVkRGF0ZVRpbWUpLnRvTG9jYWxlU3RyaW5nKCl9PC9kaXY+PGRpdiBjbGFzcz0idXBkYXRlLXRleHQiPiR7dHh0fTwvZGl2PjwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICAgIGNvbnN0IGNhcmQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIGNhcmQuY2xhc3NOYW1lID0gYGluY2lkZW50LWNhcmQgJHtjbHN9YDsKICAgIGNhcmQuaW5uZXJIVE1MID0gYAogICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1oZWFkZXIiIG9uY2xpY2s9InRvZ2dsZUluY2lkZW50KHRoaXMpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1tYWluIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXRvcCI+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJpbmNpZGVudC1pZCI+JHtpc3N1ZS5pZH08L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJ0eXBlLXBpbGwgJHtjbHN9Ij4ke2Nsc308L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJzdGF0dXMtcGlsbCI+JHtzdGF0dXNMYWJlbChpc3N1ZS5zdGF0dXMpfTwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtdGl0bGUiPiR7aXNzdWUudGl0bGV8fCdVbnRpdGxlZCBJc3N1ZSd9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1zZXJ2aWNlIj4ke2lzc3VlLnNlcnZpY2V8fCcnfSR7aXNzdWUuZmVhdHVyZT8nIMK3ICcraXNzdWUuZmVhdHVyZTonJ308L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1tZXRhIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXRpbWUiPlVwZGF0ZWQgJHttb2RUaW1lfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtdGltZSI+U3RhcnRlZCAke3N0YXJ0VGltZX08L2Rpdj4KICAgICAgICAgIDxzdmcgY2xhc3M9ImNoZXZyb24iIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cG9seWxpbmUgcG9pbnRzPSI2IDkgMTIgMTUgMTggOSIvPjwvc3ZnPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtYm9keSI+CiAgICAgICAgJHtpc3N1ZS5pbXBhY3REZXNjcmlwdGlvbj9gPHAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci10ZXh0KTttYXJnaW4tdG9wOnZhcigtLXNwYWNlLTQpIj4ke2lzc3VlLmltcGFjdERlc2NyaXB0aW9ufTwvcD5gOicnfQogICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXVwZGF0ZXMiPiR7cG9zdHN8fCc8cCBzdHlsZT0iZm9udC1zaXplOnZhcigtLXRleHQteHMpO2NvbG9yOnZhcigtLWNvbG9yLXRleHQtbXV0ZWQpIj5ObyB1cGRhdGVzIHlldC48L3A+J308L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIGxpc3QuYXBwZW5kQ2hpbGQoY2FyZCk7CiAgfSk7Cn0KCmZ1bmN0aW9uIHRvZ2dsZUluY2lkZW50KGgpIHsKICBoLm5leHRFbGVtZW50U2libGluZy5jbGFzc0xpc3QudG9nZ2xlKCdvcGVuJyk7CiAgaC5xdWVyeVNlbGVjdG9yKCcuY2hldnJvbicpLmNsYXNzTGlzdC50b2dnbGUoJ29wZW4nKTsKfQoKZnVuY3Rpb24gdXBkYXRlR2xvYmFsU3RhdHVzKCkgewogIGNvbnN0IGluY2lkZW50cyA9IGFsbElzc3Vlcy5maWx0ZXIoaSA9PiAoaS5jbGFzc2lmaWNhdGlvbnx8JycpLnRvTG93ZXJDYXNlKCk9PT0naW5jaWRlbnQnKTsKICBjb25zdCBhZHZpc29yaWVzID0gYWxsSXNzdWVzLmZpbHRlcihpID0+IChpLmNsYXNzaWZpY2F0aW9ufHwnJykudG9Mb3dlckNhc2UoKT09PSdhZHZpc29yeScpOwogIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dsb2JhbEJhZGdlJyk7CiAgY29uc3QgdGV4dCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2xvYmFsQmFkZ2VUZXh0Jyk7CiAgaWYgKGluY2lkZW50cy5sZW5ndGgpIHsKICAgIGJhZGdlLmNsYXNzTmFtZSA9ICdzdGF0dXMtYmFkZ2UgZXJyb3InOwogICAgdGV4dC50ZXh0Q29udGVudCA9IGAke2luY2lkZW50cy5sZW5ndGh9IEFjdGl2ZSBJbmNpZGVudCR7aW5jaWRlbnRzLmxlbmd0aD4xPydzJzonJ31gOwogIH0gZWxzZSBpZiAoYWR2aXNvcmllcy5sZW5ndGgpIHsKICAgIGJhZGdlLmNsYXNzTmFtZSA9ICdzdGF0dXMtYmFkZ2Ugd2FybmluZyc7CiAgICB0ZXh0LnRleHRDb250ZW50ID0gYCR7YWR2aXNvcmllcy5sZW5ndGh9IEFkdmlzb3J5JHthZHZpc29yaWVzLmxlbmd0aD4xPycgSXNzdWVzJzonJ31gOwogIH0gZWxzZSB7CiAgICBiYWRnZS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIG9rJzsKICAgIHRleHQudGV4dENvbnRlbnQgPSAnQWxsIFNlcnZpY2VzIE9wZXJhdGlvbmFsJzsKICB9Cn0KCmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmaWx0ZXJUYWJzJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICBjb25zdCB0YWIgPSBlLnRhcmdldC5jbG9zZXN0KCcuZmlsdGVyLXRhYicpOwogIGlmICghdGFiKSByZXR1cm47CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmZpbHRlci10YWInKS5mb3JFYWNoKHQgPT4gdC5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgdGFiLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGFjdGl2ZUZpbHRlciA9IHRhYi5kYXRhc2V0LmZpbHRlcjsKICByZW5kZXJBbGwoKTsKfSk7CgpmdW5jdGlvbiBzaG93U2tlbGV0b25zKCkgewogIGNvbnN0IGdyaWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZ3JpZC5jbGFzc05hbWUgPSAnc2VydmljZS1ncmlkJzsKICBmb3IgKGxldCBpID0gMDsgaSA8IDEyOyBpKyspIHsKICAgIGNvbnN0IGMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgYy5jbGFzc05hbWUgPSAnc2VydmljZS1jYXJkJzsKICAgIGMuaW5uZXJIVE1MID0gYDxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0id2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjhweDtmbGV4LXNocmluazowIj48L2Rpdj48ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0iaGVpZ2h0OjEycHg7d2lkdGg6ODAlO21hcmdpbi1ib3R0b206NnB4Ij48L2Rpdj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMHB4O3dpZHRoOjU1JSI+PC9kaXY+PC9kaXY+YDsKICAgIGdyaWQuYXBwZW5kQ2hpbGQoYyk7CiAgfQogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZXJ2aWNlc0NvbnRhaW5lcicpLmlubmVySFRNTCA9ICcnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZXJ2aWNlc0NvbnRhaW5lcicpLmFwcGVuZENoaWxkKGdyaWQpOwp9CgpmdW5jdGlvbiB0aW1lU2luY2UoZCkgewogIGNvbnN0IG0gPSBNYXRoLmZsb29yKChEYXRlLm5vdygpLWQpLzYwMDAwKTsKICBpZiAobTwxKSByZXR1cm4gJ2p1c3Qgbm93JzsKICBpZiAobTw2MCkgcmV0dXJuIGAke219bSBhZ29gOwogIGNvbnN0IGggPSBNYXRoLmZsb29yKG0vNjApOwogIHJldHVybiBoPDI0P2Ake2h9aCBhZ29gOmAke01hdGguZmxvb3IoaC8yNCl9ZCBhZ29gOwp9CmZ1bmN0aW9uIHN0cmlwSHRtbChodG1sKSB7CiAgY29uc3QgZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBkLmlubmVySFRNTCA9IGh0bWw7CiAgcmV0dXJuIGQudGV4dENvbnRlbnR8fGQuaW5uZXJUZXh0fHwnJzsKfQpmdW5jdGlvbiBzaG93VG9hc3QobXNnLCB0eXBlPSdzdWNjZXNzJykgewogIGNvbnN0IHQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgdC5jbGFzc05hbWU9YHRvYXN0ICR7dHlwZX1gOyB0LnRleHRDb250ZW50PW1zZzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndG9hc3RDb250YWluZXInKS5hcHBlbmRDaGlsZCh0KTsKICBzZXRUaW1lb3V0KCgpPT50LnJlbW92ZSgpLCA0MDAwKTsKfQoKZmV0Y2hBbmRSZW5kZXIoKS50aGVuKCgpPT5zY2hlZHVsZVJlZnJlc2goKSk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K" | base64 -d > "$APP_DIR/public/index.html"
info "public/index.html written"

# ── Write config.json (only if not already created by az-setup.sh) ────────────
section "Writing config.json"
if [ -f "$APP_DIR/config.json" ]; then
  info "config.json already exists (created by az-setup.sh) — skipping"
else
  warn "No config.json found. Writing placeholder — edit before starting the service."
  cat > "$APP_DIR/config.json" << 'CFGEOF'
{
  "tenantId":    "YOUR_TENANT_ID",
  "clientId":    "YOUR_CLIENT_ID",
  "clientSecret":"YOUR_CLIENT_SECRET",
  "port":        3000
}
CFGEOF
  info "config.json placeholder written — fill in credentials or run az-setup.sh"
fi

# ── Write config.example.json ─────────────────────────────────
cat > "$APP_DIR/config.example.json" << 'EXEOF'
{
  "comment":      "Fill in tenantId + clientId and EITHER clientSecret OR certPath+certKeyPath",
  "tenantId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",

  "clientSecret": "your-client-secret-here",

  "certPath":     "/opt/m365-dashboard/certs/m365dash.crt",
  "certKeyPath":  "/opt/m365-dashboard/certs/m365dash.key",
  "thumbprint":   "AABBCCDDEEFF...",

  "port":         3000
}
EXEOF
info "config.example.json written"

# ── Dedicated service user ────────────────────────────────────
section "Creating service user"
if id "$SERVICE_USER" &>/dev/null; then
  info "User '$SERVICE_USER' already exists"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  info "User '$SERVICE_USER' created"
fi

# ── Permissions ───────────────────────────────────────────────
section "Setting permissions"
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"
chmod 750 "$APP_DIR"
chmod 640 "$APP_DIR/config.json"
# Protect cert key if present
[ -d "$APP_DIR/certs" ] && chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR/certs" && chmod 700 "$APP_DIR/certs" && chmod 600 "$APP_DIR/certs/"*.key 2>/dev/null || true
info "config.json readable by service user only (mode 640)"

# ── Systemd unit ──────────────────────────────────────────────
section "Creating systemd service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SVCEOF
[Unit]
Description=M365 Service Health Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
ExecStart=$(which node) ${APP_DIR}/server.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
SVCEOF
info "Systemd unit created"

# ── Enable + start ────────────────────────────────────────────
section "Enabling and starting service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null

# Only start if config.json has real credentials
if grep -q "YOUR_TENANT_ID" "$APP_DIR/config.json" 2>/dev/null; then
  warn "config.json still has placeholder values — service NOT started"
  warn "Run az-setup.sh or edit config.json manually, then: systemctl start ${SERVICE_NAME}"
else
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "Service is running"
  else
    warn "Service may have failed. Check with:  journalctl -u ${SERVICE_NAME} -n 30"
  fi
fi

# ── nginx configuration ───────────────────────────────────────
section "Configuring nginx reverse proxy"

if [[ "$USE_TLS" == "y" || "$USE_TLS" == "yes" ]]; then
  NGINX_CONF="/etc/nginx/sites-available/m365-dashboard"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

  cat > "$NGINX_CONF" << NGINXEOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF

  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/m365-dashboard 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t && systemctl reload nginx
  info "nginx HTTP config applied (port 80 ready for ACME challenge)"

  section "Installing Certbot"
  if ! command -v certbot &>/dev/null; then
    if [ "$PKG_MGR" = "apt" ]; then
      apt-get install -y -q certbot python3-certbot-nginx
    elif [ "$PKG_MGR" = "dnf" ]; then
      dnf install -y -q certbot python3-certbot-nginx
    else
      yum install -y -q certbot python3-certbot-nginx
    fi
    info "Certbot installed"
  else
    info "Certbot already installed"
  fi

  section "Obtaining Let's Encrypt certificate"
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL_LE" \
    --domains "$DOMAIN" \
    --redirect
  info "Certificate issued and nginx updated for HTTPS"

  cat > "$NGINX_CONF" << NGINXEOF2
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection keep-alive;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
NGINXEOF2

  nginx -t && systemctl reload nginx
  info "nginx HTTPS proxy config applied"

  section "Let's Encrypt auto-renewal"
  if systemctl list-timers --all | grep -q certbot; then
    info "certbot renewal timer already active"
  else
    CRON_FILE="/etc/cron.d/certbot-renew"
    echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    info "Auto-renewal cron job created (/etc/cron.d/certbot-renew)"
  fi

else
  NGINX_CONF="/etc/nginx/sites-available/m365-dashboard"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

  cat > "$NGINX_CONF" << NGINXEOF3
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }
}
NGINXEOF3

  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/m365-dashboard 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t && systemctl reload nginx
  info "nginx HTTP proxy applied (no TLS)"
fi

# ── Firewall ──────────────────────────────────────────────────
section "Firewall"
open_port() {
  local p="$1"
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p/tcp" comment "M365 Dashboard" >/dev/null 2>&1
    info "UFW: port $p opened"
  elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    info "firewalld: port $p opened"
  fi
}

open_port 80
if [[ "$USE_TLS" == "y" || "$USE_TLS" == "yes" ]]; then
  open_port 443
  info "Firewall: ports 80 + 443 opened"
else
  info "Firewall: port 80 opened"
fi

# ── Done ──────────────────────────────────────────────────────
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
if [[ "$USE_TLS" == "y" || "$USE_TLS" == "yes" ]]; then
  echo "  Dashboard  →  https://${DOMAIN}"
  echo "  (HTTP redirects to HTTPS automatically)"
else
  echo "  Dashboard  →  http://${SERVER_IP}:80  (via nginx)"
  echo "  Dashboard  →  http://${SERVER_IP}:${PORT}  (direct Node.js)"
fi
echo ""
echo "  Useful commands:"
echo "    View logs    journalctl -u ${SERVICE_NAME} -f"
echo "    Restart      systemctl restart ${SERVICE_NAME}"
echo "    Stop         systemctl stop ${SERVICE_NAME}"
echo "    Status       systemctl status ${SERVICE_NAME}"
echo "    Renew cert   certbot renew --dry-run"
echo ""
if grep -q "YOUR_TENANT_ID" "$APP_DIR/config.json" 2>/dev/null; then
  echo -e "${YELLOW}  ⚠ Next: run az-setup.sh to create the Azure service account,${NC}"
  echo -e "${YELLOW}    then restart the service:  systemctl restart ${SERVICE_NAME}${NC}"
  echo ""
fi
