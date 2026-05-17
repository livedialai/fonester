# Fonester — Fonoster Self-Hosted Fork

Vollständig selbstgehostete Fonoster-Instanz **ohne Cloud-Abhängigkeit**.
Eigene Identity, kein api.fonoster.com, kein GitHub-OAuth.

## Schnellstart (empfohlen)

```bash
git clone https://github.com/livedialai/fonester
cd fonester
chmod +x install.sh
./install.sh
```

Das Script führt **interaktiv** durch die komplette Installation:
- Prüft & installiert alle Abhängigkeiten (Docker, Nginx, Certbot, Git)
- Fragt Domain ab & validiert den DNS A-Record
- Fragt Admin-Email & Passwort interaktiv ab
- Wendet alle nötigen Fixes automatisch an
- Holt SSL-Zertifikat, konfiguriert Nginx
- Baut das Dashboard und startet alle Services

**Nach erfolgreicher Installation:** `https://deine-domain.de` aufrufen.

---

## Manuelle Installation (Schritt für Schritt)

### Voraussetzungen

- Linux-Server (Debian 12 getestet) mit öffentlicher IP
- Domain mit DNS-A-Record auf den Server
- Docker & Docker Compose
- Nginx & Certbot (für HTTPS)

```bash
# 1. Repo klonen
git clone https://github.com/livedialai/fonester
cd fonester

# 2. IP in .env setzen (3 Stellen: ROUTR_EXTERNAL_ADDRS, RTPENGINE_PUBLIC_IP, ASTERISK_SIPPROXY_HOST)
sed -i 's/SET_YOUR_IP/DEINE_IP/' .env

# 3. SERVER_DASHBOARD_SESSION_SECRET generieren
echo "SERVER_DASHBOARD_SESSION_SECRET=$(openssl rand -hex 32)" >> .env

# 4. Domain in nginx-fonoster.conf setzen
sed -i 's/fonoster\.DEINE_DOMAIN\.de/deine-domain.de/g' nginx-fonoster.conf

# 5. proxy_pass muss HTTP sein (Envoy spricht plain HTTP, Nginx terminiert TLS)
sed -i 's|proxy_pass https://127.0.0.1:8449;|proxy_pass http://127.0.0.1:8449;|g' nginx-fonoster.conf

# 6. compose.yaml Fix: doppelte rtpengine-Env-Eintraege entfernen
# Zeilen 141-143 (zweites PORT_MAX, PORT_MIN, PUBLIC_IP) löschen
sed -i '141,143d' compose.yaml

# 7. compose.yaml Fix: DASHBOARD_ALLOW_INSECURE für Dashboard-SSR
# Unter "environment:" des dashboard-Service einfügen:
#   - DASHBOARD_ALLOW_INSECURE=true

# 8. config/envoy.yaml Fix: gRPC-Web+proto Content-Type supporten
# Die Regex-Zeilen ersetzen:
#   regex: "^(application/grpc|application/grpc-web-text)$"
#   -> regex: "^(application/grpc|application/grpc-web-text|application/grpc-web[+]proto)$"

# 9. Integrations-Datei vorbereiten (Docker erstellt sonst Verzeichnis!)
rm -rf config/integrations.json
cp config/integrations.example.json config/integrations.json

# 10. Let's Encrypt Zertifikat holen
systemctl stop nginx
certbot certonly --standalone -d deine-domain.de
systemctl start nginx

# 11. Nginx konfigurieren
cp nginx-fonoster.conf /etc/nginx/sites-available/fonoster
ln -sf /etc/nginx/sites-available/fonoster /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# 12. Keys generieren
mkdir -p config/keys
openssl genpkey -algorithm RSA -out config/keys/private.pem
openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem

# 13. Dashboard Image bauen (mit --build-arg DASHBOARD_ALLOW_INSECURE=true)
cd mods/dashboard
docker build --build-arg DASHBOARD_ALLOW_INSECURE=true -t fonoster/dashboard:0.17.1 .
cd ../..

# 14. Alles starten
docker compose up -d

# 15. Login
# Oeffne https://deine-domain.de
```

---

## Login-Daten

Die Login-Daten werden waehrend `install.sh` interaktiv abgefragt.
Bei manueller Installation: Email + Passwort aus `.env` (`APISERVER_OWNER_EMAIL`, `APISERVER_OWNER_PASSWORD`).

**Nach dem ersten Login Passwort aendern!**

---

## Was wurde geaendert (vs. upstream Fonoster)

### 1. RTPEngine: `network_mode: host` (compose.yaml)
Erforderlich unter Linux fuer den Port-Bereich 10000-10100. Docker `ports`-Mapping reicht nicht.

### 2. Dashboard: `expose` -> `ports` (compose.yaml)
Upstream hatte `expose: - 3030:3030` — das ist kein gueltiges Docker-Format. Korrigiert auf `ports: - 3030:3030`.

### 3. Kein `api.fonoster.com` (Dashboard-Code)
- `mods/dashboard/src/core/sdk/stores/fonoster.config.ts`: Client-URL auf `window.location.origin` statt `api.fonoster.com`
- `mods/dashboard/src/core/sdk/client/fonoster.client.ts`: Gleiche Logik im WebClient

### 4. Lokale Identity (`.env`)
- `APISERVER_IDENTITY_ISSUER=http://fonoster.local`
- `APISERVER_IDENTITY_OAUTH2_GITHUB_ENABLED=false`
- `APISERVER_IDENTITY_CONTACT_VERIFICATION_REQUIRED=false`
- `APISERVER_IDENTITY_TWO_FACTOR_AUTHENTICATION_REQUIRED=false`

### 5. Nginx Reverse-Proxy (`nginx-fonoster.conf`)
SSL-Terminierung + Proxy zu Envoy:8449 ueber **HTTP** (nicht HTTPS).

### 6. Envoy gRPC-Web Routing-Fix (`config/envoy.yaml`)
Content-Type `application/grpc-web+proto` wird jetzt korrekt zum Apiserver geroutet.

### 7. Dashboard SSR TLS-Fix (`compose.yaml`)
`DASHBOARD_ALLOW_INSECURE=true` damit Server-Side-Rendering per HTTP mit Envoy kommuniziert.

---

## Architektur

```
Browser (https://deine-domain.de)
    │
    ▼
Nginx (SSL-Terminierung, Port 443)
    │
    ▼
Envoy (Port 8449, HTTP) ──► Dashboard (3030)
    │                        API-Server (50051)
    │                        Autopilot (50061)
    │
    ▼
PostgreSQL ── InfluxDB ── NATS
    │
Routr (SIP 5060) ──► RTPEngine (10000-20000)
    │
Asterisk (6060)
```

---

## Troubleshooting

### Login: "14 UNAVAILABLE: SSL wrong version number"
- `DASHBOARD_ALLOW_INSECURE=true` muss im Dashboard-Container gesetzt sein
- Dashboard muss mit diesem Build-Arg gebaut sein: `docker build --build-arg DASHBOARD_ALLOW_INSECURE=true`
- `proxy_pass` in nginx muss `http://127.0.0.1:8449` sein (nicht https!)

### Login: "404 Not Found" nach Credentials-Eingabe
- Envoy-Regex in `config/envoy.yaml` pruefen: muss `application/grpc-web[+]proto` enthalten

### Apiserver crash-loop: EISDIR integrations.json
- `config/integrations.json` ist ein Docker-Verzeichnis statt Datei
- Fix: `rm -rf config/integrations.json && cp config/integrations.example.json config/integrations.json`
- Container neu erstellen: `docker rm -f fonester-apiserver-1 && docker compose up -d apiserver`

### Envoy startet nicht: yaml-cpp unknown escape character
- Kein `\+` in Regex verwenden, stattdessen `[+]` (Character-Class)

### Container startet nicht: compose.yaml invalid
- Doppelte Keys in rtpengine-Sektion (PORT_MAX, PORT_MIN, PUBLIC_IP) entfernen

### RTPEngine startet nicht
- Unter Linux MUSS `network_mode: host` gesetzt sein
- Ports 10000-20000/udp muessen in der Firewall offen sein

### Envoy erreicht nichts
- `docker compose logs envoy` pruefen
- `config/envoy.yaml` muss existieren
