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

# ── Uninstall option ──────────────────────────────────────
section "Checking for existing install"
if [ -d "$APP_DIR" ] || systemctl list-units --full -all 2>/dev/null | grep -q "$SERVICE_NAME"; then
  echo ""
  echo "  An existing installation was detected."
  echo "  What would you like to do?"
  echo "  [1] Fresh install (uninstall existing, then reinstall)"
  echo "  [2] Update files only (keep config.json and certs)"
  echo "  [3] Uninstall only"
  echo "  [4] Continue / skip (keep everything, just rerun setup)"
  echo ""
  read -rp "  Choice [1-4]: " INSTALL_MODE
  INSTALL_MODE="${INSTALL_MODE:-4}"

  if [[ "$INSTALL_MODE" == "1" || "$INSTALL_MODE" == "3" ]]; then
    section "Uninstalling existing installation"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    rm -f /etc/nginx/sites-available/m365-dashboard
    rm -f /etc/nginx/sites-enabled/m365-dashboard
    nginx -t && systemctl reload nginx 2>/dev/null || true
    if [[ "$INSTALL_MODE" == "1" ]]; then
      # Save certs and config before wiping
      if [ -d "$APP_DIR/certs" ]; then
        cp -r "$APP_DIR/certs" /tmp/m365-certs-backup 2>/dev/null || true
        info "Certs backed up to /tmp/m365-certs-backup"
      fi
      if [ -f "$APP_DIR/config.json" ]; then
        cp "$APP_DIR/config.json" /tmp/m365-config-backup.json 2>/dev/null || true
        info "config.json backed up to /tmp/m365-config-backup.json"
      fi
      rm -rf "$APP_DIR"
      userdel -r "$SERVICE_USER" 2>/dev/null || true
      info "Existing installation removed"
    else
      rm -rf "$APP_DIR"
      userdel -r "$SERVICE_USER" 2>/dev/null || true
      info "Uninstall complete"
      exit 0
    fi
  elif [[ "$INSTALL_MODE" == "2" ]]; then
    # Preserve config and certs
    [ -f "$APP_DIR/config.json" ] && cp "$APP_DIR/config.json" /tmp/m365-config-backup.json
    [ -d "$APP_DIR/certs" ]      && cp -r "$APP_DIR/certs" /tmp/m365-certs-backup
    info "Config and certs preserved"
  fi
fi


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
const { tenantId, clientId, clientSecret, certPath, certKeyPath, thumbprint, port: cfgPort, subscriptionId } = cfg;

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

// ── ARM token cache ───────────────────────────────────────────────────────────
let cachedArmToken = null;
let armTokenExpiry = 0;

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

// ── ARM token acquisition (management.azure.com scope) ───────────────────────
async function getArmToken() {
  if (cachedArmToken && Date.now() < armTokenExpiry) return cachedArmToken;

  let body;
  if (USE_CERT) {
    const assertion = buildClientAssertion();
    body = new URLSearchParams({
      grant_type:            'client_credentials',
      client_id:             clientId,
      client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
      client_assertion:      assertion,
      scope:                 'https://management.azure.com/.default',
    }).toString();
  } else {
    body = new URLSearchParams({
      grant_type:    'client_credentials',
      client_id:     clientId,
      client_secret: clientSecret,
      scope:         'https://management.azure.com/.default',
    }).toString();
  }

  const data = await httpsPost(
    `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`,
    { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  );

  if (!data.access_token) {
    throw new Error(data.error_description || data.error || 'Failed to acquire ARM token');
  }

  cachedArmToken = data.access_token;
  armTokenExpiry = Date.now() + (data.expires_in - 60) * 1000;
  return cachedArmToken;
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

// ── Raw HTTPS GET (returns string, not parsed JSON) ──────────────────────────
function httpsGetRaw(url) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const opts = { hostname: u.hostname, path: u.pathname + u.search, method: 'GET',
      headers: { 'User-Agent': 'M365-Dashboard/1.0', 'Accept': 'application/rss+xml, application/xml, text/xml' } };
    const req = https.request(opts, res => {
      // Follow one redirect
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return httpsGetRaw(res.headers.location).then(resolve).catch(reject);
      }
      let raw = '';
      res.on('data', c => raw += c);
      res.on('end', () => resolve(raw));
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
      console.error('[/api/health]', e.message);
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
      console.error('[/api/issues]', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (url === '/api/m365-history') {
    try {
      const params = new URL('http://localhost' + req.url).searchParams;
      const days = Math.min(Math.max(parseInt(params.get('days') || '30', 10), 1), 180);
      const since = new Date(Date.now() - days * 86400000).toISOString();
      const qs = encodeURIComponent(`isResolved eq true and lastModifiedDateTime ge ${since}`);
      const data = await graphGet(
        `/admin/serviceAnnouncement/issues?$filter=${qs}&$orderby=lastModifiedDateTime desc&$top=100`
      );
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (url === '/api/azure-history') {
    try {
      if (!subscriptionId) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'subscriptionId not set in config.json' }));
        return;
      }
      const params = new URL('http://localhost' + req.url).searchParams;
      const days = Math.min(Math.max(parseInt(params.get('days') || '30', 10), 1), 180);
      const since = new Date(Date.now() - days * 86400000);
      const token = await getArmToken();

      const result = await httpsGet(
        `https://management.azure.com/subscriptions/${subscriptionId}/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01`,
        { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' }
      );

      if (result.body.error) throw new Error(result.body.error.message || JSON.stringify(result.body.error));

      const allEvents = result.body.value || [];
      // Filter to resolved/mitigated events within the date range
      const filtered = allEvents.filter(e => {
        const p = e.properties || {};
        const status = (p.status || '').toLowerCase();
        const mitTime = p.impactMitigationTime ? new Date(p.impactMitigationTime) : null;
        const isResolved = status === 'resolved' || status === 'mitigated';
        return isResolved && mitTime && mitTime >= since;
      });

      // Normalize to consistent shape
      const data = filtered.map(e => {
        const p = e.properties || {};
        return {
          trackingId:      p.trackingId || e.name,
          title:           p.title || '',
          summary:         p.summary || '',
          header:          p.header || '',
          eventType:       p.eventType || '',
          status:          p.status || '',
          impactStartTime: p.impactStartTime || null,
          lastUpdateTime:  p.lastUpdateTime || null,
          mitigationTime:  p.impactMitigationTime || null,
          impact:          p.impact || [],
          level:           p.level || '',
        };
      }).sort((a, b) => new Date(b.mitigationTime) - new Date(a.mitigationTime));

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data, count: data.length }));
    } catch (e) {
      console.error('[/api/azure-history]', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (url === '/api/azure-status') {
    try {
      if (!subscriptionId) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'subscriptionId not set in config.json' }));
        return;
      }
      const token = await getArmToken();

      const result = await httpsGet(
        `https://management.azure.com/subscriptions/${subscriptionId}/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01`,
        { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' }
      );

      if (result.body.error) throw new Error(result.body.error.message || JSON.stringify(result.body.error));

      const allEvents = result.body.value || [];
      // Only active events
      const active = allEvents.filter(e => {
        const status = ((e.properties || {}).status || '').toLowerCase();
        return status === 'active';
      });

      const data = active.map(e => {
        const p = e.properties || {};
        return {
          trackingId:      p.trackingId || e.name,
          title:           p.title || '',
          summary:         p.summary || '',
          header:          p.header || '',
          eventType:       p.eventType || '',
          status:          p.status || '',
          impactStartTime: p.impactStartTime || null,
          lastUpdateTime:  p.lastUpdateTime || null,
          mitigationTime:  p.impactMitigationTime || null,
          impact:          p.impact || [],
          level:           p.level || '',
        };
      });

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data, count: data.length }));
    } catch (e) {
      console.error('[/api/azure-status]', e.message);
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
echo "PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIiBkYXRhLXRoZW1lPSJkYXJrIj4KPGhlYWQ+CiAgPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CiAgPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiIC8+CiAgPHRpdGxlPk0zNjUgJmFtcDsgQXp1cmUgU2VydmljZSBIZWFsdGg8L3RpdGxlPgogIDxsaW5rIHJlbD0icHJlY29ubmVjdCIgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbSIgLz4KICA8bGluayByZWw9InByZWNvbm5lY3QiIGhyZWY9Imh0dHBzOi8vZm9udHMuZ3N0YXRpYy5jb20iIGNyb3Nzb3JpZ2luIC8+CiAgPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1JbnRlcjp3Z2h0QDMwMC4uNzAwJmZhbWlseT1KZXRCcmFpbnMrTW9ubzp3Z2h0QDQwMDs1MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiIC8+CiAgPHN0eWxlPgogICAgOnJvb3QgewogICAgICAtLXRleHQteHM6IGNsYW1wKDAuNzVyZW0sIDAuN3JlbSArIDAuMjV2dywgMC44NzVyZW0pOwogICAgICAtLXRleHQtc206IGNsYW1wKDAuODc1cmVtLCAwLjhyZW0gKyAwLjM1dncsIDFyZW0pOwogICAgICAtLXRleHQtYmFzZTogY2xhbXAoMXJlbSwgMC45NXJlbSArIDAuMjV2dywgMS4xMjVyZW0pOwogICAgICAtLXRleHQtbGc6IGNsYW1wKDEuMTI1cmVtLCAxcmVtICsgMC43NXZ3LCAxLjVyZW0pOwogICAgICAtLXNwYWNlLTE6IDAuMjVyZW07IC0tc3BhY2UtMjogMC41cmVtOyAtLXNwYWNlLTM6IDAuNzVyZW07CiAgICAgIC0tc3BhY2UtNDogMXJlbTsgICAgLS1zcGFjZS01OiAxLjI1cmVtOyAtLXNwYWNlLTY6IDEuNXJlbTsKICAgICAgLS1zcGFjZS04OiAycmVtOyAgICAtLXNwYWNlLTEwOiAyLjVyZW07CiAgICAgIC0tcmFkaXVzLXNtOiAwLjM3NXJlbTsgLS1yYWRpdXMtbWQ6IDAuNXJlbTsgLS1yYWRpdXMtbGc6IDAuNzVyZW07CiAgICAgIC0tdHJhbnNpdGlvbjogMTYwbXMgY3ViaWMtYmV6aWVyKDAuMTYsIDEsIDAuMywgMSk7CiAgICAgIC0tZm9udC1ib2R5OiAnSW50ZXInLCBzeXN0ZW0tdWksIHNhbnMtc2VyaWY7CiAgICAgIC0tZm9udC1tb25vOiAnSmV0QnJhaW5zIE1vbm8nLCBtb25vc3BhY2U7CiAgICB9CiAgICBbZGF0YS10aGVtZT0nZGFyayddIHsKICAgICAgLS1jb2xvci1iZzogICAgICAgICAgIzBkMTExNzsKICAgICAgLS1jb2xvci1zdXJmYWNlOiAgICAgIzE2MWIyMjsKICAgICAgLS1jb2xvci1zdXJmYWNlLTI6ICAgIzFjMjEyODsKICAgICAgLS1jb2xvci1ib3JkZXI6ICAgICAgIzMwMzYzZDsKICAgICAgLS1jb2xvci1kaXZpZGVyOiAgICAgIzIxMjYyZDsKICAgICAgLS1jb2xvci10ZXh0OiAgICAgICAgI2U2ZWRmMzsKICAgICAgLS1jb2xvci10ZXh0LW11dGVkOiAgIzhiOTQ5ZTsKICAgICAgLS1jb2xvci10ZXh0LWZhaW50OiAgIzQ4NGY1ODsKICAgICAgLS1jb2xvci1wcmltYXJ5OiAgICAgIzM4OGJmZDsKICAgICAgLS1jb2xvci1wcmltYXJ5LWRpbTogIzFmM2Y2ZTsKICAgICAgLS1jb2xvci1henVyZTogICAgICAgIzAwNzhkNDsKICAgICAgLS1jb2xvci1henVyZS1kaW06ICAgIzBkMmE0YTsKICAgICAgLS1jb2xvci1zdWNjZXNzOiAgICAgIzNmYjk1MDsKICAgICAgLS1jb2xvci1zdWNjZXNzLWRpbTogIzFhM2QyNDsKICAgICAgLS1jb2xvci13YXJuaW5nOiAgICAgI2QyOTkyMjsKICAgICAgLS1jb2xvci13YXJuaW5nLWRpbTogIzNkMmYwZTsKICAgICAgLS1jb2xvci1lcnJvcjogICAgICAgI2Y4NTE0OTsKICAgICAgLS1jb2xvci1lcnJvci1kaW06ICAgIzRhMWExYTsKICAgICAgLS1zaGFkb3ctc206IDAgMXB4IDNweCByZ2JhKDAsMCwwLDAuNCk7CiAgICAgIC0tc2hhZG93LW1kOiAwIDRweCAxNnB4IHJnYmEoMCwwLDAsMC41KTsKICAgIH0KICAgIFtkYXRhLXRoZW1lPSdsaWdodCddIHsKICAgICAgLS1jb2xvci1iZzogICAgICAgICAgI2YwZjJmNTsKICAgICAgLS1jb2xvci1zdXJmYWNlOiAgICAgI2ZmZmZmZjsKICAgICAgLS1jb2xvci1zdXJmYWNlLTI6ICAgI2Y2ZjhmYTsKICAgICAgLS1jb2xvci1ib3JkZXI6ICAgICAgI2QwZDdkZTsKICAgICAgLS1jb2xvci1kaXZpZGVyOiAgICAgI2U0ZThlZDsKICAgICAgLS1jb2xvci10ZXh0OiAgICAgICAgIzFmMjMyODsKICAgICAgLS1jb2xvci10ZXh0LW11dGVkOiAgIzY1NmQ3NjsKICAgICAgLS1jb2xvci10ZXh0LWZhaW50OiAgIzkxOThhMTsKICAgICAgLS1jb2xvci1wcmltYXJ5OiAgICAgIzA5NjlkYTsKICAgICAgLS1jb2xvci1wcmltYXJ5LWRpbTogI2RkZjRmZjsKICAgICAgLS1jb2xvci1henVyZTogICAgICAgIzAwNzhkNDsKICAgICAgLS1jb2xvci1henVyZS1kaW06ICAgI2U4ZjRmZjsKICAgICAgLS1jb2xvci1zdWNjZXNzOiAgICAgIzFhN2YzNzsKICAgICAgLS1jb2xvci1zdWNjZXNzLWRpbTogI2RhZmJlMTsKICAgICAgLS1jb2xvci13YXJuaW5nOiAgICAgIzlhNjcwMDsKICAgICAgLS1jb2xvci13YXJuaW5nLWRpbTogI2ZmZjhjNTsKICAgICAgLS1jb2xvci1lcnJvcjogICAgICAgI2QxMjQyZjsKICAgICAgLS1jb2xvci1lcnJvci1kaW06ICAgI2ZmZWJlOTsKICAgICAgLS1zaGFkb3ctc206IDAgMXB4IDNweCByZ2JhKDAsMCwwLDAuMDgpOwogICAgICAtLXNoYWRvdy1tZDogMCA0cHggMTZweCByZ2JhKDAsMCwwLDAuMTApOwogICAgfQogICAgKiwgKjo6YmVmb3JlLCAqOjphZnRlciB7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjogMDsgcGFkZGluZzogMDsgfQogICAgaHRtbCB7IC13ZWJraXQtZm9udC1zbW9vdGhpbmc6IGFudGlhbGlhc2VkOyB0ZXh0LXJlbmRlcmluZzogb3B0aW1pemVMZWdpYmlsaXR5OyBzY3JvbGwtYmVoYXZpb3I6IHNtb290aDsgfQogICAgYm9keSB7IGZvbnQtZmFtaWx5OiB2YXIoLS1mb250LWJvZHkpOyBmb250LXNpemU6IHZhcigtLXRleHQtc20pOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLWJnKTsgbWluLWhlaWdodDogMTAwZHZoOyBsaW5lLWhlaWdodDogMS42OyB9CiAgICBidXR0b24geyBjdXJzb3I6IHBvaW50ZXI7IGJhY2tncm91bmQ6IG5vbmU7IGJvcmRlcjogbm9uZTsgZm9udDogaW5oZXJpdDsgY29sb3I6IGluaGVyaXQ7IH0KICAgIGEsIGJ1dHRvbiB7IHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyYW5zaXRpb24pLCBiYWNrZ3JvdW5kIHZhcigtLXRyYW5zaXRpb24pLCBib3JkZXItY29sb3IgdmFyKC0tdHJhbnNpdGlvbiksIG9wYWNpdHkgdmFyKC0tdHJhbnNpdGlvbik7IH0KICAgIC5hcHAgeyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBtaW4taGVpZ2h0OiAxMDBkdmg7IH0KCiAgICAvKiBIZWFkZXIgKi8KICAgIC5oZWFkZXIgeyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47IHBhZGRpbmc6IHZhcigtLXNwYWNlLTMpIHZhcigtLXNwYWNlLTYpOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IHBvc2l0aW9uOiBzdGlja3k7IHRvcDogMDsgei1pbmRleDogMTAwOyBnYXA6IHZhcigtLXNwYWNlLTQpOyB9CiAgICAubG9nbyB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogdmFyKC0tc3BhY2UtMik7IH0KICAgIC5sb2dvLXRleHQgeyBmb250LXNpemU6IHZhcigtLXRleHQtc20pOyBmb250LXdlaWdodDogNjAwOyBsZXR0ZXItc3BhY2luZzogLTAuMDFlbTsgfQogICAgLmxvZ28tc3ViIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyB9CiAgICAuaGVhZGVyLXJpZ2h0IHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgfQogICAgLnJlZnJlc2gtaW5mbyB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgZm9udC1mYW1pbHk6IHZhcigtLWZvbnQtbW9ubyk7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogdmFyKC0tc3BhY2UtMik7IH0KICAgIC5wdWxzZS1kb3QgeyB3aWR0aDogNnB4OyBoZWlnaHQ6IDZweDsgYm9yZGVyLXJhZGl1czogNTAlOyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdWNjZXNzKTsgYW5pbWF0aW9uOiBwdWxzZSAycyBlYXNlLWluLW91dCBpbmZpbml0ZTsgZmxleC1zaHJpbms6IDA7IH0KICAgIC5wdWxzZS1kb3QuZXJyb3IgICB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLWVycm9yKTsgICBhbmltYXRpb246IG5vbmU7IH0KICAgIC5wdWxzZS1kb3QubG9hZGluZyB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXByaW1hcnkpOyB9CiAgICBAa2V5ZnJhbWVzIHB1bHNlIHsgMCUsIDEwMCUgeyBvcGFjaXR5OiAxOyB9IDUwJSB7IG9wYWNpdHk6IDAuMzU7IH0gfQogICAgLmJ0biB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IHZhcigtLXNwYWNlLTIpOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0yKSB2YXIoLS1zcGFjZS0zKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLW1kKTsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDUwMDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZS0yKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyB3aGl0ZS1zcGFjZTogbm93cmFwOyB9CiAgICAuYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBib3JkZXItY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyB9CiAgICAudGhlbWUtdG9nZ2xlIHsgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1tZCk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UtMik7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgfQogICAgLnRoZW1lLXRvZ2dsZTpob3ZlciB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgfQoKICAgIC8qIFBhZ2UgdGFicyAqLwogICAgLnBhZ2UtdGFicyB7IGRpc3BsYXk6IGZsZXg7IGdhcDogMDsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZSk7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyBwYWRkaW5nOiAwIHZhcigtLXNwYWNlLTYpOyB9CiAgICAucGFnZS10YWIgeyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0zKSB2YXIoLS1zcGFjZS01KTsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBib3JkZXItYm90dG9tOiAycHggc29saWQgdHJhbnNwYXJlbnQ7IG1hcmdpbi1ib3R0b206IC0xcHg7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogdmFyKC0tc3BhY2UtMik7IHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyYW5zaXRpb24pLCBib3JkZXItY29sb3IgdmFyKC0tdHJhbnNpdGlvbik7IH0KICAgIC5wYWdlLXRhYjpob3ZlciB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgfQogICAgLnBhZ2UtdGFiLmFjdGl2ZSB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgYm9yZGVyLWJvdHRvbS1jb2xvcjogdmFyKC0tY29sb3ItcHJpbWFyeSk7IH0KICAgIC5wYWdlLXRhYi5henVyZS5hY3RpdmUgeyBib3JkZXItYm90dG9tLWNvbG9yOiB2YXIoLS1jb2xvci1henVyZSk7IH0KICAgIC50YWItYmFkZ2UgeyBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA3MDA7IHBhZGRpbmc6IDFweCA2cHg7IGJvcmRlci1yYWRpdXM6IDk5OTlweDsgYmFja2dyb3VuZDogdmFyKC0tY29sb3ItZXJyb3ItZGltKTsgY29sb3I6IHZhcigtLWNvbG9yLWVycm9yKTsgZGlzcGxheTogbm9uZTsgfQogICAgLnRhYi1iYWRnZS5zaG93IHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KCiAgICAvKiBNYWluICovCiAgICAubWFpbiB7IHBhZGRpbmc6IHZhcigtLXNwYWNlLTYpOyBtYXgtd2lkdGg6IDEyMDBweDsgbWFyZ2luOiAwIGF1dG87IHdpZHRoOiAxMDAlOyBmbGV4OiAxOyB9CiAgICAucGFnZS12aWV3IHsgZGlzcGxheTogbm9uZTsgfQogICAgLnBhZ2Utdmlldy5hY3RpdmUgeyBkaXNwbGF5OiBibG9jazsgfQoKICAgIC8qIFN1bW1hcnkgKi8KICAgIC5zdW1tYXJ5LWJhciB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgZmxleC13cmFwOiB3cmFwOyBnYXA6IHZhcigtLXNwYWNlLTMpOyBtYXJnaW4tYm90dG9tOiB2YXIoLS1zcGFjZS02KTsgfQogICAgLnN1bW1hcnktc3RhdHVzIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgfQogICAgLnN0YXR1cy1iYWRnZSB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IHZhcigtLXNwYWNlLTIpOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0yKSB2YXIoLS1zcGFjZS00KTsgYm9yZGVyLXJhZGl1czogOTk5OXB4OyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBmb250LXdlaWdodDogNjAwOyBsZXR0ZXItc3BhY2luZzogMC4wM2VtOyB0ZXh0LXRyYW5zZm9ybTogdXBwZXJjYXNlOyB9CiAgICAuc3RhdHVzLWJhZGdlLm9rICAgICAgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdWNjZXNzLWRpbSk7IGNvbG9yOiB2YXIoLS1jb2xvci1zdWNjZXNzKTsgfQogICAgLnN0YXR1cy1iYWRnZS53YXJuaW5nIHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itd2FybmluZy1kaW0pOyBjb2xvcjogdmFyKC0tY29sb3Itd2FybmluZyk7IH0KICAgIC5zdGF0dXMtYmFkZ2UuZXJyb3IgICB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLWVycm9yLWRpbSk7ICAgY29sb3I6IHZhcigtLWNvbG9yLWVycm9yKTsgfQogICAgLnN0YXR1cy1iYWRnZS5henVyZSAgIHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3ItYXp1cmUtZGltKTsgICBjb2xvcjogdmFyKC0tY29sb3ItYXp1cmUpOyB9CiAgICAuc3RhdHVzLWJhZGdlLmxvYWRpbmcgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlLTIpOyAgIGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgfQogICAgLmxhc3QtdXBkYXRlZCB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LWZhaW50KTsgZm9udC1mYW1pbHk6IHZhcigtLWZvbnQtbW9ubyk7IH0KCiAgICAvKiBQcm9ncmVzcyByaW5nICovCiAgICAucHJvZ3Jlc3MtcmluZy13cmFwIHsgd2lkdGg6IDIwcHg7IGhlaWdodDogMjBweDsgZmxleC1zaHJpbms6IDA7IGRpc3BsYXk6IG5vbmU7IH0KICAgIC5wcm9ncmVzcy1yaW5nIHsgdHJhbnNmb3JtOiByb3RhdGUoLTkwZGVnKTsgfQogICAgLnByb2dyZXNzLXJpbmctY2lyY2xlIHsgc3Ryb2tlLWRhc2hhcnJheTogNTYuNTsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDU2LjU7IHN0cm9rZTogdmFyKC0tY29sb3ItcHJpbWFyeSk7IHRyYW5zaXRpb246IHN0cm9rZS1kYXNob2Zmc2V0IDFzIGxpbmVhcjsgZmlsbDogbm9uZTsgc3Ryb2tlLWxpbmVjYXA6IHJvdW5kOyB9CiAgICAucHJvZ3Jlc3MtcmluZy1iZyB7IGZpbGw6IG5vbmU7IHN0cm9rZTogdmFyKC0tY29sb3ItYm9yZGVyKTsgfQoKICAgIC8qIEZpbHRlcnMgKi8KICAgIC5maWx0ZXItdGFicyB7IGRpc3BsYXk6IGZsZXg7IGdhcDogdmFyKC0tc3BhY2UtMSk7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTQpOyBmbGV4LXdyYXA6IHdyYXA7IH0KICAgIC5maWx0ZXItdGFiIHsgcGFkZGluZzogdmFyKC0tc3BhY2UtMikgdmFyKC0tc3BhY2UtMyk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1tZCk7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgYm9yZGVyOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9CiAgICAuZmlsdGVyLXRhYjpob3ZlciB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZSk7IH0KICAgIC5maWx0ZXItdGFiLmFjdGl2ZSB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZSk7IGJvcmRlci1jb2xvcjogdmFyKC0tY29sb3ItYm9yZGVyKTsgfQoKICAgIC8qIFNlcnZpY2UgZ3JpZCAqLwogICAgLnNlY3Rpb24tdGl0bGUgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBmb250LXdlaWdodDogNjAwOyB0ZXh0LXRyYW5zZm9ybTogdXBwZXJjYXNlOyBsZXR0ZXItc3BhY2luZzogMC4wN2VtOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTMpOyB9CiAgICAuc2VydmljZS1ncmlkIHsgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiByZXBlYXQoYXV0by1maWxsLCBtaW5tYXgoMjIwcHgsIDFmcikpOyBnYXA6IHZhcigtLXNwYWNlLTMpOyBtYXJnaW4tYm90dG9tOiB2YXIoLS1zcGFjZS04KTsgfQogICAgLnNlcnZpY2UtY2FyZCB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UpOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMtbGcpOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS00KTsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgdHJhbnNpdGlvbjogYm9yZGVyLWNvbG9yIHZhcigtLXRyYW5zaXRpb24pLCBib3gtc2hhZG93IHZhcigtLXRyYW5zaXRpb24pLCB0cmFuc2Zvcm0gdmFyKC0tdHJhbnNpdGlvbik7IH0KICAgIC5zZXJ2aWNlLWNhcmQ6aG92ZXIgeyBib3JkZXItY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBib3gtc2hhZG93OiB2YXIoLS1zaGFkb3ctc20pOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCk7IH0KICAgIC5zZXJ2aWNlLWNhcmQud2FybmluZyB7IGJvcmRlci1jb2xvcjogdmFyKC0tY29sb3Itd2FybmluZyk7IH0KICAgIC5zZXJ2aWNlLWNhcmQuZXJyb3IgICB7IGJvcmRlci1jb2xvcjogdmFyKC0tY29sb3ItZXJyb3IpOyB9CiAgICAuc2VydmljZS1pY29uIHsgd2lkdGg6IDM2cHg7IGhlaWdodDogMzZweDsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLW1kKTsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGZsZXgtc2hyaW5rOiAwOyBmb250LXNpemU6IDE4cHg7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UtMik7IH0KICAgIC5zZXJ2aWNlLWluZm8geyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IH0KICAgIC5zZXJ2aWNlLW5hbWUgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IGxpbmUtaGVpZ2h0OiAxLjM7IGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IG92ZXJmbG93OiBoaWRkZW47IH0KICAgIC5zZXJ2aWNlLXN0YXR1cy10ZXh0IHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBtYXJnaW4tdG9wOiAycHg7IH0KICAgIC5zZXJ2aWNlLXN0YXR1cy10ZXh0Lm9rICAgICAgeyBjb2xvcjogdmFyKC0tY29sb3Itc3VjY2Vzcyk7IH0KICAgIC5zZXJ2aWNlLXN0YXR1cy10ZXh0Lndhcm5pbmcgeyBjb2xvcjogdmFyKC0tY29sb3Itd2FybmluZyk7IH0KICAgIC5zZXJ2aWNlLXN0YXR1cy10ZXh0LmVycm9yICAgeyBjb2xvcjogdmFyKC0tY29sb3ItZXJyb3IpOyB9CiAgICAuc2VydmljZS1kb3QgeyB3aWR0aDogOHB4OyBoZWlnaHQ6IDhweDsgYm9yZGVyLXJhZGl1czogNTAlOyBmbGV4LXNocmluazogMDsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VjY2Vzcyk7IH0KICAgIC5zZXJ2aWNlLWRvdC53YXJuaW5nIHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itd2FybmluZyk7IH0KICAgIC5zZXJ2aWNlLWRvdC5lcnJvciAgIHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3ItZXJyb3IpOyBhbmltYXRpb246IGJsaW5rIDEuMnMgc3RlcC1lbmQgaW5maW5pdGU7IH0KICAgIEBrZXlmcmFtZXMgYmxpbmsgeyAwJSwgMTAwJSB7IG9wYWNpdHk6IDE7IH0gNTAlIHsgb3BhY2l0eTogMC4xNTsgfSB9CgogICAgLyogSW5jaWRlbnRzICovCiAgICAuaW5jaWRlbnRzLXNlY3Rpb24geyBtYXJnaW4tYm90dG9tOiB2YXIoLS1zcGFjZS04KTsgfQogICAgLmluY2lkZW50cy1saXN0IHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgfQogICAgLmluY2lkZW50LWNhcmQgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLWxnKTsgb3ZlcmZsb3c6IGhpZGRlbjsgfQogICAgLmluY2lkZW50LWNhcmQuaW5jaWRlbnQgeyBib3JkZXItbGVmdDogM3B4IHNvbGlkIHZhcigtLWNvbG9yLWVycm9yKTsgfQogICAgLmluY2lkZW50LWNhcmQuYWR2aXNvcnkgeyBib3JkZXItbGVmdDogM3B4IHNvbGlkIHZhcigtLWNvbG9yLXdhcm5pbmcpOyB9CiAgICAuaW5jaWRlbnQtY2FyZC5henVyZS1pbmNpZGVudCB7IGJvcmRlci1sZWZ0OiAzcHggc29saWQgdmFyKC0tY29sb3ItYXp1cmUpOyB9CiAgICAuaW5jaWRlbnQtaGVhZGVyIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgcGFkZGluZzogdmFyKC0tc3BhY2UtNCkgdmFyKC0tc3BhY2UtNSk7IGdhcDogdmFyKC0tc3BhY2UtNCk7IGN1cnNvcjogcG9pbnRlcjsgfQogICAgLmluY2lkZW50LWhlYWRlcjpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UtMik7IH0KICAgIC5pbmNpZGVudC1tYWluIHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyB9CiAgICAuaW5jaWRlbnQtdG9wIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiB2YXIoLS1zcGFjZS0yKTsgZmxleC13cmFwOiB3cmFwOyBtYXJnaW4tYm90dG9tOiB2YXIoLS1zcGFjZS0yKTsgfQogICAgLmluY2lkZW50LWlkIHsgZm9udC1mYW1pbHk6IHZhcigtLWZvbnQtbW9ubyk7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZS0yKTsgcGFkZGluZzogMXB4IHZhcigtLXNwYWNlLTIpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMtc20pOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyB9CiAgICAudHlwZS1waWxsIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDYwMDsgcGFkZGluZzogMXB4IHZhcigtLXNwYWNlLTIpOyBib3JkZXItcmFkaXVzOiA5OTk5cHg7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7IGxldHRlci1zcGFjaW5nOiAwLjA0ZW07IH0KICAgIC50eXBlLXBpbGwuaW5jaWRlbnQgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1lcnJvci1kaW0pOyBjb2xvcjogdmFyKC0tY29sb3ItZXJyb3IpOyB9CiAgICAudHlwZS1waWxsLmFkdmlzb3J5IHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itd2FybmluZy1kaW0pOyBjb2xvcjogdmFyKC0tY29sb3Itd2FybmluZyk7IH0KICAgIC50eXBlLXBpbGwuYXp1cmUtaW5jaWRlbnQgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1henVyZS1kaW0pOyBjb2xvcjogdmFyKC0tY29sb3ItYXp1cmUpOyB9CiAgICAuc3RhdHVzLXBpbGwgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBmb250LXdlaWdodDogNTAwOyBwYWRkaW5nOiAxcHggdmFyKC0tc3BhY2UtMik7IGJvcmRlci1yYWRpdXM6IDk5OTlweDsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZS0yKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyB9CiAgICAuaW5jaWRlbnQtdGl0bGUgeyBmb250LXNpemU6IHZhcigtLXRleHQtc20pOyBmb250LXdlaWdodDogNjAwOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IGxpbmUtaGVpZ2h0OiAxLjM1OyB9CiAgICAuaW5jaWRlbnQtc2VydmljZSB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgbWFyZ2luLXRvcDogdmFyKC0tc3BhY2UtMSk7IH0KICAgIC5pbmNpZGVudC1tZXRhIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGZsZXgtZW5kOyBnYXA6IHZhcigtLXNwYWNlLTEpOyBmbGV4LXNocmluazogMDsgfQogICAgLmluY2lkZW50LXRpbWUgeyBmb250LWZhbWlseTogdmFyKC0tZm9udC1tb25vKTsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtZmFpbnQpOyB9CiAgICAuY2hldnJvbiB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LWZhaW50KTsgdHJhbnNpdGlvbjogdHJhbnNmb3JtIHZhcigtLXRyYW5zaXRpb24pOyB9CiAgICAuY2hldnJvbi5vcGVuIHsgdHJhbnNmb3JtOiByb3RhdGUoMTgwZGVnKTsgfQogICAgLmluY2lkZW50LWJvZHkgeyBwYWRkaW5nOiAwIHZhcigtLXNwYWNlLTUpIHZhcigtLXNwYWNlLTUpOyBib3JkZXItdG9wOiAxcHggc29saWQgdmFyKC0tY29sb3ItZGl2aWRlcik7IGRpc3BsYXk6IG5vbmU7IH0KICAgIC5pbmNpZGVudC1ib2R5Lm9wZW4geyBkaXNwbGF5OiBibG9jazsgfQogICAgLmluY2lkZW50LXVwZGF0ZXMgeyBtYXJnaW4tdG9wOiB2YXIoLS1zcGFjZS00KTsgfQogICAgLnVwZGF0ZS1lbnRyeSB7IGRpc3BsYXk6IGZsZXg7IGdhcDogdmFyKC0tc3BhY2UtNCk7IHBhZGRpbmc6IHZhcigtLXNwYWNlLTMpIDA7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1jb2xvci1kaXZpZGVyKTsgfQogICAgLnVwZGF0ZS1lbnRyeTpsYXN0LWNoaWxkIHsgYm9yZGVyLWJvdHRvbTogbm9uZTsgfQogICAgLnVwZGF0ZS10aW1lIHsgZm9udC1mYW1pbHk6IHZhcigtLWZvbnQtbW9ubyk7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgZmxleC1zaHJpbms6IDA7IHdpZHRoOiAxNDBweDsgcGFkZGluZy10b3A6IDJweDsgfQogICAgLnVwZGF0ZS10ZXh0IHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBsaW5lLWhlaWdodDogMS42OyB9CgogICAgLyogQXp1cmUgc3RhdHVzIGl0ZW1zICovCiAgICAuYXp1cmUtaXRlbSB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UpOyBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1ib3JkZXIpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMtbGcpOyBwYWRkaW5nOiB2YXIoLS1zcGFjZS00KSB2YXIoLS1zcGFjZS01KTsgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCB2YXIoLS1jb2xvci1henVyZSk7IH0KICAgIC5henVyZS1pdGVtLXRpdGxlIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXNtKTsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBtYXJnaW4tYm90dG9tOiB2YXIoLS1zcGFjZS0xKTsgfQogICAgLmF6dXJlLWl0ZW0tdGl0bGUgYSB7IGNvbG9yOiBpbmhlcml0OyB0ZXh0LWRlY29yYXRpb246IG5vbmU7IH0KICAgIC5henVyZS1pdGVtLXRpdGxlIGE6aG92ZXIgeyBjb2xvcjogdmFyKC0tY29sb3ItYXp1cmUpOyB9CiAgICAuYXp1cmUtaXRlbS1tZXRhIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBmb250LWZhbWlseTogdmFyKC0tZm9udC1tb25vKTsgbWFyZ2luLWJvdHRvbTogdmFyKC0tc3BhY2UtMik7IH0KICAgIC5henVyZS1pdGVtLWRlc2MgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7IGxpbmUtaGVpZ2h0OiAxLjY7IH0KICAgIC5henVyZS1vay1ib3ggeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLWxnKTsgcGFkZGluZzogdmFyKC0tc3BhY2UtMTApOyB0ZXh0LWFsaWduOiBjZW50ZXI7IH0KCiAgICAvKiBTdGF0ZXMgKi8KICAgIC5zdGF0ZS1ib3ggeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdXJmYWNlKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLWxnKTsgcGFkZGluZzogdmFyKC0tc3BhY2UtMTApOyB0ZXh0LWFsaWduOiBjZW50ZXI7IH0KICAgIC5zdGF0ZS1pY29uIHsgZm9udC1zaXplOiAzMnB4OyBtYXJnaW4tYm90dG9tOiB2YXIoLS1zcGFjZS0zKTsgfQogICAgLnN0YXRlLXRpdGxlIHsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXNtKTsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQpOyBtYXJnaW4tYm90dG9tOiB2YXIoLS1zcGFjZS0yKTsgfQogICAgLnN0YXRlLWRlc2MgeyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7IG1heC13aWR0aDogNDJjaDsgbWFyZ2luOiAwIGF1dG87IH0KICAgIC5za2VsZXRvbiB7IGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgdmFyKC0tY29sb3Itc3VyZmFjZSkgMCUsIHZhcigtLWNvbG9yLXN1cmZhY2UtMikgNTAlLCB2YXIoLS1jb2xvci1zdXJmYWNlKSAxMDAlKTsgYmFja2dyb3VuZC1zaXplOiAyMDAlIDEwMCU7IGFuaW1hdGlvbjogc2hpbW1lciAxLjRzIGVhc2UtaW4tb3V0IGluZmluaXRlOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yYWRpdXMtbWQpOyB9CiAgICBAa2V5ZnJhbWVzIHNoaW1tZXIgeyAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IDIwMCUgMDsgfSAxMDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogLTIwMCUgMDsgfSB9CgogICAgLyogRm9vdGVyICovCiAgICAuZm9vdGVyIHsgcGFkZGluZzogdmFyKC0tc3BhY2UtNCkgdmFyKC0tc3BhY2UtNik7IGJvcmRlci10b3A6IDFweCBzb2xpZCB2YXIoLS1jb2xvci1kaXZpZGVyKTsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBmbGV4LXdyYXA6IHdyYXA7IGdhcDogdmFyKC0tc3BhY2UtMik7IH0KICAgIC5mb290ZXItdGV4dCB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LWZhaW50KTsgfQogICAgLmZvb3Rlci10ZXh0IGEgeyBjb2xvcjogdmFyKC0tY29sb3ItcHJpbWFyeSk7IHRleHQtZGVjb3JhdGlvbjogbm9uZTsgfQogICAgLmZvb3Rlci10ZXh0IGE6aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQoKICAgIC8qIFRvYXN0ICovCiAgICAudG9hc3QtY29udGFpbmVyIHsgcG9zaXRpb246IGZpeGVkOyBib3R0b206IHZhcigtLXNwYWNlLTYpOyByaWdodDogdmFyKC0tc3BhY2UtNik7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogdmFyKC0tc3BhY2UtMik7IHotaW5kZXg6IDUwMDsgfQogICAgLnRvYXN0IHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZSk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1sZyk7IHBhZGRpbmc6IHZhcigtLXNwYWNlLTMpIHZhcigtLXNwYWNlLTUpOyBmb250LXNpemU6IHZhcigtLXRleHQteHMpOyBib3gtc2hhZG93OiB2YXIoLS1zaGFkb3ctbWQpOyBtYXgtd2lkdGg6IDMyMHB4OyBhbmltYXRpb246IHRvYXN0SW4gMC4zcyBlYXNlOyB9CiAgICBAa2V5ZnJhbWVzIHRvYXN0SW4geyBmcm9tIHsgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDhweCk7IH0gdG8geyBvcGFjaXR5OiAxOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0gfQogICAgLnRvYXN0LnN1Y2Nlc3MgeyBib3JkZXItbGVmdDogM3B4IHNvbGlkIHZhcigtLWNvbG9yLXN1Y2Nlc3MpOyB9CiAgICAudG9hc3QuZXJyb3IgICB7IGJvcmRlci1sZWZ0OiAzcHggc29saWQgdmFyKC0tY29sb3ItZXJyb3IpOyB9CgogICAgLyogSGlzdG9yeSB0YWIgKi8KICAgIC5oaXN0b3J5LWNvbnRyb2xzIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBmbGV4LXdyYXA6IHdyYXA7IGdhcDogdmFyKC0tc3BhY2UtMyk7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTYpOyB9CiAgICAucmFuZ2UtYnRucyB7IGRpc3BsYXk6IGZsZXg7IGdhcDogdmFyKC0tc3BhY2UtMSk7IH0KICAgIC5yYW5nZS1idG4geyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0yKSB2YXIoLS1zcGFjZS0zKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcmFkaXVzLW1kKTsgZm9udC1zaXplOiB2YXIoLS10ZXh0LXhzKTsgZm9udC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigtLWNvbG9yLXRleHQtbXV0ZWQpOyBib3JkZXI6IDFweCBzb2xpZCB0cmFuc3BhcmVudDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IH0KICAgIC5yYW5nZS1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UpOyB9CiAgICAucmFuZ2UtYnRuLmFjdGl2ZSB7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0KTsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZSk7IGJvcmRlci1jb2xvcjogdmFyKC0tY29sb3ItYm9yZGVyKTsgfQogICAgLmhpc3Rvcnktc291cmNlLWZpbHRlciB7IGRpc3BsYXk6IGZsZXg7IGdhcDogdmFyKC0tc3BhY2UtMSk7IH0KICAgIC5zb3VyY2UtYnRuIHsgcGFkZGluZzogdmFyKC0tc3BhY2UtMikgdmFyKC0tc3BhY2UtMyk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1tZCk7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tY29sb3ItYm9yZGVyKTsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZS0yKTsgfQogICAgLnNvdXJjZS1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IH0KICAgIC5zb3VyY2UtYnRuLmFjdGl2ZSB7IGJhY2tncm91bmQ6IHZhcigtLWNvbG9yLXN1cmZhY2UpOyBjb2xvcjogdmFyKC0tY29sb3ItdGV4dCk7IH0KICAgIC5oaXN0b3J5LXRpbWVsaW5lIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgfQogICAgLmhpc3RvcnktZGF0ZS1ncm91cCB7IG1hcmdpbi1ib3R0b206IHZhcigtLXNwYWNlLTIpOyB9CiAgICAuaGlzdG9yeS1kYXRlLWhlYWRlciB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGZvbnQtd2VpZ2h0OiA2MDA7IHRleHQtdHJhbnNmb3JtOiB1cHBlcmNhc2U7IGxldHRlci1zcGFjaW5nOiAwLjA3ZW07IGNvbG9yOiB2YXIoLS1jb2xvci10ZXh0LW11dGVkKTsgbWFyZ2luLWJvdHRvbTogdmFyKC0tc3BhY2UtMyk7IHBhZGRpbmctYm90dG9tOiB2YXIoLS1zcGFjZS0yKTsgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWRpdmlkZXIpOyB9CiAgICAuc291cmNlLWJhZGdlIHsgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNzAwOyBwYWRkaW5nOiAxcHggNnB4OyBib3JkZXItcmFkaXVzOiA5OTk5cHg7IG1hcmdpbi1sZWZ0OiB2YXIoLS1zcGFjZS0xKTsgfQogICAgLnNvdXJjZS1iYWRnZS5tMzY1IHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3ItcHJpbWFyeS1kaW0pOyBjb2xvcjogdmFyKC0tY29sb3ItcHJpbWFyeSk7IH0KICAgIC5zb3VyY2UtYmFkZ2UuYXp1cmUgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1henVyZS1kaW0pOyBjb2xvcjogdmFyKC0tY29sb3ItYXp1cmUpOyB9CiAgICAucmVzb2x2ZWQtcGlsbCB7IGZvbnQtc2l6ZTogdmFyKC0tdGV4dC14cyk7IGZvbnQtd2VpZ2h0OiA1MDA7IHBhZGRpbmc6IDFweCB2YXIoLS1zcGFjZS0yKTsgYm9yZGVyLXJhZGl1czogOTk5OXB4OyBiYWNrZ3JvdW5kOiB2YXIoLS1jb2xvci1zdWNjZXNzLWRpbSk7IGNvbG9yOiB2YXIoLS1jb2xvci1zdWNjZXNzKTsgYm9yZGVyOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7IH0KICAgIC5oaXN0b3J5LWVtcHR5IHsgYmFja2dyb3VuZDogdmFyKC0tY29sb3Itc3VyZmFjZSk7IGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWNvbG9yLWJvcmRlcik7IGJvcmRlci1yYWRpdXM6IHZhcigtLXJhZGl1cy1sZyk7IHBhZGRpbmc6IHZhcigtLXNwYWNlLTEwKTsgdGV4dC1hbGlnbjogY2VudGVyOyB9CiAgICAuaGlzdG9yeS1sb2FkaW5nIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiB2YXIoLS1zcGFjZS0zKTsgfQoKICAgIEBtZWRpYSAobWF4LXdpZHRoOiA2NDBweCkgewogICAgICAubWFpbiB7IHBhZGRpbmc6IHZhcigtLXNwYWNlLTQpOyB9CiAgICAgIC5oZWFkZXIgeyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0zKSB2YXIoLS1zcGFjZS00KTsgfQogICAgICAuc2VydmljZS1ncmlkIHsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgMWZyOyB9CiAgICAgIC5pbmNpZGVudC1tZXRhIHsgZGlzcGxheTogbm9uZTsgfQogICAgICAucGFnZS10YWJzIHsgcGFkZGluZzogMCB2YXIoLS1zcGFjZS0zKTsgfQogICAgICAucGFnZS10YWIgeyBwYWRkaW5nOiB2YXIoLS1zcGFjZS0zKSB2YXIoLS1zcGFjZS0zKTsgfQogICAgfQogIDwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9ImFwcCI+CiAgPGhlYWRlciBjbGFzcz0iaGVhZGVyIj4KICAgIDxkaXYgY2xhc3M9ImxvZ28iPgogICAgICA8c3ZnIHdpZHRoPSIyOCIgaGVpZ2h0PSIyOCIgdmlld0JveD0iMCAwIDI4IDI4IiBmaWxsPSJub25lIiBhcmlhLWxhYmVsPSJTdGF0dXMiPgogICAgICAgIDxyZWN0IHdpZHRoPSIyOCIgaGVpZ2h0PSIyOCIgcng9IjYiIGZpbGw9InZhcigtLWNvbG9yLXByaW1hcnkpIi8+CiAgICAgICAgPHJlY3QgeD0iNSIgeT0iNSIgd2lkdGg9IjgiIGhlaWdodD0iOCIgcng9IjEuNSIgZmlsbD0id2hpdGUiIG9wYWNpdHk9IjAuOTUiLz4KICAgICAgICA8cmVjdCB4PSIxNSIgeT0iNSIgd2lkdGg9IjgiIGhlaWdodD0iOCIgcng9IjEuNSIgZmlsbD0id2hpdGUiIG9wYWNpdHk9IjAuNyIvPgogICAgICAgIDxyZWN0IHg9IjUiIHk9IjE1IiB3aWR0aD0iOCIgaGVpZ2h0PSI4IiByeD0iMS41IiBmaWxsPSJ3aGl0ZSIgb3BhY2l0eT0iMC43Ii8+CiAgICAgICAgPHJlY3QgeD0iMTUiIHk9IjE1IiB3aWR0aD0iOCIgaGVpZ2h0PSI4IiByeD0iMS41IiBmaWxsPSJ3aGl0ZSIgb3BhY2l0eT0iMC41Ii8+CiAgICAgIDwvc3ZnPgogICAgICA8ZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxvZ28tdGV4dCI+U2VydmljZSBIZWFsdGg8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2dvLXN1YiI+TTM2NSAmYW1wOyBBenVyZSBsaXZlIHN0YXR1czwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iaGVhZGVyLXJpZ2h0Ij4KICAgICAgPGRpdiBjbGFzcz0icmVmcmVzaC1pbmZvIj4KICAgICAgICA8ZGl2IGNsYXNzPSJwdWxzZS1kb3QgbG9hZGluZyIgaWQ9InN0YXR1c0RvdCI+PC9kaXY+CiAgICAgICAgPHNwYW4gaWQ9InJlZnJlc2hDb3VudGRvd24iPkxvYWRpbmfigKY8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4iIGlkPSJyZWZyZXNoQnRuIj4KICAgICAgICA8c3ZnIHdpZHRoPSIxMiIgaGVpZ2h0PSIxMiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjUiPgogICAgICAgICAgPHBhdGggZD0iTTIzIDR2NmgtNk0xIDIwdi02aDYiLz48cGF0aCBkPSJNMy41MSA5YTkgOSAwIDAgMSAxNC44NS0zLjM2TDIzIDEwTTEgMTRsNC42NCA0LjM2QTkgOSAwIDAgMCAyMC40OSAxNSIvPgogICAgICAgIDwvc3ZnPgogICAgICAgIFJlZnJlc2gKICAgICAgPC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9InByb2dyZXNzLXJpbmctd3JhcCIgaWQ9InByb2dyZXNzUmluZ1dyYXAiPgogICAgICAgIDxzdmcgY2xhc3M9InByb2dyZXNzLXJpbmciIHdpZHRoPSIyMCIgaGVpZ2h0PSIyMCI+CiAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJwcm9ncmVzcy1yaW5nLWJnIiBjeD0iMTAiIGN5PSIxMCIgcj0iOSIgc3Ryb2tlLXdpZHRoPSIyIi8+CiAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJwcm9ncmVzcy1yaW5nLWNpcmNsZSIgaWQ9InByb2dyZXNzUmluZyIgY3g9IjEwIiBjeT0iMTAiIHI9IjkiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICAgIDwvc3ZnPgogICAgICA8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0idGhlbWUtdG9nZ2xlIiBpZD0idGhlbWVUb2dnbGUiIGFyaWEtbGFiZWw9IlRvZ2dsZSB0aGVtZSI+CiAgICAgICAgPHN2ZyB3aWR0aD0iMTQiIGhlaWdodD0iMTQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIgaWQ9InRoZW1lSWNvbiI+CiAgICAgICAgICA8cGF0aCBkPSJNMjEgMTIuNzlBOSA5IDAgMSAxIDExLjIxIDMgNyA3IDAgMCAwIDIxIDEyLjc5eiIvPgogICAgICAgIDwvc3ZnPgogICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvaGVhZGVyPgoKICA8IS0tIFBhZ2UgdGFicyAtLT4KICA8bmF2IGNsYXNzPSJwYWdlLXRhYnMiPgogICAgPGJ1dHRvbiBjbGFzcz0icGFnZS10YWIgYWN0aXZlIiBkYXRhLXBhZ2U9Im0zNjUiPgogICAgICA8c3ZnIHdpZHRoPSIxMyIgaGVpZ2h0PSIxMyIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cmVjdCB4PSIzIiB5PSIzIiB3aWR0aD0iNyIgaGVpZ2h0PSI3Ii8+PHJlY3QgeD0iMTQiIHk9IjMiIHdpZHRoPSI3IiBoZWlnaHQ9IjciLz48cmVjdCB4PSIzIiB5PSIxNCIgd2lkdGg9IjciIGhlaWdodD0iNyIvPjxyZWN0IHg9IjE0IiB5PSIxNCIgd2lkdGg9IjciIGhlaWdodD0iNyIvPjwvc3ZnPgogICAgICBNaWNyb3NvZnQgMzY1CiAgICAgIDxzcGFuIGNsYXNzPSJ0YWItYmFkZ2UiIGlkPSJtMzY1QmFkZ2UiPjA8L3NwYW4+CiAgICA8L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9InBhZ2UtdGFiIGF6dXJlIiBkYXRhLXBhZ2U9ImF6dXJlIj4KICAgICAgPHN2ZyB3aWR0aD0iMTMiIGhlaWdodD0iMTMiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiI+PHBvbHlnb24gcG9pbnRzPSIxMiAyIDIgNyAxMiAxMiAyMiA3IDEyIDIiLz48cG9seWxpbmUgcG9pbnRzPSIyIDE3IDEyIDIyIDIyIDE3Ii8+PHBvbHlsaW5lIHBvaW50cz0iMiAxMiAxMiAxNyAyMiAxMiIvPjwvc3ZnPgogICAgICBBenVyZQogICAgICA8c3BhbiBjbGFzcz0idGFiLWJhZGdlIiBpZD0iYXp1cmVCYWRnZSI+MDwvc3Bhbj4KICAgIDwvYnV0dG9uPgogICAgPGJ1dHRvbiBjbGFzcz0icGFnZS10YWIiIGRhdGEtcGFnZT0iaGlzdG9yeSI+CiAgICAgIDxzdmcgd2lkdGg9IjEzIiBoZWlnaHQ9IjEzIiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjEwIi8+PHBvbHlsaW5lIHBvaW50cz0iMTIgNiAxMiAxMiAxNiAxNCIvPjwvc3ZnPgogICAgICBIaXN0b3J5CiAgICA8L2J1dHRvbj4KICA8L25hdj4KCiAgPG1haW4gY2xhc3M9Im1haW4iPgoKICAgIDwhLS0gTTM2NSBWaWV3IC0tPgogICAgPGRpdiBjbGFzcz0icGFnZS12aWV3IGFjdGl2ZSIgaWQ9InZpZXctbTM2NSI+CiAgICAgIDxkaXYgY2xhc3M9InN1bW1hcnktYmFyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdW1tYXJ5LXN0YXR1cyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0dXMtYmFkZ2UgbG9hZGluZyIgaWQ9Imdsb2JhbEJhZGdlIj48c3BhbiBpZD0iZ2xvYmFsQmFkZ2VUZXh0Ij5Mb2FkaW5n4oCmPC9zcGFuPjwvZGl2PgogICAgICAgICAgPHNwYW4gY2xhc3M9Imxhc3QtdXBkYXRlZCIgaWQ9Imxhc3RVcGRhdGVkIj48L3NwYW4+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaWx0ZXItdGFicyIgaWQ9ImZpbHRlclRhYnMiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImZpbHRlci10YWIgYWN0aXZlIiBkYXRhLWZpbHRlcj0iYWxsIj5BbGwgU2VydmljZXM8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJmaWx0ZXItdGFiIiBkYXRhLWZpbHRlcj0iaXNzdWVzIj5Jc3N1ZXMgT25seTwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImZpbHRlci10YWIiIGRhdGEtZmlsdGVyPSJFeGNoYW5nZSBPbmxpbmUiPkV4Y2hhbmdlPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iZmlsdGVyLXRhYiIgZGF0YS1maWx0ZXI9Ik1pY3Jvc29mdCBUZWFtcyI+VGVhbXM8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJmaWx0ZXItdGFiIiBkYXRhLWZpbHRlcj0iU2hhcmVQb2ludCBPbmxpbmUiPlNoYXJlUG9pbnQ8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJmaWx0ZXItdGFiIiBkYXRhLWZpbHRlcj0iT25lRHJpdmUgZm9yIEJ1c2luZXNzIj5PbmVEcml2ZTwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0ic2VydmljZXNDb250YWluZXIiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudHMtc2VjdGlvbiIgaWQ9ImluY2lkZW50c1NlY3Rpb24iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgIDxkaXYgY2xhc3M9InNlY3Rpb24tdGl0bGUiIGlkPSJpbmNpZGVudHNTZWN0aW9uVGl0bGUiPkFjdGl2ZSBJc3N1ZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudHMtbGlzdCIgaWQ9ImluY2lkZW50c0xpc3QiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0gQXp1cmUgVmlldyAtLT4KICAgIDxkaXYgY2xhc3M9InBhZ2UtdmlldyIgaWQ9InZpZXctYXp1cmUiPgogICAgICA8ZGl2IGNsYXNzPSJzdW1tYXJ5LWJhciI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3VtbWFyeS1zdGF0dXMiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3RhdHVzLWJhZGdlIGxvYWRpbmciIGlkPSJhenVyZUdsb2JhbEJhZGdlIj48c3BhbiBpZD0iYXp1cmVHbG9iYWxCYWRnZVRleHQiPkxvYWRpbmfigKY8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8c3BhbiBjbGFzcz0ibGFzdC11cGRhdGVkIiBpZD0iYXp1cmVMYXN0VXBkYXRlZCI+PC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0iYXp1cmVDb250YWluZXIiPgogICAgICAgIDxkaXYgY2xhc3M9InNlcnZpY2UtZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZXJ2aWNlLWNhcmQiPjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0id2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjhweDtmbGV4LXNocmluazowIj48L2Rpdj48ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0iaGVpZ2h0OjEycHg7d2lkdGg6ODAlO21hcmdpbi1ib3R0b206NnB4Ij48L2Rpdj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMHB4O3dpZHRoOjU1JSI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZXJ2aWNlLWNhcmQiPjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0id2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjhweDtmbGV4LXNocmluazowIj48L2Rpdj48ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0iaGVpZ2h0OjEycHg7d2lkdGg6ODAlO21hcmdpbi1ib3R0b206NnB4Ij48L2Rpdj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMHB4O3dpZHRoOjU1JSI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZXJ2aWNlLWNhcmQiPjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0id2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjhweDtmbGV4LXNocmluazowIj48L2Rpdj48ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0iaGVpZ2h0OjEycHg7d2lkdGg6ODAlO21hcmdpbi1ib3R0b206NnB4Ij48L2Rpdj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMHB4O3dpZHRoOjU1JSI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBIaXN0b3J5IFZpZXcgLS0+CiAgICA8ZGl2IGNsYXNzPSJwYWdlLXZpZXciIGlkPSJ2aWV3LWhpc3RvcnkiPgogICAgICA8ZGl2IGNsYXNzPSJoaXN0b3J5LWNvbnRyb2xzIj4KICAgICAgICA8ZGl2IGNsYXNzPSJyYW5nZS1idG5zIiBpZD0icmFuZ2VCdG5zIj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJhbmdlLWJ0biIgZGF0YS1kYXlzPSI3Ij43IGRheXM8L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJhbmdlLWJ0biBhY3RpdmUiIGRhdGEtZGF5cz0iMzAiPjMwIGRheXM8L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJhbmdlLWJ0biIgZGF0YS1kYXlzPSI2MCI+NjAgZGF5czwvYnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0icmFuZ2UtYnRuIiBkYXRhLWRheXM9IjkwIj45MCBkYXlzPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iaGlzdG9yeS1zb3VyY2UtZmlsdGVyIiBpZD0ic291cmNlRmlsdGVyIj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InNvdXJjZS1idG4gYWN0aXZlIiBkYXRhLXNvdXJjZT0iYWxsIj5BbGwgU291cmNlczwvYnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0ic291cmNlLWJ0biIgZGF0YS1zb3VyY2U9Im0zNjUiPk0zNjUgT25seTwvYnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0ic291cmNlLWJ0biIgZGF0YS1zb3VyY2U9ImF6dXJlIj5BenVyZSBPbmx5PC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJoaXN0b3J5Q29udGFpbmVyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJoaXN0b3J5LWxvYWRpbmciPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VydmljZS1jYXJkIj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9IndpZHRoOjM2cHg7aGVpZ2h0OjM2cHg7Ym9yZGVyLXJhZGl1czo4cHg7ZmxleC1zaHJpbms6MCI+PC9kaXY+PGRpdiBzdHlsZT0iZmxleDoxIj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMnB4O3dpZHRoOjgwJTttYXJnaW4tYm90dG9tOjZweCI+PC9kaXY+PGRpdiBjbGFzcz0ic2tlbGV0b24iIHN0eWxlPSJoZWlnaHQ6MTBweDt3aWR0aDo1NSUiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VydmljZS1jYXJkIj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9IndpZHRoOjM2cHg7aGVpZ2h0OjM2cHg7Ym9yZGVyLXJhZGl1czo4cHg7ZmxleC1zaHJpbms6MCI+PC9kaXY+PGRpdiBzdHlsZT0iZmxleDoxIj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMnB4O3dpZHRoOjgwJTttYXJnaW4tYm90dG9tOjZweCI+PC9kaXY+PGRpdiBjbGFzcz0ic2tlbGV0b24iIHN0eWxlPSJoZWlnaHQ6MTBweDt3aWR0aDo1NSUiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VydmljZS1jYXJkIj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9IndpZHRoOjM2cHg7aGVpZ2h0OjM2cHg7Ym9yZGVyLXJhZGl1czo4cHg7ZmxleC1zaHJpbms6MCI+PC9kaXY+PGRpdiBzdHlsZT0iZmxleDoxIj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMnB4O3dpZHRoOjgwJTttYXJnaW4tYm90dG9tOjZweCI+PC9kaXY+PGRpdiBjbGFzcz0ic2tlbGV0b24iIHN0eWxlPSJoZWlnaHQ6MTBweDt3aWR0aDo1NSUiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICA8L21haW4+CgogIDxmb290ZXIgY2xhc3M9ImZvb3RlciI+CiAgICA8ZGl2IGNsYXNzPSJmb290ZXItdGV4dCI+TTM2NSB2aWEgPGEgaHJlZj0iaHR0cHM6Ly9sZWFybi5taWNyb3NvZnQuY29tL2VuLXVzL2dyYXBoL2FwaS9yZXNvdXJjZXMvc2VydmljZS1jb21tdW5pY2F0aW9ucy1hcGktb3ZlcnZpZXciIHRhcmdldD0iX2JsYW5rIj5NaWNyb3NvZnQgR3JhcGg8L2E+ICZuYnNwO8K3Jm5ic3A7IEF6dXJlIHZpYSA8YSBocmVmPSJodHRwczovL2F6dXJlLnN0YXR1cy5taWNyb3NvZnQiIHRhcmdldD0iX2JsYW5rIj5henVyZS5zdGF0dXMubWljcm9zb2Z0PC9hPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iZm9vdGVyLXRleHQiPkF1dG8tcmVmcmVzaGVzIGV2ZXJ5IDYwIHNlY29uZHM8L2Rpdj4KICA8L2Zvb3Rlcj4KPC9kaXY+CjxkaXYgY2xhc3M9InRvYXN0LWNvbnRhaW5lciIgaWQ9InRvYXN0Q29udGFpbmVyIj48L2Rpdj4KCjxzY3JpcHQ+Ci8vIEFsbCBNMzY1IEFQSSBjYWxscyBnbyB0byB0aGUgbG9jYWwgcHJveHkgc2VydmVyIOKAlCBubyBjcmVkZW50aWFscyBpbiB0aGlzIGZpbGUuCmNvbnN0IEFQSSA9ICcnOwoKbGV0IGFsbFNlcnZpY2VzID0gW10sIGFsbElzc3VlcyA9IFtdLCBhenVyZUl0ZW1zID0gW107CmxldCByZWZyZXNoVGltZXIgPSBudWxsLCBjb3VudGRvd25UaW1lciA9IG51bGwsIGNvdW50ZG93blNlYyA9IDYwOwpsZXQgYWN0aXZlRmlsdGVyID0gJ2FsbCc7CmxldCBhY3RpdmVQYWdlID0gJ20zNjUnOwpjb25zdCBSRUZSRVNIX0lOVEVSVkFMID0gNjA7CgovLyBUaGVtZQooZnVuY3Rpb24oKSB7CiAgY29uc3QgcHJlZiA9IG1hdGNoTWVkaWEoJyhwcmVmZXJzLWNvbG9yLXNjaGVtZTogZGFyayknKS5tYXRjaGVzID8gJ2RhcmsnIDogJ2xpZ2h0JzsKICBkb2N1bWVudC5kb2N1bWVudEVsZW1lbnQuc2V0QXR0cmlidXRlKCdkYXRhLXRoZW1lJywgcHJlZik7CiAgdXBkYXRlVGhlbWVJY29uKHByZWYpOwp9KSgpOwpmdW5jdGlvbiB1cGRhdGVUaGVtZUljb24odCkgewogIGNvbnN0IGljb24gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGhlbWVJY29uJyk7CiAgaWYgKCFpY29uKSByZXR1cm47CiAgaWNvbi5pbm5lckhUTUwgPSB0ID09PSAnZGFyaycKICAgID8gJzxwYXRoIGQ9Ik0yMSAxMi43OUE5IDkgMCAxIDEgMTEuMjEgMyA3IDcgMCAwIDAgMjEgMTIuNzl6Ii8+JwogICAgOiAnPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iNSIvPjxwYXRoIGQ9Ik0xMiAxdjJNMTIgMjF2Mk00LjIyIDQuMjJsMS40MiAxLjQyTTE4LjM2IDE4LjM2bDEuNDIgMS40Mk0xIDEyaDJNMjEgMTJoMk00LjIyIDE5Ljc4bDEuNDItMS40Mk0xOC4zNiA1LjY0bDEuNDItMS40MiIvPic7Cn0KZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RoZW1lVG9nZ2xlJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKSA9PiB7CiAgY29uc3QgaHRtbCA9IGRvY3VtZW50LmRvY3VtZW50RWxlbWVudDsKICBjb25zdCBuZXh0ID0gaHRtbC5nZXRBdHRyaWJ1dGUoJ2RhdGEtdGhlbWUnKSA9PT0gJ2RhcmsnID8gJ2xpZ2h0JyA6ICdkYXJrJzsKICBodG1sLnNldEF0dHJpYnV0ZSgnZGF0YS10aGVtZScsIG5leHQpOwogIHVwZGF0ZVRoZW1lSWNvbihuZXh0KTsKfSk7CgovLyBQYWdlIHRhYnMKZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnBhZ2UtdGFiJykuZm9yRWFjaCh0YWIgPT4gewogIHRhYi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpID0+IHsKICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5wYWdlLXRhYicpLmZvckVhY2godCA9PiB0LmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICAgIHRhYi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICAgIGFjdGl2ZVBhZ2UgPSB0YWIuZGF0YXNldC5wYWdlOwogICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnBhZ2UtdmlldycpLmZvckVhY2godiA9PiB2LmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd2aWV3LScgKyBhY3RpdmVQYWdlKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICB9KTsKfSk7CgovLyBNMzY1IGZldGNoZXMKYXN5bmMgZnVuY3Rpb24gZmV0Y2hIZWFsdGgoKSB7CiAgY29uc3QgcmVzID0gYXdhaXQgZmV0Y2goQVBJICsgJy9hcGkvaGVhbHRoJyk7CiAgaWYgKCFyZXMub2spIHsgY29uc3QgZSA9IGF3YWl0IHJlcy5qc29uKCk7IHRocm93IG5ldyBFcnJvcihlLmVycm9yIHx8IGBIVFRQICR7cmVzLnN0YXR1c31gKTsgfQogIHJldHVybiAoYXdhaXQgcmVzLmpzb24oKSkudmFsdWUgfHwgW107Cn0KYXN5bmMgZnVuY3Rpb24gZmV0Y2hJc3N1ZXMoKSB7CiAgY29uc3QgcmVzID0gYXdhaXQgZmV0Y2goQVBJICsgJy9hcGkvaXNzdWVzJyk7CiAgaWYgKCFyZXMub2spIHsgY29uc3QgZSA9IGF3YWl0IHJlcy5qc29uKCk7IHRocm93IG5ldyBFcnJvcihlLmVycm9yIHx8IGBIVFRQICR7cmVzLnN0YXR1c31gKTsgfQogIHJldHVybiAoYXdhaXQgcmVzLmpzb24oKSkudmFsdWUgfHwgW107Cn0KCi8vIEF6dXJlIHN0YXR1cyBmZXRjaCAoQXp1cmUgUmVzb3VyY2UgR3JhcGgpCmFzeW5jIGZ1bmN0aW9uIGZldGNoQXp1cmVTdGF0dXMoKSB7CiAgY29uc3QgcmVzID0gYXdhaXQgZmV0Y2goQVBJICsgJy9hcGkvYXp1cmUtc3RhdHVzJyk7CiAgaWYgKCFyZXMub2spIHsgY29uc3QgZSA9IGF3YWl0IHJlcy5qc29uKCk7IHRocm93IG5ldyBFcnJvcihlLmVycm9yIHx8IGBIVFRQICR7cmVzLnN0YXR1c31gKTsgfQogIHJldHVybiBhd2FpdCByZXMuanNvbigpOwp9Cgphc3luYyBmdW5jdGlvbiBmZXRjaEFuZFJlbmRlcigpIHsKICBzZXREb3QoJ2xvYWRpbmcnKTsKICBzaG93U2tlbGV0b25zKCk7CiAgdHJ5IHsKICAgIGNvbnN0IFtzZXJ2aWNlcywgaXNzdWVzLCBhenVyZURhdGFdID0gYXdhaXQgUHJvbWlzZS5hbGwoWwogICAgICBmZXRjaEhlYWx0aCgpLAogICAgICBmZXRjaElzc3VlcygpLAogICAgICBmZXRjaEF6dXJlU3RhdHVzKCksCiAgICBdKTsKICAgIGFsbFNlcnZpY2VzID0gc2VydmljZXM7CiAgICBhbGxJc3N1ZXMgPSBpc3N1ZXM7CiAgICBhenVyZUl0ZW1zID0gYXp1cmVEYXRhLmRhdGEgfHwgW107CiAgICByZW5kZXJBbGwoKTsKICAgIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGFzdFVwZGF0ZWQnKS50ZXh0Q29udGVudCA9IGBVcGRhdGVkICR7bm93fWA7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXp1cmVMYXN0VXBkYXRlZCcpLnRleHRDb250ZW50ID0gYFVwZGF0ZWQgJHtub3d9YDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm9ncmVzc1JpbmdXcmFwJykuc3R5bGUuZGlzcGxheSA9ICcnOwogICAgc2V0RG90KCdvaycpOwogIH0gY2F0Y2ggKGUpIHsKICAgIHNldERvdCgnZXJyb3InKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZXJ2aWNlc0NvbnRhaW5lcicpLmlubmVySFRNTCA9IGAKICAgICAgPGRpdiBjbGFzcz0ic3RhdGUtYm94Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0ZS1pY29uIj7imqDvuI88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0ZS10aXRsZSI+Q291bGQgbm90IGxvYWQgZGF0YTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0YXRlLWRlc2MiPiR7ZS5tZXNzYWdlfTxicj48YnI+TWFrZSBzdXJlIHRoZSBzZXJ2ZXIgaXMgcnVubmluZyBhbmQgcmVhY2hhYmxlLjwvZGl2PgogICAgICA8L2Rpdj5gOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dsb2JhbEJhZGdlJykuY2xhc3NOYW1lID0gJ3N0YXR1cy1iYWRnZSBlcnJvcic7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2xvYmFsQmFkZ2VUZXh0JykudGV4dENvbnRlbnQgPSAnRXJyb3InOwogICAgc2hvd1RvYXN0KCdSZWZyZXNoIGZhaWxlZDogJyArIGUubWVzc2FnZSwgJ2Vycm9yJyk7CiAgfQp9CgpmdW5jdGlvbiBzY2hlZHVsZVJlZnJlc2goKSB7CiAgaWYgKHJlZnJlc2hUaW1lcikgY2xlYXJUaW1lb3V0KHJlZnJlc2hUaW1lcik7CiAgaWYgKGNvdW50ZG93blRpbWVyKSBjbGVhckludGVydmFsKGNvdW50ZG93blRpbWVyKTsKICBjb3VudGRvd25TZWMgPSBSRUZSRVNIX0lOVEVSVkFMOwogIHNldFByb2dyZXNzUmluZyhSRUZSRVNIX0lOVEVSVkFMLCBSRUZSRVNIX0lOVEVSVkFMKTsKICBjb3VudGRvd25UaW1lciA9IHNldEludGVydmFsKCgpID0+IHsKICAgIGNvdW50ZG93blNlYy0tOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JlZnJlc2hDb3VudGRvd24nKS50ZXh0Q29udGVudCA9IGAke2NvdW50ZG93blNlY31zYDsKICAgIHNldFByb2dyZXNzUmluZyhjb3VudGRvd25TZWMsIFJFRlJFU0hfSU5URVJWQUwpOwogICAgaWYgKGNvdW50ZG93blNlYyA8PSAwKSBjbGVhckludGVydmFsKGNvdW50ZG93blRpbWVyKTsKICB9LCAxMDAwKTsKICByZWZyZXNoVGltZXIgPSBzZXRUaW1lb3V0KGFzeW5jICgpID0+IHsgYXdhaXQgZmV0Y2hBbmRSZW5kZXIoKTsgc2NoZWR1bGVSZWZyZXNoKCk7IH0sIFJFRlJFU0hfSU5URVJWQUwgKiAxMDAwKTsKfQoKZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JlZnJlc2hCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGFzeW5jICgpID0+IHsKICBpZiAocmVmcmVzaFRpbWVyKSBjbGVhclRpbWVvdXQocmVmcmVzaFRpbWVyKTsKICBpZiAoY291bnRkb3duVGltZXIpIGNsZWFySW50ZXJ2YWwoY291bnRkb3duVGltZXIpOwogIGF3YWl0IGZldGNoQW5kUmVuZGVyKCk7CiAgc2NoZWR1bGVSZWZyZXNoKCk7Cn0pOwoKZnVuY3Rpb24gc2V0UHJvZ3Jlc3NSaW5nKHIsIHQpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvZ3Jlc3NSaW5nJykuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IDU2LjUgKiAoMSAtIHIgLyB0KTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmVmcmVzaENvdW50ZG93bicpLnRleHRDb250ZW50ID0gYCR7cn1zYDsKfQpmdW5jdGlvbiBzZXREb3QocykgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdGF0dXNEb3QnKS5jbGFzc05hbWUgPSAncHVsc2UtZG90JyArIChzID09PSAnZXJyb3InID8gJyBlcnJvcicgOiBzID09PSAnbG9hZGluZycgPyAnIGxvYWRpbmcnIDogJycpOwp9CgpmdW5jdGlvbiByZW5kZXJBbGwoKSB7IHJlbmRlclNlcnZpY2VzKCk7IHJlbmRlckluY2lkZW50cygpOyB1cGRhdGVHbG9iYWxTdGF0dXMoKTsgcmVuZGVyQXp1cmUoKTsgfQoKY29uc3QgSUNPTlMgPSB7CiAgJ0V4Y2hhbmdlJzon8J+TpycsJ1RlYW1zJzon8J+SrCcsJ1NoYXJlUG9pbnQnOifwn5OBJywnT25lRHJpdmUnOifimIHvuI8nLAogICdNaWNyb3NvZnQgMzY1Jzon8J+nqScsJ0VudHJhJzon8J+UkCcsJ0ludHVuZSc6J/Cfk7EnLCdQb3dlciBCSSc6J/Cfk4gnLAogICdQb3dlciBBdXRvbWF0ZSc6J+KaoScsJ1Bvd2VyIEFwcHMnOifwn5SnJywnRHluYW1pY3MnOifwn4+iJywnUGxhbm5lcic6J/Cfk4snLAogICdEZWZlbmRlcic6J/Cfm6HvuI8nLCdWaXZhJzon8J+MsScsJ0NvcGlsb3QnOifwn6SWJywnRm9ybXMnOifwn5OdJywnU3RyZWFtJzon8J+OrCcsCn07CmZ1bmN0aW9uIGdldEljb24obikgewogIGZvciAoY29uc3QgW2ssdl0gb2YgT2JqZWN0LmVudHJpZXMoSUNPTlMpKSBpZiAobi50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKGsudG9Mb3dlckNhc2UoKSkpIHJldHVybiB2OwogIHJldHVybiAn8J+UtSc7Cn0KZnVuY3Rpb24gc3RhdHVzQ2xzKHMpIHsKICBpZiAoIXMpIHJldHVybiAnb2snOwogIGNvbnN0IGwgPSBzLnRvTG93ZXJDYXNlKCk7CiAgaWYgKGwuaW5jbHVkZXMoJ29wZXJhdGlvbmFsJykgJiYgIWwuaW5jbHVkZXMoJ25vbicpKSByZXR1cm4gJ29rJzsKICBpZiAobC5pbmNsdWRlcygnZGVncmFkYXRpb24nKXx8bC5pbmNsdWRlcygnZGVncmFkZWQnKXx8bC5pbmNsdWRlcygnYWR2aXNvcnknKXx8CiAgICAgIGwuaW5jbHVkZXMoJ2ludmVzdGlnYXRpbmcnKXx8bC5pbmNsdWRlcygncmVzdG9yaW5nJyl8fGwuaW5jbHVkZXMoJ3Jlc3RvcmVkJyl8fAogICAgICBsLmluY2x1ZGVzKCdyZWR1Y2VkJyl8fGwuaW5jbHVkZXMoJ2V4dGVuZGVkJykpIHJldHVybiAnd2FybmluZyc7CiAgcmV0dXJuICdlcnJvcic7Cn0KZnVuY3Rpb24gc3RhdHVzTGFiZWwocykgewogIGlmICghcykgcmV0dXJuICdVbmtub3duJzsKICBjb25zdCBtID0gewogICAgc2VydmljZW9wZXJhdGlvbmFsOidPcGVyYXRpb25hbCcsIGludmVzdGlnYXRpbmc6J0ludmVzdGlnYXRpbmcnLAogICAgcmVzdG9yaW5nc2VydmljZTonUmVzdG9yaW5nJywgdmVyaWZ5aW5nc2VydmljZTonVmVyaWZ5aW5nJywKICAgIHNlcnZpY2VkZWdyYWRhdGlvbjonRGVncmFkZWQnLCBzZXJ2aWNlaW50ZXJydXB0aW9uOidPdXRhZ2UnLAogICAgZXh0ZW5kZWRyZWNvdmVyeTonRXh0ZW5kZWQgUmVjb3ZlcnknLCBmYWxzZXBvc2l0aXZlOidGYWxzZSBQb3NpdGl2ZScsCiAgICBpbnZlc3RpZ2F0aW9uc3VzcGVuZGVkOidTdXNwZW5kZWQnLCByZXNvbHZlZDonUmVzb2x2ZWQnLAogICAgcG9zdGluY2lkZW50cmV2aWV3cHVibGlzaGVkOidQSVIgUHVibGlzaGVkJywgc2VydmljZXJlZHVjZWQ6J1JlZHVjZWQnLAogIH07CiAgcmV0dXJuIG1bcy50b0xvd2VyQ2FzZSgpXSB8fCBzOwp9CgpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcygpIHsKICBsZXQgc3ZjcyA9IGFsbFNlcnZpY2VzOwogIGlmIChhY3RpdmVGaWx0ZXIgPT09ICdpc3N1ZXMnKSBzdmNzID0gc3Zjcy5maWx0ZXIocyA9PiBzdGF0dXNDbHMocy5zdGF0dXMpICE9PSAnb2snKTsKICBlbHNlIGlmIChhY3RpdmVGaWx0ZXIgIT09ICdhbGwnKSBzdmNzID0gc3Zjcy5maWx0ZXIocyA9PiBzLnNlcnZpY2UgPT09IGFjdGl2ZUZpbHRlcik7CiAgY29uc3QgY29udGFpbmVyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlcnZpY2VzQ29udGFpbmVyJyk7CiAgY29udGFpbmVyLmlubmVySFRNTCA9ICcnOwogIGlmICghc3Zjcy5sZW5ndGgpIHsKICAgIGNvbnRhaW5lci5pbm5lckhUTUwgPSBgPGRpdiBjbGFzcz0ic3RhdGUtYm94Ij48ZGl2IGNsYXNzPSJzdGF0ZS1pY29uIj7inIU8L2Rpdj48ZGl2IGNsYXNzPSJzdGF0ZS10aXRsZSI+QWxsIHNlcnZpY2VzIG9wZXJhdGlvbmFsPC9kaXY+PGRpdiBjbGFzcz0ic3RhdGUtZGVzYyI+Tm8gaXNzdWVzIG1hdGNoIHRoZSBjdXJyZW50IGZpbHRlci48L2Rpdj48L2Rpdj5gOwogICAgcmV0dXJuOwogIH0KICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgY29uc3QgaCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBoLmNsYXNzTmFtZSA9ICdzZWN0aW9uLXRpdGxlJzsKICBoLnRleHRDb250ZW50ID0gYFNlcnZpY2VzICgke3N2Y3MubGVuZ3RofSlgOyB3cmFwLmFwcGVuZENoaWxkKGgpOwogIGNvbnN0IGdyaWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZ3JpZC5jbGFzc05hbWUgPSAnc2VydmljZS1ncmlkJzsKICBzdmNzLmZvckVhY2goc3ZjID0+IHsKICAgIGNvbnN0IGNscyA9IHN0YXR1c0NscyhzdmMuc3RhdHVzKTsKICAgIGNvbnN0IGNhcmQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIGNhcmQuY2xhc3NOYW1lID0gYHNlcnZpY2UtY2FyZCR7Y2xzICE9PSAnb2snID8gJyAnK2NscyA6ICcnfWA7CiAgICBjYXJkLnRpdGxlID0gc3ZjLnNlcnZpY2U7CiAgICBjYXJkLmlubmVySFRNTCA9IGAKICAgICAgPGRpdiBjbGFzcz0ic2VydmljZS1pY29uIj4ke2dldEljb24oc3ZjLnNlcnZpY2UpfTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZXJ2aWNlLWluZm8iPgogICAgICAgIDxkaXYgY2xhc3M9InNlcnZpY2UtbmFtZSI+JHtzdmMuc2VydmljZX08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZXJ2aWNlLXN0YXR1cy10ZXh0ICR7Y2xzfSI+JHtzdGF0dXNMYWJlbChzdmMuc3RhdHVzKX08L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlcnZpY2UtZG90JHtjbHMgIT09ICdvaycgPyAnICcrY2xzIDogJyd9Ij48L2Rpdj5gOwogICAgZ3JpZC5hcHBlbmRDaGlsZChjYXJkKTsKICB9KTsKICB3cmFwLmFwcGVuZENoaWxkKGdyaWQpOwogIGNvbnRhaW5lci5hcHBlbmRDaGlsZCh3cmFwKTsKfQoKZnVuY3Rpb24gcmVuZGVySW5jaWRlbnRzKCkgewogIGNvbnN0IHNlY3Rpb24gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5jaWRlbnRzU2VjdGlvbicpOwogIGNvbnN0IGxpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5jaWRlbnRzTGlzdCcpOwogIGxpc3QuaW5uZXJIVE1MID0gJyc7CiAgbGV0IGlzc3VlcyA9IGFsbElzc3VlczsKICBpZiAoYWN0aXZlRmlsdGVyICE9PSAnYWxsJyAmJiBhY3RpdmVGaWx0ZXIgIT09ICdpc3N1ZXMnKSBpc3N1ZXMgPSBpc3N1ZXMuZmlsdGVyKGkgPT4gaS5zZXJ2aWNlID09PSBhY3RpdmVGaWx0ZXIpOwogIGlmICghaXNzdWVzLmxlbmd0aCkgeyBzZWN0aW9uLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7IHJldHVybjsgfQogIHNlY3Rpb24uc3R5bGUuZGlzcGxheSA9ICcnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbmNpZGVudHNTZWN0aW9uVGl0bGUnKS50ZXh0Q29udGVudCA9IGBBY3RpdmUgSXNzdWVzICgke2lzc3Vlcy5sZW5ndGh9KWA7CiAgaXNzdWVzLmZvckVhY2goaXNzdWUgPT4gewogICAgY29uc3QgY2xzID0gKGlzc3VlLmNsYXNzaWZpY2F0aW9ufHwnJykudG9Mb3dlckNhc2UoKSA9PT0gJ2luY2lkZW50JyA/ICdpbmNpZGVudCcgOiAnYWR2aXNvcnknOwogICAgY29uc3QgbW9kVGltZSA9IGlzc3VlLmxhc3RNb2RpZmllZERhdGVUaW1lID8gdGltZVNpbmNlKG5ldyBEYXRlKGlzc3VlLmxhc3RNb2RpZmllZERhdGVUaW1lKSkgOiAn4oCUJzsKICAgIGNvbnN0IHN0YXJ0VGltZSA9IGlzc3VlLnN0YXJ0RGF0ZVRpbWUgPyBuZXcgRGF0ZShpc3N1ZS5zdGFydERhdGVUaW1lKS50b0xvY2FsZVN0cmluZygpIDogJ+KAlCc7CiAgICBjb25zdCBwb3N0cyA9IChpc3N1ZS5wb3N0c3x8W10pLnNsaWNlKCkucmV2ZXJzZSgpLnNsaWNlKDAsNSkubWFwKHAgPT4gewogICAgICBjb25zdCB0eHQgPSBwLmRlc2NyaXB0aW9uPy5jb250ZW50ID8gc3RyaXBIdG1sKHAuZGVzY3JpcHRpb24uY29udGVudCkuc3Vic3RyaW5nKDAsNjAwKSA6ICcnOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVwZGF0ZS1lbnRyeSI+PGRpdiBjbGFzcz0idXBkYXRlLXRpbWUiPiR7bmV3IERhdGUocC5jcmVhdGVkRGF0ZVRpbWUpLnRvTG9jYWxlU3RyaW5nKCl9PC9kaXY+PGRpdiBjbGFzcz0idXBkYXRlLXRleHQiPiR7dHh0fTwvZGl2PjwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICAgIGNvbnN0IGNhcmQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIGNhcmQuY2xhc3NOYW1lID0gYGluY2lkZW50LWNhcmQgJHtjbHN9YDsKICAgIGNhcmQuaW5uZXJIVE1MID0gYAogICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1oZWFkZXIiIG9uY2xpY2s9InRvZ2dsZUluY2lkZW50KHRoaXMpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1tYWluIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXRvcCI+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJpbmNpZGVudC1pZCI+JHtpc3N1ZS5pZH08L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJ0eXBlLXBpbGwgJHtjbHN9Ij4ke2Nsc308L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJzdGF0dXMtcGlsbCI+JHtzdGF0dXNMYWJlbChpc3N1ZS5zdGF0dXMpfTwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtdGl0bGUiPiR7aXNzdWUudGl0bGV8fCdVbnRpdGxlZCBJc3N1ZSd9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1zZXJ2aWNlIj4ke2lzc3VlLnNlcnZpY2V8fCcnfSR7aXNzdWUuZmVhdHVyZT8nIMK3ICcraXNzdWUuZmVhdHVyZTonJ308L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1tZXRhIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXRpbWUiPlVwZGF0ZWQgJHttb2RUaW1lfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtdGltZSI+U3RhcnRlZCAke3N0YXJ0VGltZX08L2Rpdj4KICAgICAgICAgIDxzdmcgY2xhc3M9ImNoZXZyb24iIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cG9seWxpbmUgcG9pbnRzPSI2IDkgMTIgMTUgMTggOSIvPjwvc3ZnPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtYm9keSI+CiAgICAgICAgJHtpc3N1ZS5pbXBhY3REZXNjcmlwdGlvbj9gPHAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci10ZXh0KTttYXJnaW4tdG9wOnZhcigtLXNwYWNlLTQpIj4ke2lzc3VlLmltcGFjdERlc2NyaXB0aW9ufTwvcD5gOicnfQogICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXVwZGF0ZXMiPiR7cG9zdHN8fCc8cCBzdHlsZT0iZm9udC1zaXplOnZhcigtLXRleHQteHMpO2NvbG9yOnZhcigtLWNvbG9yLXRleHQtbXV0ZWQpIj5ObyB1cGRhdGVzIHlldC48L3A+J308L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIGxpc3QuYXBwZW5kQ2hpbGQoY2FyZCk7CiAgfSk7Cn0KCmZ1bmN0aW9uIHJlbmRlckF6dXJlKCkgewogIGNvbnN0IGNvbnRhaW5lciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhenVyZUNvbnRhaW5lcicpOwogIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2F6dXJlR2xvYmFsQmFkZ2UnKTsKICBjb25zdCBiYWRnZVRleHQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXp1cmVHbG9iYWxCYWRnZVRleHQnKTsKICBjb25zdCB0YWJCYWRnZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhenVyZUJhZGdlJyk7CgogIC8vIFVwZGF0ZSBNMzY1IGJhZGdlCiAgY29uc3QgbTM2NUNvdW50ID0gYWxsSXNzdWVzLmZpbHRlcihpID0+IChpLmNsYXNzaWZpY2F0aW9ufHwnJykudG9Mb3dlckNhc2UoKSA9PT0gJ2luY2lkZW50JykubGVuZ3RoOwogIGNvbnN0IG0zNjVCYWRnZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtMzY1QmFkZ2UnKTsKICBpZiAobTM2NUNvdW50ID4gMCkgeyBtMzY1QmFkZ2UudGV4dENvbnRlbnQgPSBtMzY1Q291bnQ7IG0zNjVCYWRnZS5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7IH0KICBlbHNlIHsgbTM2NUJhZGdlLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsgfQoKICBpZiAoIWF6dXJlSXRlbXMubGVuZ3RoKSB7CiAgICBjb250YWluZXIuaW5uZXJIVE1MID0gYAogICAgICA8ZGl2IGNsYXNzPSJzdGF0ZS1ib3giPgogICAgICAgIDxkaXYgY2xhc3M9InN0YXRlLWljb24iPuKchTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0YXRlLXRpdGxlIj5ObyBhY3RpdmUgQXp1cmUgZXZlbnRzPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3RhdGUtZGVzYyI+Tm8gYWN0aXZlIHNlcnZpY2UgaXNzdWVzLCBtYWludGVuYW5jZSwgb3IgYWR2aXNvcmllcyBmb3IgeW91ciBzdWJzY3JpcHRpb24uPC9kaXY+CiAgICAgIDwvZGl2PmA7CiAgICBiYWRnZS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIG9rJzsKICAgIGJhZGdlVGV4dC50ZXh0Q29udGVudCA9ICdBbGwgU3lzdGVtcyBPcGVyYXRpb25hbCc7CiAgICB0YWJCYWRnZS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CiAgICByZXR1cm47CiAgfQoKICAvLyBCdWNrZXQgYnkgZXZlbnQgdHlwZQogIGNvbnN0IGlzc3VlcyAgICAgID0gYXp1cmVJdGVtcy5maWx0ZXIoaSA9PiBpLmV2ZW50VHlwZSA9PT0gJ1NlcnZpY2VJc3N1ZScpOwogIGNvbnN0IG1haW50ZW5hbmNlID0gYXp1cmVJdGVtcy5maWx0ZXIoaSA9PiBpLmV2ZW50VHlwZSA9PT0gJ1BsYW5uZWRNYWludGVuYW5jZScpOwogIGNvbnN0IGFkdmlzb3JpZXMgID0gYXp1cmVJdGVtcy5maWx0ZXIoaSA9PiBpLmV2ZW50VHlwZSA9PT0gJ0hlYWx0aEFkdmlzb3J5Jyk7CiAgY29uc3Qgc2VjdXJpdHkgICAgPSBhenVyZUl0ZW1zLmZpbHRlcihpID0+IGkuZXZlbnRUeXBlID09PSAnU2VjdXJpdHlBZHZpc29yeScpOwoKICAvLyBCYWRnZQogIGlmIChpc3N1ZXMubGVuZ3RoKSB7CiAgICBiYWRnZS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIGVycm9yJzsKICAgIGJhZGdlVGV4dC50ZXh0Q29udGVudCA9IGAke2lzc3Vlcy5sZW5ndGh9IEFjdGl2ZSBPdXRhZ2Uke2lzc3Vlcy5sZW5ndGggPiAxID8gJ3MnIDogJyd9YDsKICAgIHRhYkJhZGdlLnRleHRDb250ZW50ID0gaXNzdWVzLmxlbmd0aDsKICAgIHRhYkJhZGdlLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICB9IGVsc2UgaWYgKHNlY3VyaXR5Lmxlbmd0aCkgewogICAgYmFkZ2UuY2xhc3NOYW1lID0gJ3N0YXR1cy1iYWRnZSBlcnJvcic7CiAgICBiYWRnZVRleHQudGV4dENvbnRlbnQgPSBgJHtzZWN1cml0eS5sZW5ndGh9IFNlY3VyaXR5IEFkdmlzb3J5YDsKICAgIHRhYkJhZGdlLnRleHRDb250ZW50ID0gc2VjdXJpdHkubGVuZ3RoOwogICAgdGFiQmFkZ2UuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogIH0gZWxzZSBpZiAobWFpbnRlbmFuY2UubGVuZ3RoIHx8IGFkdmlzb3JpZXMubGVuZ3RoKSB7CiAgICBiYWRnZS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIHdhcm5pbmcnOwogICAgYmFkZ2VUZXh0LnRleHRDb250ZW50ID0gYCR7bWFpbnRlbmFuY2UubGVuZ3RoICsgYWR2aXNvcmllcy5sZW5ndGh9IEV2ZW50JHttYWludGVuYW5jZS5sZW5ndGggKyBhZHZpc29yaWVzLmxlbmd0aCA+IDEgPyAncycgOiAnJ31gOwogICAgdGFiQmFkZ2UuY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpOwogIH0gZWxzZSB7CiAgICBiYWRnZS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIG9rJzsKICAgIGJhZGdlVGV4dC50ZXh0Q29udGVudCA9ICdBbGwgU3lzdGVtcyBPcGVyYXRpb25hbCc7CiAgICB0YWJCYWRnZS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CiAgfQoKICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CgogIGZ1bmN0aW9uIHJlbmRlclNlY3Rpb24oaXRlbXMsIGxhYmVsLCBjYXJkQ2xhc3MsIHBpbGxDbGFzcywgcGlsbExhYmVsKSB7CiAgICBpZiAoIWl0ZW1zLmxlbmd0aCkgcmV0dXJuOwogICAgY29uc3QgaCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBoLmNsYXNzTmFtZSA9ICdzZWN0aW9uLXRpdGxlJzsKICAgIGgudGV4dENvbnRlbnQgPSBgJHtsYWJlbH0gKCR7aXRlbXMubGVuZ3RofSlgOyB3cmFwLmFwcGVuZENoaWxkKGgpOwogICAgY29uc3QgbGlzdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBsaXN0LmNsYXNzTmFtZSA9ICdpbmNpZGVudHMtbGlzdCc7IGxpc3Quc3R5bGUubWFyZ2luQm90dG9tID0gJ3ZhcigtLXNwYWNlLTgpJzsKICAgIGl0ZW1zLmZvckVhY2goaXRlbSA9PiB7CiAgICAgIGNvbnN0IHN0YXJ0VGltZSA9IGl0ZW0uaW1wYWN0U3RhcnRUaW1lID8gbmV3IERhdGUoaXRlbS5pbXBhY3RTdGFydFRpbWUpLnRvTG9jYWxlU3RyaW5nKCkgOiAn4oCUJzsKICAgICAgY29uc3QgdXBkYXRlVGltZSA9IGl0ZW0ubGFzdFVwZGF0ZVRpbWUgPyB0aW1lU2luY2UobmV3IERhdGUoaXRlbS5sYXN0VXBkYXRlVGltZSkpIDogJ+KAlCc7CiAgICAgIGNvbnN0IG1pdGlnVGltZSA9IGl0ZW0ubWl0aWdhdGlvblRpbWUgPyBuZXcgRGF0ZShpdGVtLm1pdGlnYXRpb25UaW1lKS50b0xvY2FsZVN0cmluZygpIDogJ+KAlCc7CgogICAgICAvLyBQYXJzZSBpbXBhY3RlZCBzZXJ2aWNlcyBmcm9tIGltcGFjdCBhcnJheQogICAgICBsZXQgaW1wYWN0ZWRTZXJ2aWNlcyA9ICcnOwogICAgICB0cnkgewogICAgICAgIGNvbnN0IGltcGFjdHMgPSBBcnJheS5pc0FycmF5KGl0ZW0uaW1wYWN0KSA/IGl0ZW0uaW1wYWN0IDogSlNPTi5wYXJzZShpdGVtLmltcGFjdCB8fCAnW10nKTsKICAgICAgICBpbXBhY3RlZFNlcnZpY2VzID0gaW1wYWN0cy5tYXAoaSA9PiBpLkltcGFjdGVkU2VydmljZSB8fCBpLmltcGFjdGVkU2VydmljZSB8fCAnJykuZmlsdGVyKEJvb2xlYW4pLmpvaW4oJywgJyk7CiAgICAgIH0gY2F0Y2goZSkge30KCiAgICAgIC8vIFBhcnNlIGltcGFjdGVkIHJlZ2lvbnMKICAgICAgbGV0IHJlZ2lvbnMgPSAnJzsKICAgICAgdHJ5IHsKICAgICAgICBjb25zdCBpbXBhY3RzID0gQXJyYXkuaXNBcnJheShpdGVtLmltcGFjdCkgPyBpdGVtLmltcGFjdCA6IEpTT04ucGFyc2UoaXRlbS5pbXBhY3QgfHwgJ1tdJyk7CiAgICAgICAgY29uc3QgcmVnaW9uU2V0ID0gbmV3IFNldCgpOwogICAgICAgIGltcGFjdHMuZm9yRWFjaChpID0+IHsKICAgICAgICAgIGNvbnN0IHJMaXN0ID0gaS5JbXBhY3RlZFJlZ2lvbnMgfHwgaS5pbXBhY3RlZFJlZ2lvbnMgfHwgW107CiAgICAgICAgICAoQXJyYXkuaXNBcnJheShyTGlzdCkgPyByTGlzdCA6IFtyTGlzdF0pLmZvckVhY2gociA9PiB7CiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSByLlJlZ2lvbk5hbWUgfHwgci5yZWdpb25OYW1lIHx8IHI7CiAgICAgICAgICAgIGlmIChuYW1lKSByZWdpb25TZXQuYWRkKG5hbWUpOwogICAgICAgICAgfSk7CiAgICAgICAgfSk7CiAgICAgICAgcmVnaW9ucyA9IFsuLi5yZWdpb25TZXRdLnNsaWNlKDAsIDYpLmpvaW4oJywgJyk7CiAgICAgIH0gY2F0Y2goZSkge30KCiAgICAgIGNvbnN0IGNhcmQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgY2FyZC5jbGFzc05hbWUgPSBgaW5jaWRlbnQtY2FyZCAke2NhcmRDbGFzc31gOwogICAgICBjYXJkLmlubmVySFRNTCA9IGAKICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1oZWFkZXIiIG9uY2xpY2s9InRvZ2dsZUluY2lkZW50KHRoaXMpIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LW1haW4iPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC10b3AiPgogICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJpbmNpZGVudC1pZCI+JHtpdGVtLnRyYWNraW5nSWQgfHwgJ+KAlCd9PC9zcGFuPgogICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJ0eXBlLXBpbGwgJHtwaWxsQ2xhc3N9Ij4ke3BpbGxMYWJlbH08L3NwYW4+CiAgICAgICAgICAgICAgJHtpdGVtLmxldmVsID8gYDxzcGFuIGNsYXNzPSJzdGF0dXMtcGlsbCI+JHtpdGVtLmxldmVsfTwvc3Bhbj5gIDogJyd9CiAgICAgICAgICAgICAgJHtpdGVtLnByaW9yaXR5ID8gYDxzcGFuIGNsYXNzPSJzdGF0dXMtcGlsbCI+UCR7aXRlbS5wcmlvcml0eX08L3NwYW4+YCA6ICcnfQogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtdGl0bGUiPiR7aXRlbS50aXRsZSB8fCAnVW50aXRsZWQnfTwvZGl2PgogICAgICAgICAgICAke2ltcGFjdGVkU2VydmljZXMgPyBgPGRpdiBjbGFzcz0iaW5jaWRlbnQtc2VydmljZSI+JHtpbXBhY3RlZFNlcnZpY2VzfTwvZGl2PmAgOiAnJ30KICAgICAgICAgICAgJHtyZWdpb25zID8gYDxkaXYgY2xhc3M9ImluY2lkZW50LXNlcnZpY2UiIHN0eWxlPSJjb2xvcjp2YXIoLS1jb2xvci10ZXh0LWZhaW50KSI+8J+TjSAke3JlZ2lvbnN9PC9kaXY+YCA6ICcnfQogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1tZXRhIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtdGltZSI+VXBkYXRlZCAke3VwZGF0ZVRpbWV9PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXRpbWUiPlN0YXJ0ZWQgJHtzdGFydFRpbWV9PC9kaXY+CiAgICAgICAgICAgICR7aXRlbS5ldmVudFR5cGUgPT09ICdQbGFubmVkTWFpbnRlbmFuY2UnID8gYDxkaXYgY2xhc3M9ImluY2lkZW50LXRpbWUiPkVuZHMgJHttaXRpZ1RpbWV9PC9kaXY+YCA6ICcnfQogICAgICAgICAgICA8c3ZnIGNsYXNzPSJjaGV2cm9uIiB3aWR0aD0iMTYiIGhlaWdodD0iMTYiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiI+PHBvbHlsaW5lIHBvaW50cz0iNiA5IDEyIDE1IDE4IDkiLz48L3N2Zz4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LWJvZHkiPgogICAgICAgICAgJHtpdGVtLnN1bW1hcnkgPyBgPHAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci10ZXh0KTttYXJnaW4tdG9wOnZhcigtLXNwYWNlLTQpO2xpbmUtaGVpZ2h0OjEuNiI+JHtpdGVtLnN1bW1hcnl9PC9wPmAgOiAnJ30KICAgICAgICAgICR7aXRlbS5oZWFkZXIgPyBgPHAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci10ZXh0LW11dGVkKTttYXJnaW4tdG9wOnZhcigtLXNwYWNlLTMpO2xpbmUtaGVpZ2h0OjEuNiI+JHtpdGVtLmhlYWRlcn08L3A+YCA6ICcnfQogICAgICAgICAgPGRpdiBzdHlsZT0ibWFyZ2luLXRvcDp2YXIoLS1zcGFjZS00KTtkaXNwbGF5OmZsZXg7Z2FwOnZhcigtLXNwYWNlLTMpO2ZsZXgtd3JhcDp3cmFwIj4KICAgICAgICAgICAgPGEgaHJlZj0iaHR0cHM6Ly9hcHAuYXp1cmUuY29tL2gvJHtpdGVtLnRyYWNraW5nSWR9IiB0YXJnZXQ9Il9ibGFuayIgcmVsPSJub29wZW5lciIKICAgICAgICAgICAgICAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci1henVyZSk7dGV4dC1kZWNvcmF0aW9uOm5vbmUiPgogICAgICAgICAgICAgIFZpZXcgaW4gQXp1cmUgUG9ydGFsIOKGkgogICAgICAgICAgICA8L2E+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj5gOwogICAgICBsaXN0LmFwcGVuZENoaWxkKGNhcmQpOwogICAgfSk7CiAgICB3cmFwLmFwcGVuZENoaWxkKGxpc3QpOwogIH0KCiAgcmVuZGVyU2VjdGlvbihpc3N1ZXMsICAgICAgJ0FjdGl2ZSBPdXRhZ2VzJywgICAgICAgJ2luY2lkZW50JywgICAgICAgJ2luY2lkZW50JywgICAgICAgJ091dGFnZScpOwogIHJlbmRlclNlY3Rpb24oc2VjdXJpdHksICAgICdTZWN1cml0eSBBZHZpc29yaWVzJywgICdpbmNpZGVudCcsICAgICAgICdpbmNpZGVudCcsICAgICAgICdTZWN1cml0eScpOwogIHJlbmRlclNlY3Rpb24obWFpbnRlbmFuY2UsICdQbGFubmVkIE1haW50ZW5hbmNlJywgICdhZHZpc29yeScsICAgICAgICdhZHZpc29yeScsICAgICAgICdNYWludGVuYW5jZScpOwogIHJlbmRlclNlY3Rpb24oYWR2aXNvcmllcywgICdIZWFsdGggQWR2aXNvcmllcycsICAgICdhZHZpc29yeScsICAgICAgICdhZHZpc29yeScsICAgICAgICdBZHZpc29yeScpOwoKICBjb250YWluZXIuaW5uZXJIVE1MID0gJyc7CiAgY29udGFpbmVyLmFwcGVuZENoaWxkKHdyYXApOwp9CgpmdW5jdGlvbiB0b2dnbGVJbmNpZGVudChoKSB7CiAgaC5uZXh0RWxlbWVudFNpYmxpbmcuY2xhc3NMaXN0LnRvZ2dsZSgnb3BlbicpOwogIGgucXVlcnlTZWxlY3RvcignLmNoZXZyb24nKS5jbGFzc0xpc3QudG9nZ2xlKCdvcGVuJyk7Cn0KCmZ1bmN0aW9uIHVwZGF0ZUdsb2JhbFN0YXR1cygpIHsKICBjb25zdCBpbmNpZGVudHMgPSBhbGxJc3N1ZXMuZmlsdGVyKGkgPT4gKGkuY2xhc3NpZmljYXRpb258fCcnKS50b0xvd2VyQ2FzZSgpPT09J2luY2lkZW50Jyk7CiAgY29uc3QgYWR2aXNvcmllcyA9IGFsbElzc3Vlcy5maWx0ZXIoaSA9PiAoaS5jbGFzc2lmaWNhdGlvbnx8JycpLnRvTG93ZXJDYXNlKCk9PT0nYWR2aXNvcnknKTsKICBjb25zdCBiYWRnZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdnbG9iYWxCYWRnZScpOwogIGNvbnN0IHRleHQgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dsb2JhbEJhZGdlVGV4dCcpOwogIGlmIChpbmNpZGVudHMubGVuZ3RoKSB7CiAgICBiYWRnZS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIGVycm9yJzsKICAgIHRleHQudGV4dENvbnRlbnQgPSBgJHtpbmNpZGVudHMubGVuZ3RofSBBY3RpdmUgSW5jaWRlbnQke2luY2lkZW50cy5sZW5ndGg+MT8ncyc6Jyd9YDsKICB9IGVsc2UgaWYgKGFkdmlzb3JpZXMubGVuZ3RoKSB7CiAgICBiYWRnZS5jbGFzc05hbWUgPSAnc3RhdHVzLWJhZGdlIHdhcm5pbmcnOwogICAgdGV4dC50ZXh0Q29udGVudCA9IGAke2Fkdmlzb3JpZXMubGVuZ3RofSBBZHZpc29yeSR7YWR2aXNvcmllcy5sZW5ndGg+MT8nIElzc3Vlcyc6Jyd9YDsKICB9IGVsc2UgewogICAgYmFkZ2UuY2xhc3NOYW1lID0gJ3N0YXR1cy1iYWRnZSBvayc7CiAgICB0ZXh0LnRleHRDb250ZW50ID0gJ0FsbCBTZXJ2aWNlcyBPcGVyYXRpb25hbCc7CiAgfQp9Cgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZmlsdGVyVGFicycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLmZpbHRlci10YWInKTsKICBpZiAoIXRhYikgcmV0dXJuOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5maWx0ZXItdGFiJykuZm9yRWFjaCh0ID0+IHQuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIHRhYi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBhY3RpdmVGaWx0ZXIgPSB0YWIuZGF0YXNldC5maWx0ZXI7CiAgcmVuZGVyQWxsKCk7Cn0pOwoKZnVuY3Rpb24gc2hvd1NrZWxldG9ucygpIHsKICBjb25zdCBncmlkID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7IGdyaWQuY2xhc3NOYW1lID0gJ3NlcnZpY2UtZ3JpZCc7CiAgZm9yIChsZXQgaSA9IDA7IGkgPCAxMjsgaSsrKSB7CiAgICBjb25zdCBjID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7IGMuY2xhc3NOYW1lID0gJ3NlcnZpY2UtY2FyZCc7CiAgICBjLmlubmVySFRNTCA9IGA8ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9IndpZHRoOjM2cHg7aGVpZ2h0OjM2cHg7Ym9yZGVyLXJhZGl1czo4cHg7ZmxleC1zaHJpbms6MCI+PC9kaXY+PGRpdiBzdHlsZT0iZmxleDoxIj48ZGl2IGNsYXNzPSJza2VsZXRvbiIgc3R5bGU9ImhlaWdodDoxMnB4O3dpZHRoOjgwJTttYXJnaW4tYm90dG9tOjZweCI+PC9kaXY+PGRpdiBjbGFzcz0ic2tlbGV0b24iIHN0eWxlPSJoZWlnaHQ6MTBweDt3aWR0aDo1NSUiPjwvZGl2PjwvZGl2PmA7CiAgICBncmlkLmFwcGVuZENoaWxkKGMpOwogIH0KICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VydmljZXNDb250YWluZXInKS5pbm5lckhUTUwgPSAnJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VydmljZXNDb250YWluZXInKS5hcHBlbmRDaGlsZChncmlkKTsKfQoKZnVuY3Rpb24gdGltZVNpbmNlKGQpIHsKICBjb25zdCBtID0gTWF0aC5mbG9vcigoRGF0ZS5ub3coKS1kKS82MDAwMCk7CiAgaWYgKG08MSkgcmV0dXJuICdqdXN0IG5vdyc7CiAgaWYgKG08NjApIHJldHVybiBgJHttfW0gYWdvYDsKICBjb25zdCBoID0gTWF0aC5mbG9vcihtLzYwKTsKICByZXR1cm4gaDwyND9gJHtofWggYWdvYDpgJHtNYXRoLmZsb29yKGgvMjQpfWQgYWdvYDsKfQpmdW5jdGlvbiBzdHJpcEh0bWwoaHRtbCkgewogIGNvbnN0IGQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZC5pbm5lckhUTUwgPSBodG1sOwogIHJldHVybiBkLnRleHRDb250ZW50fHxkLmlubmVyVGV4dHx8Jyc7Cn0KZnVuY3Rpb24gc2hvd1RvYXN0KG1zZywgdHlwZT0nc3VjY2VzcycpIHsKICBjb25zdCB0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7IHQuY2xhc3NOYW1lPWB0b2FzdCAke3R5cGV9YDsgdC50ZXh0Q29udGVudD1tc2c7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RvYXN0Q29udGFpbmVyJykuYXBwZW5kQ2hpbGQodCk7CiAgc2V0VGltZW91dCgoKT0+dC5yZW1vdmUoKSwgNDAwMCk7Cn0KCmZldGNoQW5kUmVuZGVyKCkudGhlbigoKT0+c2NoZWR1bGVSZWZyZXNoKCkpOwoKLy8g4pSA4pSAIEhpc3RvcnkgVGFiIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsZXQgaGlzdG9yeURheXMgPSAzMDsKbGV0IGhpc3RvcnlTb3VyY2UgPSAnYWxsJzsgIC8vICdhbGwnIHwgJ20zNjUnIHwgJ2F6dXJlJwpsZXQgaGlzdG9yeUxvYWRlZCA9IGZhbHNlOwoKLy8gTGF6eS1sb2FkIGhpc3Rvcnkgd2hlbiB0aGUgdGFiIGlzIGZpcnN0IG9wZW5lZApkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcucGFnZS10YWInKS5mb3JFYWNoKHRhYiA9PiB7CiAgdGFiLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCkgPT4gewogICAgaWYgKHRhYi5kYXRhc2V0LnBhZ2UgPT09ICdoaXN0b3J5JyAmJiAhaGlzdG9yeUxvYWRlZCkgewogICAgICBoaXN0b3J5TG9hZGVkID0gdHJ1ZTsKICAgICAgbG9hZEhpc3RvcnkoKTsKICAgIH0KICB9KTsKfSk7Cgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFuZ2VCdG5zJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICBjb25zdCBidG4gPSBlLnRhcmdldC5jbG9zZXN0KCcucmFuZ2UtYnRuJyk7CiAgaWYgKCFidG4pIHJldHVybjsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcucmFuZ2UtYnRuJykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGJ0bi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBoaXN0b3J5RGF5cyA9IHBhcnNlSW50KGJ0bi5kYXRhc2V0LmRheXMsIDEwKTsKICBsb2FkSGlzdG9yeSgpOwp9KTsKCmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzb3VyY2VGaWx0ZXInKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogIGNvbnN0IGJ0biA9IGUudGFyZ2V0LmNsb3Nlc3QoJy5zb3VyY2UtYnRuJyk7CiAgaWYgKCFidG4pIHJldHVybjsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuc291cmNlLWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBidG4uY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgaGlzdG9yeVNvdXJjZSA9IGJ0bi5kYXRhc2V0LnNvdXJjZTsKICByZW5kZXJIaXN0b3J5KHdpbmRvdy5faGlzdG9yeU0zNjUgfHwgW10sIHdpbmRvdy5faGlzdG9yeUF6dXJlIHx8IFtdKTsKfSk7Cgphc3luYyBmdW5jdGlvbiBsb2FkSGlzdG9yeSgpIHsKICBjb25zdCBjb250YWluZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGlzdG9yeUNvbnRhaW5lcicpOwogIGNvbnRhaW5lci5pbm5lckhUTUwgPSBgPGRpdiBjbGFzcz0iaGlzdG9yeS1sb2FkaW5nIj4KICAgICR7JzxkaXYgY2xhc3M9InNlcnZpY2UtY2FyZCI+PGRpdiBjbGFzcz0ic2tlbGV0b24iIHN0eWxlPSJ3aWR0aDozNnB4O2hlaWdodDozNnB4O2JvcmRlci1yYWRpdXM6OHB4O2ZsZXgtc2hyaW5rOjAiPjwvZGl2PjxkaXYgc3R5bGU9ImZsZXg6MSI+PGRpdiBjbGFzcz0ic2tlbGV0b24iIHN0eWxlPSJoZWlnaHQ6MTJweDt3aWR0aDo4MCU7bWFyZ2luLWJvdHRvbTo2cHgiPjwvZGl2PjxkaXYgY2xhc3M9InNrZWxldG9uIiBzdHlsZT0iaGVpZ2h0OjEwcHg7d2lkdGg6NTUlIj48L2Rpdj48L2Rpdj48L2Rpdj4nLnJlcGVhdCg1KX0KICA8L2Rpdj5gOwoKICB0cnkgewogICAgY29uc3QgW20zNjVSZXMsIGF6dXJlUmVzXSA9IGF3YWl0IFByb21pc2UuYWxsKFsKICAgICAgZmV0Y2goQVBJICsgYC9hcGkvbTM2NS1oaXN0b3J5P2RheXM9JHtoaXN0b3J5RGF5c31gKS50aGVuKHIgPT4gci5qc29uKCkpLAogICAgICBmZXRjaChBUEkgKyBgL2FwaS9henVyZS1oaXN0b3J5P2RheXM9JHtoaXN0b3J5RGF5c31gKS50aGVuKHIgPT4gci5qc29uKCkpLAogICAgXSk7CgogICAgY29uc3QgbTM2NUl0ZW1zICA9IChtMzY1UmVzLnZhbHVlIHx8IFtdKTsKICAgIGNvbnN0IGF6dXJlSXRlbXMgPSAoYXp1cmVSZXMuZGF0YSAgfHwgW10pOwoKICAgIHdpbmRvdy5faGlzdG9yeU0zNjUgID0gbTM2NUl0ZW1zOwogICAgd2luZG93Ll9oaXN0b3J5QXp1cmUgPSBhenVyZUl0ZW1zOwoKICAgIHJlbmRlckhpc3RvcnkobTM2NUl0ZW1zLCBhenVyZUl0ZW1zKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnRhaW5lci5pbm5lckhUTUwgPSBgCiAgICAgIDxkaXYgY2xhc3M9InN0YXRlLWJveCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3RhdGUtaWNvbiI+4pqg77iPPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3RhdGUtdGl0bGUiPkNvdWxkIG5vdCBsb2FkIGhpc3Rvcnk8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0ZS1kZXNjIj4ke2UubWVzc2FnZX08L2Rpdj4KICAgICAgPC9kaXY+YDsKICB9Cn0KCmZ1bmN0aW9uIHJlbmRlckhpc3RvcnkobTM2NUl0ZW1zLCBhenVyZUl0ZW1zKSB7CiAgY29uc3QgY29udGFpbmVyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hpc3RvcnlDb250YWluZXInKTsKCiAgLy8gQnVpbGQgdW5pZmllZCBsaXN0CiAgY29uc3QgY29tYmluZWQgPSBbXTsKCiAgaWYgKGhpc3RvcnlTb3VyY2UgIT09ICdhenVyZScpIHsKICAgIG0zNjVJdGVtcy5mb3JFYWNoKGlzc3VlID0+IHsKICAgICAgY29uc3Qgc29ydERhdGUgPSBpc3N1ZS5sYXN0TW9kaWZpZWREYXRlVGltZSB8fCBpc3N1ZS5zdGFydERhdGVUaW1lOwogICAgICBjb21iaW5lZC5wdXNoKHsKICAgICAgICBzb3VyY2U6ICdtMzY1JywKICAgICAgICBzb3J0RGF0ZSwKICAgICAgICBpZDogICAgICAgaXNzdWUuaWQsCiAgICAgICAgdGl0bGU6ICAgIGlzc3VlLnRpdGxlIHx8ICdVbnRpdGxlZCBJc3N1ZScsCiAgICAgICAgc2VydmljZTogIGlzc3VlLnNlcnZpY2UgfHwgJycsCiAgICAgICAgZmVhdHVyZTogIGlzc3VlLmZlYXR1cmUgfHwgJycsCiAgICAgICAgY2xzOiAgICAgIChpc3N1ZS5jbGFzc2lmaWNhdGlvbnx8JycpLnRvTG93ZXJDYXNlKCkgPT09ICdpbmNpZGVudCcgPyAnaW5jaWRlbnQnIDogJ2Fkdmlzb3J5JywKICAgICAgICBzdGF0dXM6ICAgc3RhdHVzTGFiZWwoaXNzdWUuc3RhdHVzKSwKICAgICAgICBzdGFydFRpbWU6IGlzc3VlLnN0YXJ0RGF0ZVRpbWUgPyBuZXcgRGF0ZShpc3N1ZS5zdGFydERhdGVUaW1lKS50b0xvY2FsZVN0cmluZygpIDogJ+KAlCcsCiAgICAgICAgcmVzb2x2ZWRUaW1lOiBpc3N1ZS5sYXN0TW9kaWZpZWREYXRlVGltZSA/IG5ldyBEYXRlKGlzc3VlLmxhc3RNb2RpZmllZERhdGVUaW1lKS50b0xvY2FsZVN0cmluZygpIDogJ+KAlCcsCiAgICAgICAgcG9zdHM6IChpc3N1ZS5wb3N0cyB8fCBbXSkuc2xpY2UoKS5yZXZlcnNlKCkuc2xpY2UoMCwgMykubWFwKHAgPT4gKHsKICAgICAgICAgIHRpbWU6IG5ldyBEYXRlKHAuY3JlYXRlZERhdGVUaW1lKS50b0xvY2FsZVN0cmluZygpLAogICAgICAgICAgdGV4dDogcC5kZXNjcmlwdGlvbj8uY29udGVudCA/IHN0cmlwSHRtbChwLmRlc2NyaXB0aW9uLmNvbnRlbnQpLnN1YnN0cmluZygwLCA0MDApIDogJycKICAgICAgICB9KSksCiAgICAgICAgaW1wYWN0RGVzY3JpcHRpb246IGlzc3VlLmltcGFjdERlc2NyaXB0aW9uIHx8ICcnLAogICAgICB9KTsKICAgIH0pOwogIH0KCiAgaWYgKGhpc3RvcnlTb3VyY2UgIT09ICdtMzY1JykgewogICAgYXp1cmVJdGVtcy5mb3JFYWNoKGl0ZW0gPT4gewogICAgICBjb25zdCBzb3J0RGF0ZSA9IGl0ZW0ubWl0aWdhdGlvblRpbWUgfHwgaXRlbS5sYXN0VXBkYXRlVGltZSB8fCBpdGVtLmltcGFjdFN0YXJ0VGltZTsKICAgICAgbGV0IGltcGFjdGVkU2VydmljZXMgPSAnJzsKICAgICAgbGV0IHJlZ2lvbnMgPSAnJzsKICAgICAgdHJ5IHsKICAgICAgICBjb25zdCBpbXBhY3RzID0gQXJyYXkuaXNBcnJheShpdGVtLmltcGFjdCkgPyBpdGVtLmltcGFjdCA6IEpTT04ucGFyc2UoaXRlbS5pbXBhY3QgfHwgJ1tdJyk7CiAgICAgICAgaW1wYWN0ZWRTZXJ2aWNlcyA9IGltcGFjdHMubWFwKGkgPT4gaS5JbXBhY3RlZFNlcnZpY2UgfHwgaS5pbXBhY3RlZFNlcnZpY2UgfHwgJycpLmZpbHRlcihCb29sZWFuKS5qb2luKCcsICcpOwogICAgICAgIGNvbnN0IHJlZ2lvblNldCA9IG5ldyBTZXQoKTsKICAgICAgICBpbXBhY3RzLmZvckVhY2goaSA9PiB7CiAgICAgICAgICBjb25zdCByTGlzdCA9IGkuSW1wYWN0ZWRSZWdpb25zIHx8IGkuaW1wYWN0ZWRSZWdpb25zIHx8IFtdOwogICAgICAgICAgKEFycmF5LmlzQXJyYXkockxpc3QpID8gckxpc3QgOiBbckxpc3RdKS5mb3JFYWNoKHIgPT4gewogICAgICAgICAgICBjb25zdCBuYW1lID0gci5SZWdpb25OYW1lIHx8IHIucmVnaW9uTmFtZSB8fCByOwogICAgICAgICAgICBpZiAobmFtZSkgcmVnaW9uU2V0LmFkZChuYW1lKTsKICAgICAgICAgIH0pOwogICAgICAgIH0pOwogICAgICAgIHJlZ2lvbnMgPSBbLi4ucmVnaW9uU2V0XS5zbGljZSgwLCA2KS5qb2luKCcsICcpOwogICAgICB9IGNhdGNoKGUpIHt9CgogICAgICBjb21iaW5lZC5wdXNoKHsKICAgICAgICBzb3VyY2U6ICdhenVyZScsCiAgICAgICAgc29ydERhdGUsCiAgICAgICAgaWQ6ICAgICAgIGl0ZW0udHJhY2tpbmdJZCB8fCAn4oCUJywKICAgICAgICB0aXRsZTogICAgaXRlbS50aXRsZSB8fCAnVW50aXRsZWQnLAogICAgICAgIHNlcnZpY2U6ICBpbXBhY3RlZFNlcnZpY2VzLAogICAgICAgIGZlYXR1cmU6ICByZWdpb25zID8gJ/Cfk40gJyArIHJlZ2lvbnMgOiAnJywKICAgICAgICBjbHM6ICAgICAgaXRlbS5ldmVudFR5cGUgPT09ICdTZXJ2aWNlSXNzdWUnID8gJ2luY2lkZW50JyA6ICdhZHZpc29yeScsCiAgICAgICAgc3RhdHVzOiAgIGl0ZW0uc3RhdHVzIHx8ICdSZXNvbHZlZCcsCiAgICAgICAgc3RhcnRUaW1lOiBpdGVtLmltcGFjdFN0YXJ0VGltZSA/IG5ldyBEYXRlKGl0ZW0uaW1wYWN0U3RhcnRUaW1lKS50b0xvY2FsZVN0cmluZygpIDogJ+KAlCcsCiAgICAgICAgcmVzb2x2ZWRUaW1lOiBpdGVtLm1pdGlnYXRpb25UaW1lID8gbmV3IERhdGUoaXRlbS5taXRpZ2F0aW9uVGltZSkudG9Mb2NhbGVTdHJpbmcoKSA6ICfigJQnLAogICAgICAgIGV2ZW50VHlwZTogaXRlbS5ldmVudFR5cGUsCiAgICAgICAgc3VtbWFyeTogaXRlbS5zdW1tYXJ5IHx8ICcnLAogICAgICAgIGhlYWRlcjogaXRlbS5oZWFkZXIgfHwgJycsCiAgICAgICAgcG9zdHM6IFtdLAogICAgICAgIGltcGFjdERlc2NyaXB0aW9uOiAnJywKICAgICAgfSk7CiAgICB9KTsKICB9CgogIC8vIFNvcnQgbmV3ZXN0IGZpcnN0CiAgY29tYmluZWQuc29ydCgoYSwgYikgPT4gbmV3IERhdGUoYi5zb3J0RGF0ZSkgLSBuZXcgRGF0ZShhLnNvcnREYXRlKSk7CgogIGlmICghY29tYmluZWQubGVuZ3RoKSB7CiAgICBjb250YWluZXIuaW5uZXJIVE1MID0gYAogICAgICA8ZGl2IGNsYXNzPSJoaXN0b3J5LWVtcHR5Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0ZS1pY29uIj7wn5OLPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3RhdGUtdGl0bGUiIHN0eWxlPSJmb250LXNpemU6dmFyKC0tdGV4dC1zbSk7Zm9udC13ZWlnaHQ6NjAwO21hcmdpbi10b3A6dmFyKC0tc3BhY2UtMykiPk5vIHJlc29sdmVkIGluY2lkZW50cyBmb3VuZDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0YXRlLWRlc2MiIHN0eWxlPSJmb250LXNpemU6dmFyKC0tdGV4dC14cyk7Y29sb3I6dmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7bWFyZ2luLXRvcDp2YXIoLS1zcGFjZS0yKSI+CiAgICAgICAgICBObyByZXNvbHZlZCBldmVudHMgZm91bmQgaW4gdGhlIGxhc3QgJHtoaXN0b3J5RGF5c30gZGF5cyBmb3IgdGhlIHNlbGVjdGVkIHNvdXJjZS4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIHJldHVybjsKICB9CgogIC8vIEdyb3VwIGJ5IGNhbGVuZGFyIGRhdGUKICBjb25zdCBncm91cHMgPSB7fTsKICBjb21iaW5lZC5mb3JFYWNoKGl0ZW0gPT4gewogICAgY29uc3QgZCA9IGl0ZW0uc29ydERhdGUgPyBuZXcgRGF0ZShpdGVtLnNvcnREYXRlKSA6IG5ldyBEYXRlKDApOwogICAgY29uc3QgbGFiZWwgPSBkLnRvTG9jYWxlRGF0ZVN0cmluZyh1bmRlZmluZWQsIHsgd2Vla2RheTogJ2xvbmcnLCB5ZWFyOiAnbnVtZXJpYycsIG1vbnRoOiAnbG9uZycsIGRheTogJ251bWVyaWMnIH0pOwogICAgaWYgKCFncm91cHNbbGFiZWxdKSBncm91cHNbbGFiZWxdID0gW107CiAgICBncm91cHNbbGFiZWxdLnB1c2goaXRlbSk7CiAgfSk7CgogIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICB3cmFwLmNsYXNzTmFtZSA9ICdoaXN0b3J5LXRpbWVsaW5lJzsKCiAgT2JqZWN0LmVudHJpZXMoZ3JvdXBzKS5mb3JFYWNoKChbZGF0ZUxhYmVsLCBpdGVtc10pID0+IHsKICAgIGNvbnN0IGdyb3VwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICBncm91cC5jbGFzc05hbWUgPSAnaGlzdG9yeS1kYXRlLWdyb3VwJzsKICAgIGdyb3VwLmlubmVySFRNTCA9IGA8ZGl2IGNsYXNzPSJoaXN0b3J5LWRhdGUtaGVhZGVyIj4ke2RhdGVMYWJlbH0gPHNwYW4gc3R5bGU9ImNvbG9yOnZhcigtLWNvbG9yLXRleHQtZmFpbnQpO2ZvbnQtd2VpZ2h0OjQwMCI+KCR7aXRlbXMubGVuZ3RofSk8L3NwYW4+PC9kaXY+YDsKCiAgICBjb25zdCBsaXN0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICBsaXN0LmNsYXNzTmFtZSA9ICdpbmNpZGVudHMtbGlzdCc7CiAgICBsaXN0LnN0eWxlLm1hcmdpbkJvdHRvbSA9ICd2YXIoLS1zcGFjZS00KSc7CgogICAgaXRlbXMuZm9yRWFjaChpdGVtID0+IHsKICAgICAgY29uc3QgY2FyZCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICBjYXJkLmNsYXNzTmFtZSA9IGBpbmNpZGVudC1jYXJkICR7aXRlbS5jbHN9YDsKCiAgICAgIGNvbnN0IHVwZGF0ZXMgPSBpdGVtLnBvc3RzLm1hcChwID0+CiAgICAgICAgYDxkaXYgY2xhc3M9InVwZGF0ZS1lbnRyeSI+PGRpdiBjbGFzcz0idXBkYXRlLXRpbWUiPiR7cC50aW1lfTwvZGl2PjxkaXYgY2xhc3M9InVwZGF0ZS10ZXh0Ij4ke3AudGV4dH08L2Rpdj48L2Rpdj5gCiAgICAgICkuam9pbignJyk7CgogICAgICBjb25zdCBzb3VyY2VMYWJlbCA9IGl0ZW0uc291cmNlID09PSAnbTM2NScgPyAnTTM2NScgOiAnQXp1cmUnOwogICAgICBjb25zdCBhenVyZVBvcnRhbExpbmsgPSBpdGVtLnNvdXJjZSA9PT0gJ2F6dXJlJwogICAgICAgID8gYDxhIGhyZWY9Imh0dHBzOi8vYXBwLmF6dXJlLmNvbS9oLyR7aXRlbS5pZH0iIHRhcmdldD0iX2JsYW5rIiByZWw9Im5vb3BlbmVyIgogICAgICAgICAgICAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci1henVyZSk7dGV4dC1kZWNvcmF0aW9uOm5vbmU7ZGlzcGxheTppbmxpbmUtYmxvY2s7bWFyZ2luLXRvcDp2YXIoLS1zcGFjZS0zKSI+CiAgICAgICAgICAgICBWaWV3IGluIEF6dXJlIFBvcnRhbCDihpIKICAgICAgICAgICA8L2E+YAogICAgICAgIDogJyc7CgogICAgICBjb25zdCBib2R5Q29udGVudCA9IFsKICAgICAgICBpdGVtLmltcGFjdERlc2NyaXB0aW9uID8gYDxwIHN0eWxlPSJmb250LXNpemU6dmFyKC0tdGV4dC14cyk7Y29sb3I6dmFyKC0tY29sb3ItdGV4dCk7bWFyZ2luLXRvcDp2YXIoLS1zcGFjZS00KTtsaW5lLWhlaWdodDoxLjYiPiR7aXRlbS5pbXBhY3REZXNjcmlwdGlvbn08L3A+YCA6ICcnLAogICAgICAgIGl0ZW0uc3VtbWFyeSAgICAgICAgICAgPyBgPHAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci10ZXh0KTttYXJnaW4tdG9wOnZhcigtLXNwYWNlLTQpO2xpbmUtaGVpZ2h0OjEuNiI+JHtpdGVtLnN1bW1hcnl9PC9wPmAgOiAnJywKICAgICAgICBpdGVtLmhlYWRlciAgICAgICAgICAgID8gYDxwIHN0eWxlPSJmb250LXNpemU6dmFyKC0tdGV4dC14cyk7Y29sb3I6dmFyKC0tY29sb3ItdGV4dC1tdXRlZCk7bWFyZ2luLXRvcDp2YXIoLS1zcGFjZS0zKTtsaW5lLWhlaWdodDoxLjYiPiR7aXRlbS5oZWFkZXJ9PC9wPmAgOiAnJywKICAgICAgICB1cGRhdGVzID8gYDxkaXYgY2xhc3M9ImluY2lkZW50LXVwZGF0ZXMiPiR7dXBkYXRlc308L2Rpdj5gIDogJycsCiAgICAgICAgYXp1cmVQb3J0YWxMaW5rLAogICAgICBdLmZpbHRlcihCb29sZWFuKS5qb2luKCcnKSB8fCBgPHAgc3R5bGU9ImZvbnQtc2l6ZTp2YXIoLS10ZXh0LXhzKTtjb2xvcjp2YXIoLS1jb2xvci10ZXh0LW11dGVkKTttYXJnaW4tdG9wOnZhcigtLXNwYWNlLTQpIj5ObyBhZGRpdGlvbmFsIGRldGFpbHMuPC9wPmA7CgogICAgICBjYXJkLmlubmVySFRNTCA9IGAKICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1oZWFkZXIiIG9uY2xpY2s9InRvZ2dsZUluY2lkZW50KHRoaXMpIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LW1haW4iPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC10b3AiPgogICAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJpbmNpZGVudC1pZCI+JHtpdGVtLmlkfTwvc3Bhbj4KICAgICAgICAgICAgICA8c3BhbiBjbGFzcz0idHlwZS1waWxsICR7aXRlbS5jbHN9Ij4ke2l0ZW0uY2xzfTwvc3Bhbj4KICAgICAgICAgICAgICA8c3BhbiBjbGFzcz0icmVzb2x2ZWQtcGlsbCI+UmVzb2x2ZWQ8L3NwYW4+CiAgICAgICAgICAgICAgPHNwYW4gY2xhc3M9InNvdXJjZS1iYWRnZSAke2l0ZW0uc291cmNlfSI+JHtzb3VyY2VMYWJlbH08L3NwYW4+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC10aXRsZSI+JHtpdGVtLnRpdGxlfTwvZGl2PgogICAgICAgICAgICAke2l0ZW0uc2VydmljZSA/IGA8ZGl2IGNsYXNzPSJpbmNpZGVudC1zZXJ2aWNlIj4ke2l0ZW0uc2VydmljZX0ke2l0ZW0uZmVhdHVyZSA/ICcgwrcgJyArIGl0ZW0uZmVhdHVyZSA6ICcnfTwvZGl2PmAgOiAnJ30KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iaW5jaWRlbnQtbWV0YSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXRpbWUiPlJlc29sdmVkICR7aXRlbS5yZXNvbHZlZFRpbWV9PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImluY2lkZW50LXRpbWUiPlN0YXJ0ZWQgJHtpdGVtLnN0YXJ0VGltZX08L2Rpdj4KICAgICAgICAgICAgPHN2ZyBjbGFzcz0iY2hldnJvbiIgd2lkdGg9IjE2IiBoZWlnaHQ9IjE2IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxwb2x5bGluZSBwb2ludHM9IjYgOSAxMiAxNSAxOCA5Ii8+PC9zdmc+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJpbmNpZGVudC1ib2R5Ij4ke2JvZHlDb250ZW50fTwvZGl2PmA7CgogICAgICBsaXN0LmFwcGVuZENoaWxkKGNhcmQpOwogICAgfSk7CgogICAgZ3JvdXAuYXBwZW5kQ2hpbGQobGlzdCk7CiAgICB3cmFwLmFwcGVuZENoaWxkKGdyb3VwKTsKICB9KTsKCiAgY29udGFpbmVyLmlubmVySFRNTCA9ICcnOwogIGNvbnRhaW5lci5hcHBlbmRDaGlsZCh3cmFwKTsKfQo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==" | base64 -d > "$APP_DIR/public/index.html"
info "public/index.html written"

# ── Restore backed-up config/certs if available ──────────────
if [ -f /tmp/m365-config-backup.json ]; then
  cp /tmp/m365-config-backup.json "$APP_DIR/config.json"
  info "config.json restored from backup"
  rm -f /tmp/m365-config-backup.json
fi
if [ -d /tmp/m365-certs-backup ]; then
  mkdir -p "$APP_DIR/certs"
  cp -r /tmp/m365-certs-backup/. "$APP_DIR/certs/"
  info "Certs restored from backup"
  rm -rf /tmp/m365-certs-backup
fi

# ── Certificate generation ────────────────────────────────────
section "App Registration Certificate"
CERT_DIR="$APP_DIR/certs"
CERT_FILE="$CERT_DIR/m365dash.crt"
KEY_FILE="$CERT_DIR/m365dash.key"

mkdir -p "$CERT_DIR"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
  info "Certificate already exists — skipping generation"
  THUMBPRINT=$(openssl x509 -in "$CERT_FILE" -fingerprint -sha1 -noout 2>/dev/null | sed 's/://g' | cut -d= -f2)
  info "Thumbprint: $THUMBPRINT"
else
  openssl req -x509 -newkey rsa:2048     -keyout "$KEY_FILE"     -out "$CERT_FILE"     -days 3650 -nodes     -subj "/CN=m365-health-dashboard" >/dev/null 2>&1
  THUMBPRINT=$(openssl x509 -in "$CERT_FILE" -fingerprint -sha1 -noout | sed 's/://g' | cut -d= -f2)
  info "Certificate generated (valid 10 years)"
  info "Thumbprint: $THUMBPRINT"
  echo ""
  warn "ACTION REQUIRED: Upload the certificate to your Azure App Registration"
  warn "  1. Go to https://entra.microsoft.com"
  warn "  2. App registrations → your app → Certificates & secrets → Certificates"
  warn "  3. Upload certificate → select this file:"
  warn "     $CERT_FILE"
  warn "  4. After uploading, continue this setup"
  echo ""
  read -rp "  Press Enter once you have uploaded the certificate to Azure..." _DUMMY
fi

# ── Write config.json (only if not already created) ──────────
section "Writing config.json"
if [ -f "$APP_DIR/config.json" ] && ! grep -q "YOUR_TENANT_ID" "$APP_DIR/config.json" 2>/dev/null; then
  info "config.json already exists — skipping"
  # Update cert paths and thumbprint if using cert auth
  if [ -n "$THUMBPRINT" ]; then
    node -e "
      const fs = require('fs');
      const cfg = JSON.parse(fs.readFileSync('$APP_DIR/config.json','utf8'));
      cfg.certPath    = '$CERT_FILE';
      cfg.certKeyPath = '$KEY_FILE';
      cfg.thumbprint  = '$THUMBPRINT';
      delete cfg.clientSecret;
      fs.writeFileSync('$APP_DIR/config.json', JSON.stringify(cfg, null, 2));
      console.log('config.json updated to cert auth');
    " 2>/dev/null && info "config.json updated to use certificate auth" || warn "Could not auto-update config.json — update certPath/certKeyPath/thumbprint manually"
  fi
else
  read -rp "  Tenant ID:       " CFG_TENANT
  read -rp "  Client ID:       " CFG_CLIENT
  read -rp "  Subscription ID (optional, for Azure status): " CFG_SUB
  [[ -z "$CFG_TENANT" ]] && err "Tenant ID is required"
  [[ -z "$CFG_CLIENT" ]] && err "Client ID is required"

  SUB_LINE=""
  [[ -n "$CFG_SUB" ]] && SUB_LINE=",\"subscriptionId\": \"$CFG_SUB\""

  cat > "$APP_DIR/config.json" << CFGEOF
{
  "tenantId":    "$CFG_TENANT",
  "clientId":    "$CFG_CLIENT",
  "certPath":    "$CERT_FILE",
  "certKeyPath": "$KEY_FILE",
  "thumbprint":  "$THUMBPRINT",
  "port":        3000$SUB_LINE
}
CFGEOF
  info "config.json written with certificate auth"
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
ExecStartPre=/bin/chown -R ${SERVICE_USER}:${SERVICE_USER} ${APP_DIR}
ExecStartPre=/bin/chmod 750 ${APP_DIR}
ExecStartPre=/bin/chmod 640 ${APP_DIR}/config.json
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
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
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
