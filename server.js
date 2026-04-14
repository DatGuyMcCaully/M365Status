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
