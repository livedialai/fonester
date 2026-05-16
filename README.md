# Fonester — Fonoster Self-Hosted Fork

Vollständig selbstgehostete Fonoster-Instanz **ohne Cloud-Abhängigkeit**.
Eigene Identity, kein api.fonoster.com, kein GitHub-OAuth.

## Voraussetzungen

- Linux-Server (Debian 12 getestet) mit öffentlicher IP
- Domain mit DNS-A-Record auf den Server
- Docker & Docker Compose
- Nginx & Certbot (für HTTPS)

## Schnellstart

```bash
# 1. Repo klonen
git clone https://github.com/livedialai/fonester
cd fonester

# 2. IP in .env setzen (3 Stellen: ROUTR_EXTERNAL_ADDRS, RTPENGINE_PUBLIC_IP, ASTERISK_SIPPROXY_HOST)
sed -i 's/SET_YOUR_IP/DEINE_IP/' .env

# 3. Domain in nginx-fonoster.conf setzen
sed -i 's/DEINE_DOMAIN/deine-domain/' nginx-fonoster.conf

# 4. Let's Encrypt Zertifikat holen
certbot certonly --standalone -d fonoster.deine-domain.de

# 5. Nginx konfigurieren
cp nginx-fonoster.conf /etc/nginx/sites-available/fonoster
ln -s /etc/nginx/sites-available/fonoster /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 6. Keys generieren
mkdir -p config/keys
openssl genpkey -algorithm RSA -out config/keys/private.pem
openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem

# 7. Dashboard Image bauen (mit unseren Patches)
docker compose -f compose.dashboard-build.yaml build --no-cache
docker compose -f compose.dashboard-build.yaml up -d  # nur bauen, dann stoppen

# 8. Alles starten
docker compose up -d

# 9. Login
# Öffne https://fonoster.deine-domain.de
# Email: admin@fonoster.local
# Passwort: Call1870
```

## Was wurde geändert (vs. upstream Fonoster)

### 1. RTPEngine: `network_mode: host` (compose.yaml)
Erforderlich unter Linux für den Port-Bereich 10000-10100. Docker `ports`-Mapping reicht nicht.

### 2. Dashboard: `expose` → `ports` (compose.yaml)
Upstream hatte `expose: - 3030:3030` — das ist kein gültiges Docker-Format. Korrigiert auf `ports: - 3030:3030`.

### 3. Kein `api.fonoster.com` (Dashboard-Code)
- `mods/dashboard/src/core/sdk/stores/fonoster.config.ts`: Client-URL auf `window.location.origin` statt `api.fonoster.com`
- `mods/dashboard/src/core/sdk/client/fonoster.client.ts`: Gleiche Logik im WebClient

### 4. Lokale Identity (`.env`)
- `APISERVER_IDENTITY_ISSUER=http://fonoster.local`
- `APISERVER_IDENTITY_OAUTH2_GITHUB_ENABLED=false`
- `APISERVER_IDENTITY_CONTACT_VERIFICATION_REQUIRED=false`
- `APISERVER_IDENTITY_TWO_FACTOR_AUTHENTICATION_REQUIRED=false`

### 5. Nginx Reverse-Proxy (`nginx-fonoster.conf`)
SSL-Terminierung + Proxy zu Envoy:8449.

## Login-Daten (Default)

| Feld | Wert |
|------|------|
| Email | `admin@fonoster.local` |
| Passwort | `Call1870` |

**Nach dem ersten Login Passwort ändern!**

## Architektur

```
Browser (https://fonoster.domain.de)
    │
    ▼
Nginx (SSL-Terminierung, Port 443)
    │
    ▼
Envoy (Port 8449) ──► Dashboard (3030)
    │                  API-Server (50051)
    │                  Autopilot (50061)
    │
    ▼
PostgreSQL ── InfluxDB ── NATS
    │
Routr (SIP 5060) ──► RTPEngine (10000-20000)
    │
Asterisk (6060)
```

## Troubleshooting

### Login schlägt fehl (PERMISSION_DENIED)
→ Identity-Issuer in `.env` prüfen: `APISERVER_IDENTITY_ISSUER=http://fonoster.local`
→ Dashboard-Code prüft ob `api.fonoster.com` noch hartkodiert ist

### RTPEngine startet nicht
→ Unter Linux MUSS `network_mode: host` gesetzt sein
→ Ports 10000-20000/udp müssen in der Firewall offen sein

### Envoy erreicht nichts
→ `docker compose logs envoy` prüfen
→ `config/envoy.yaml` muss existieren
