#!/usr/bin/env bash
# Fonester — Fonoster Self-Hosted Installer
# curl -sSL https://raw.githubusercontent.com/livedialai/fonester/main/install.sh | bash
set -euo pipefail

GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' RED='\033[0;31m' NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║         Fonester — Self-Hosted Installer              ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# ═══ 1. Abhängigkeiten ═══════════════════════════════════════
info "Installiere Abhängigkeiten..."
apt-get update -qq

command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | bash; systemctl enable docker; }
log "Docker: $(docker --version 2>/dev/null | head -1)"

docker compose version &>/dev/null || apt-get install -y -qq docker-compose-plugin
log "Compose: $(docker compose version 2>/dev/null | head -1)"

for pkg in git nginx certbot python3-certbot-nginx; do
    dpkg -l "$pkg" &>/dev/null && continue
    command -v "${pkg%%-*}" &>/dev/null && continue
    apt-get install -y -qq "$pkg"
done
log "Nginx: $(nginx -v 2>&1)"
log "Certbot: $(certbot --version 2>/dev/null | head -1)"
echo ""

# ═══ 2. IP ═══════════════════════════════════════════════════
SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')
info "Server-IP: $SERVER_IP"

# ═══ 3. Domain ════════════════════════════════════════════════
read -rp "Domain: " DOMAIN
[[ -z "$DOMAIN" ]] && err "Domain erforderlich."

# DNS
command -v dig &>/dev/null || apt-get install -y -qq dnsutils
DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)
if [[ -z "$DNS_IP" ]]; then
    warn "Kein A-Record: $DOMAIN → $SERVER_IP noch nicht gesetzt."
    read -rp "Enter wenn DNS bereit... "
    DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)
    [[ -z "$DNS_IP" ]] && err "DNS immer noch nicht auflösbar."
fi
[[ "$DNS_IP" != "$SERVER_IP" ]] && warn "DNS zeigt auf $DNS_IP, Server ist $SERVER_IP"
log "Domain: $DOMAIN"
echo ""

# ═══ 4. Login ═════════════════════════════════════════════════
read -rp "Admin Email [admin@$DOMAIN]: " ADMIN_EMAIL; ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}
while true; do
    read -rsp "Admin Passwort (min. 8): " ADMIN_PASS; echo ""
    [[ ${#ADMIN_PASS} -lt 8 ]] && warn "Min. 8 Zeichen." && continue
    read -rsp "Wiederholen: " ADMIN_PASS2; echo ""
    [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]] && warn "Ungleich." && continue
    break
done
SESSION_SECRET=$(openssl rand -hex 32)
echo ""

# ═══ 5. Repo clonen ══════════════════════════════════════════
FONESTER_DIR="/opt/fonester"
if [[ -d "$FONESTER_DIR/.git" ]]; then cd "$FONESTER_DIR" && git pull; else
    git clone https://github.com/livedialai/fonester.git "$FONESTER_DIR"; fi
cd "$FONESTER_DIR"
log "Repository: $FONESTER_DIR"

# ═══ 6. .env ══════════════════════════════════════════════════
log "Konfiguriere .env..."
sed -i "s/SET_YOUR_IP/$SERVER_IP/g" .env
sed -i "s|ROUTR_RTPENGINE_HOST=rtpengine|ROUTR_RTPENGINE_HOST=$SERVER_IP|" .env
sed -i "s/APISERVER_OWNER_EMAIL=.*/APISERVER_OWNER_EMAIL=$ADMIN_EMAIL/" .env
sed -i "s/APISERVER_OWNER_PASSWORD=.*/APISERVER_OWNER_PASSWORD=$ADMIN_PASS/" .env
grep -q "SERVER_DASHBOARD_SESSION_SECRET=" .env || echo "SERVER_DASHBOARD_SESSION_SECRET=$SESSION_SECRET" >> .env
log ".env bereit"
echo ""

# ═══ 7. compose.yaml fixes ═══════════════════════════════════
log "Patch compose.yaml..."
FIXDIR="$(mktemp -d)"
cat > "$FIXDIR/fix_compose.py" << 'PYFIX'
with open('compose.yaml', 'r') as f: lines = f.readlines()
seen = set(); result = []
for l in lines:
    s = l.strip()
    if s in ('PORT_MAX: ${RTPENGINE_PORT_MAX}', 'PORT_MIN: ${RTPENGINE_PORT_MIN}', 'PUBLIC_IP: ${RTPENGINE_PUBLIC_IP}'):
        if s in seen: continue; seen.add(s)
    result.append(l)
with open('compose.yaml', 'w') as f: f.writelines(result)
PYFIX
python3 "$FIXDIR/fix_compose.py"

# DASHBOARD_ALLOW_INSECURE
if ! grep -q "DASHBOARD_ALLOW_INSECURE" compose.yaml; then
    sed -i '/SERVER_DASHBOARD_SESSION_SECRET/a\      - DASHBOARD_ALLOW_INSECURE=true' compose.yaml
fi

docker compose config -q 2>/dev/null || err "compose.yaml ungültig."
log "compose.yaml OK"
echo ""

# ═══ 8. envoy.yaml fix ═══════════════════════════════════════
log "Patch config/envoy.yaml..."
sed -i 's|^(application/grpc|application/grpc-web-text)$|^(application/grpc|application/grpc-web-text|application/grpc-web[+]proto)$|g' config/envoy.yaml
log "Envoy-Regex gefixt"
echo ""

# ═══ 9. integrations.json ════════════════════════════════════
rm -rf config/integrations.json
cp config/integrations.example.json config/integrations.json
log "integrations.json bereit"
echo ""

# ═══ 10. Dashboard patchen (nach fonoster-README) ═══════════
info "Patch Dashboard-Source..."

# fonoster.config.ts — hart codiert: keine Cloud, allowInsecure
cat > mods/dashboard/src/core/sdk/stores/fonoster.config.ts << 'TSCONFIG'
/*
 * Copyright (C) 2025 by Fonoster Inc (https://fonoster.com)
 * http://github.com/fonoster/fonoster
 *
 * Licensed under the MIT License
 */

const INTERNAL_API_URL = "http://envoy:8449";
const { hostname, port } = new URL(INTERNAL_API_URL);

export const FONOSTER_CLIENT_CONFIG = Object.freeze({
  url: "",
  accessKeyId: "",
  allowInsecure: typeof window !== "undefined"
});

export const FONOSTER_SERVER_CONFIG = Object.freeze({
  endpoint: `${hostname}${port ? `:${port}` : ""}`,
  accessKeyId: "",
  allowInsecure: true,
  accessToken: ""
});

export const FONOSTER_RESET_PASSWORD_URL = "";
export const IS_CLOUD = false;
export const IS_PRIVATE_BETA = false;
export const IS_SIGNUP_ENABLED = false;
TSCONFIG

# fonoster.client.ts
cat > mods/dashboard/src/core/sdk/client/fonoster.client.ts << 'TSCLIENT'
/*
 * Copyright (C) 2025 by Fonoster Inc (https://fonoster.com)
 * http://github.com/fonoster/fonoster
 *
 * Licensed under the MIT License
 */

import * as SDK from "@fonoster/sdk/dist/web/index.esm.js";
import { Logger } from "~/core/shared/logger";

export const getClient = () => {
  Logger.debug("[fonoster.client] Creating Fonoster WebClient instance");
  const url = typeof window !== "undefined" ? window.location.origin : "";
  const fonosterClient = new SDK.WebClient({ url, accessKeyId: "" });
  return fonosterClient;
};

export { SDK };
TSCLIENT

log "Dashboard-Source gepatcht"
echo ""

# ═══ 11. Dashboard bauen ═════════════════════════════════════
info "Baue Dashboard-Image (2-5 min)..."
cd mods/dashboard
docker build -t fonoster-dashboard-local:0.17.1 . 2>&1 | tail -3
cd "$FONESTER_DIR"

# compose.yaml: eigenes Image statt upstream
sed -i 's|image: fonoster/dashboard:0.17.1|image: fonoster-dashboard-local:0.17.1|' compose.yaml
log "Dashboard-Image: fonoster-dashboard-local:0.17.1"
echo ""

# ═══ 12. SSL-Zertifikat ══════════════════════════════════════
info "SSL-Zertifikat..."

if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    log "Zertifikat existiert"
else
    # Temp Nginx für webroot
    mkdir -p /var/www/html
    cat > /etc/nginx/sites-available/fonoster-temp << NGINXTMP
server { listen 80; server_name $DOMAIN; root /var/www/html; }
NGINXTMP
    ln -sf /etc/nginx/sites-available/fonoster-temp /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl start nginx 2>/dev/null || true
    certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
        --non-interactive --agree-tos --email "$ADMIN_EMAIL" --quiet
    log "Zertifikat erstellt"
fi

# ═══ 13. Nginx Reverse-Proxy ══════════════════════════════════
log "Konfiguriere Nginx..."

cat > /etc/nginx/sites-available/fonoster << NGINX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8449;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/fonoster /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/fonoster-temp /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log "Nginx bereit"
echo ""

# ═══ 14. Keys ═════════════════════════════════════════════════
mkdir -p config/keys
if [[ ! -f config/keys/private.pem ]]; then
    openssl genpkey -algorithm RSA -out config/keys/private.pem 2>/dev/null
    openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem 2>/dev/null
fi
log "RSA-Keys bereit"
echo ""

# ═══ 15. Starten ══════════════════════════════════════════════
info "Starte Fonester..."
docker compose pull 2>&1 | tail -3
docker compose up -d 2>&1
sleep 15

# ═══ 16. Healthcheck ══════════════════════════════════════════
for svc in dashboard apiserver routr envoy postgres; do
    s=$(docker inspect "fonester-${svc}-1" --format '{{.State.Status}}' 2>/dev/null || echo "down")
    [[ "$s" == "running" ]] && log "$svc" || warn "$svc: $s"
done

HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/" 2>/dev/null || echo "000")
[[ "$HTTP" == "200" || "$HTTP" == "302" ]] && log "HTTPS: $HTTP" || warn "HTTPS: $HTTP"

# ═══ 17. Fertig ═══════════════════════════════════════════════
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║     Fonester bereit!                                   ║"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  URL:      https://$DOMAIN"
echo "║  Email:    $ADMIN_EMAIL"
echo "║  Passwort: (dein gewähltes)"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
