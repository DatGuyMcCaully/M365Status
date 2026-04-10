#Known issue

I'm having some issues getting auto approval of the Entra app to work, so you may have to manually grant access via Entra -> App Registration -> App -> API Permissions

It needs Mircosoft Graph
ServiceHealth.Read.ALL
ServiceMessage.Read.All

# M365 Service Health Dashboard

A lightweight, self-hosted dashboard that displays Microsoft 365 service health status and active incidents in real time. Pulls data from the Microsoft Graph API using an Azure app registration — no M365 licenses or user accounts required.

![Dashboard](https://img.shields.io/badge/Node.js-18%2B-green) ![License](https://img.shields.io/badge/license-MIT-blue)

## Features

- Live service status grid for all M365 services (Exchange, Teams, SharePoint, OneDrive, etc.)
- Active incident panel with expandable update history
- Filter tabs: All / Issues Only / Exchange / Teams / SharePoint / OneDrive
- Auto-refreshes every 60 seconds with a countdown indicator
- Dark / light mode (follows system preference)
- Zero npm dependencies — pure Node.js

## Requirements

- A Linux server (Ubuntu 20.04+, Debian 11+, RHEL/Rocky/CentOS 8+)
- A domain name pointed at your server (for HTTPS via Let's Encrypt)
- An Azure / Microsoft 365 tenant with Global Admin access to create an app registration

---

## Quick Start

### Step 1 — Create the Azure app registration

Run `az-setup.sh` on your server. It will:
- Install Azure CLI
- Prompt you to log in via device code (requires Global Admin)
- Create an Entra ID app registration named `m365-health-dashboard`
- Generate a 2-year self-signed certificate
- Grant `ServiceHealth.Read.All` and `ServiceMessage.Read.All` permissions
- Write `/opt/m365-dashboard/config.json` automatically

```bash
sudo bash az-setup.sh
```

> If you prefer a client secret over a certificate, skip this step and fill in `config.json` manually (see below).

### Step 2 — Install and start the dashboard

```bash
sudo bash setup.sh
```

This will:
- Install Node.js 20 and nginx
- Write all app files to `/opt/m365-dashboard/`
- Create a dedicated `m365dash` system user
- Register and start a systemd service (`m365-dashboard`)
- Optionally configure Let's Encrypt HTTPS (you'll be prompted)

---

## Manual Setup (without az-setup.sh)

### 1. Create an Azure app registration

1. Go to [Entra ID → App registrations → New registration](https://entra.microsoft.com)
2. Name: anything (e.g. `m365-health-dashboard`)
3. Supported account types: **Single tenant**
4. No redirect URI needed
5. After creation, go to **API permissions → Add a permission → Microsoft Graph → Application permissions**
6. Add both:
   - `ServiceHealth.Read.All`
   - `ServiceMessage.Read.All`
7. Click **Grant admin consent**
8. Go to **Certificates & secrets** and create a client secret (copy it immediately)

### 2. Configure credentials

```bash
cp config.example.json config.json
nano config.json
```

Fill in your `tenantId`, `clientId`, and either `clientSecret` or cert paths.

### 3. Run the server

```bash
node server.js
```

The dashboard will be available at `http://localhost:3000`.

---

## Configuration

`config.json` supports two authentication modes:

### Client secret (simpler)
```json
{
  "tenantId":     "your-tenant-id",
  "clientId":     "your-client-id",
  "clientSecret": "your-client-secret",
  "port":         3000
}
```

### Certificate (recommended — no expiry surprises)
```json
{
  "tenantId":    "your-tenant-id",
  "clientId":    "your-client-id",
  "certPath":    "/opt/m365-dashboard/certs/m365dash.crt",
  "certKeyPath": "/opt/m365-dashboard/certs/m365dash.key",
  "thumbprint":  "CERT_SHA1_THUMBPRINT",
  "port":        3000
}
```

> **Never commit `config.json` to source control.** It is listed in `.gitignore`.

---

## nginx Reverse Proxy

`setup.sh` configures nginx automatically. If you're setting it up manually, use this config:

```nginx
server {
    listen 80;
    server_name yourdomain.com;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

---

## Running alongside other sites

nginx routes by `server_name`, so multiple sites on the same server won't conflict as long as each has its own `server_name` defined. See the nginx docs on [virtual hosts](https://nginx.org/en/docs/http/server_names.html).

---

## Useful Commands

```bash
# View live logs
journalctl -u m365-dashboard -f

# Restart the service
systemctl restart m365-dashboard

# Check status
systemctl status m365-dashboard

# Test nginx config
nginx -t

# Renew Let's Encrypt cert
certbot renew --dry-run

# Rotate the app cert (re-run az-setup.sh)
sudo bash az-setup.sh
systemctl restart m365-dashboard
```

---

## Security Notes

- Credentials are stored server-side only — never exposed to the browser
- `config.json` is set to mode `640` (readable by the service user only)
- The `m365dash` system user has no login shell and no home directory
- The systemd service runs with `NoNewPrivileges`, `PrivateTmp`, and `ProtectSystem=strict`
- Port 3000 is only accessible via nginx on localhost — block it externally:
  ```bash
  ufw deny 3000
  ```

---

## License

MIT
