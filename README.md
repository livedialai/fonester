# Fonester — Fonoster Self-Hosted Fork

Vollständig selbstgehostete Fonoster-Instanz **ohne Cloud-Abhängigkeit**.
Eigene Identity, kein api.fonoster.com, kein GitHub-OAuth.

## Schnellstart

```bash
git clone https://github.com/livedialai/fonester
cd fonester
chmod +x install.sh
./install.sh
```

Das Script fragt interaktiv Domain, Email und Passwort ab und erledigt alles Weitere.

**Nach Installation:** `https://deine-domain.de` aufrufen.

---

## Manuelle Installation

### Voraussetzungen

- Debian 12 Server mit öffentlicher IP
- Domain mit DNS A-Record auf den Server
- Docker, Docker Compose, Nginx, Certbot, Git

### Schritte

```bash
# 1. Repo klonen
git clone https://github.com/livedialai/fonester
cd fonester

# 2. IP in .env setzen
sed -i 's/SET_YOUR_IP/DEINE_IP/' .env

# 3. Login-Daten in .env setzen
sed -i 's/APISERVER_OWNER_EMAIL=.*/APISERVER_OWNER_EMAIL=admin@deine-domain.de/' .env
sed -i 's/APISERVER_OWNER_PASSWORD=.*/APISERVER_OWNER_PASSWORD=DEIN_PASSWORT/' .env

# 4. Session Secret generieren
echo "SERVER_DASHBOARD_SESSION_SECRET=$(openssl rand -hex 32)" >> .env

# 5. Domain in nginx-fonoster.conf setzen
sed -i 's/fonoster\.DEINE_DOMAIN\.de/deine-domain.de/g' nginx-fonoster.conf

# 6. proxy_pass: https → http (Envoy spricht plain HTTP)
sed -i 's|proxy_pass https://127.0.0.1:8449;|proxy_pass http://127.0.0.1:8449;|g' nginx-fonoster.conf

# 7. compose.yaml: doppelte rtpengine-Keys entfernen (Zeilen 141-143)
sed -i '141,143d' compose.yaml

# 8. compose.yaml: DASHBOARD_ALLOW_INSECURE=true hinzufügen
# (per Python-Script, siehe install.sh)

# 9. config/envoy.yaml: grpc-web+proto Regex fixen
# regex: "^(application/grpc|application/grpc-web-text)$"
# → regex: "^(application/grpc|application/grpc-web-text|application/grpc-web[+]proto)$"

# 10. integrations.json vorbereiten (Docker erstellt sonst Verzeichnis!)
rm -rf config/integrations.json
cp config/integrations.example.json config/integrations.json

# 11. SSL-Zertifikat
systemctl stop nginx
certbot certonly --standalone -d deine-domain.de
systemctl start nginx

# 12. Nginx aktivieren
cp nginx-fonoster.conf /etc/nginx/sites-available/fonoster
ln -sf /etc/nginx/sites-available/fonoster /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# 13. Keys generieren
mkdir -p config/keys
openssl genpkey -algorithm RSA -out config/keys/private.pem
openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem

# 14. Dashboard bauen (WICHTIG: Build-Args!)
cd mods/dashboard
docker build \
    --build-arg DASHBOARD_ALLOW_INSECURE=true \
    --build-arg DASHBOARD_EDITION="" \
    --build-arg DASHBOARD_AUTH_GITHUB_ENABLED=false \
    --build-arg DASHBOARD_AUTH_GITHUB_CLIENT_ID="" \
    --build-arg DASHBOARD_API_URL="" \
    -t fonoster/dashboard:0.17.1 .
cd ../..

# 15. Alles starten
docker compose up -d

# 16. Login: https://deine-domain.de
```

---

## Login

Email und Passwort wie in `.env` konfiguriert (`APISERVER_OWNER_EMAIL` / `APISERVER_OWNER_PASSWORD`).

**Nach dem ersten Login Passwort ändern!**

---

## Änderungen vs. Upstream Fonoster

1. **RTPEngine:** `network_mode: host` für Linux
2. **Dashboard:** `expose` → `ports` korrigiert
3. **Kein api.fonoster.com:** Client-URL = `window.location.origin`
4. **Lokale Identity:** Kein GitHub-OAuth, `APISERVER_IDENTITY_ISSUER=http://fonoster.local`
5. **Nginx:** SSL-Terminierung, Proxy zu Envoy über **HTTP**
6. **Envoy:** gRPC-Web+proto Content-Type Routing-Fix
7. **Dashboard SSR:** `DASHBOARD_ALLOW_INSECURE=true`

---

## Architektur

```
Browser (HTTPS) → Nginx :443 → Envoy :8449 (HTTP) → Dashboard :3030
                                                      API-Server :50051
                                                      Autopilot :50061
                         PostgreSQL ← InfluxDB ← NATS
                         Routr :5060 → RTPEngine :10000-20000
                         Asterisk :6060
```

---

## Troubleshooting

### "14 UNAVAILABLE: SSL wrong version number" beim Login
- Dashboard muss mit `--build-arg DASHBOARD_ALLOW_INSECURE=true` gebaut sein
- `proxy_pass` in Nginx muss `http://` sein (nicht `https://`)

### GitHub-Login-Button sichtbar
- Dashboard muss mit `--build-arg DASHBOARD_AUTH_GITHUB_ENABLED=false` und `--build-arg DASHBOARD_EDITION=""` gebaut sein

### Apiserver crash-loop: EISDIR integrations.json
- `rm -rf config/integrations.json && cp config/integrations.example.json config/integrations.json`
- `docker rm -f fonester-apiserver-1 && docker compose up -d apiserver`

### Envoy startet nicht: unknown escape character
- Kein `\+` im Regex — `[+]` verwenden

### compose.yaml: mapping key already defined
- Doppelte PORT_MAX/PORT_MIN/PUBLIC_IP in rtpengine-Sektion entfernen
