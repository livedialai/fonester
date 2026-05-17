#!/usr/bin/env bash
# bash <(curl -sSL https://raw.githubusercontent.com/livedialai/fonester/main/install.sh)
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

# ═══ DOMAIN ══════════════════════════════════════════════════
read -rp "Domain: " DOMAIN </dev/tty
[[ -z "$DOMAIN" ]] && err "Domain erforderlich."

# ═══ EMAIL ════════════════════════════════════════════════════
read -rp "Admin Email [admin@$DOMAIN]: " ADMIN_EMAIL </dev/tty
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

# ═══ PASSWORT ═════════════════════════════════════════════════
while true; do
    read -rsp "Admin Passwort (min. 8): " ADMIN_PASS </dev/tty; echo ""
    [[ ${#ADMIN_PASS} -lt 8 ]] && warn "Min. 8 Zeichen." && continue
    read -rsp "Wiederholen: " ADMIN_PASS2 </dev/tty; echo ""
    [[ "$ADMIN_PASS" != "$ADMIN_PASS2" ]] && warn "Ungleich." && continue
    break
done
echo ""

# ═══ 1. Abhängigkeiten ═══════════════════════════════════════
info "Installiere Abhängigkeiten..."
apt-get update -qq

command -v docker &>/dev/null || { curl -fsSL https://get.docker.com | bash; systemctl enable docker; }
log "Docker: $(docker --version 2>/dev/null | head -1)"

docker compose version &>/dev/null || apt-get install -y -qq docker-compose-plugin
log "Compose: $(docker compose version 2>/dev/null | head -1)"

for pkg in git nginx certbot python3-certbot-nginx; do
    command -v "${pkg%%-*}" &>/dev/null && continue
    apt-get install -y -qq "$pkg"
done
log "Nginx: $(nginx -v 2>&1)"
log "Certbot: $(certbot --version 2>/dev/null | head -1)"
echo ""

# ═══ 2. IP ═══════════════════════════════════════════════════
SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')
info "Server-IP: $SERVER_IP"

# DNS
command -v dig &>/dev/null || apt-get install -y -qq dnsutils
DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)
if [[ -z "$DNS_IP" ]]; then
    warn "Kein A-Record: $DOMAIN → $SERVER_IP"
    read -rp "Enter wenn DNS bereit... " </dev/tty
    DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)
    [[ -z "$DNS_IP" ]] && err "DNS immer noch nicht auflösbar."
fi
[[ "$DNS_IP" != "$SERVER_IP" ]] && warn "DNS: $DNS_IP (Server: $SERVER_IP)"
log "Domain: $DOMAIN → $DNS_IP"
echo ""

# ═══ 3. Repo clonen ══════════════════════════════════════════
SESSION_SECRET=$(openssl rand -hex 32)
FONESTER_DIR="/opt/fonester"
if [[ -d "$FONESTER_DIR/.git" ]]; then cd "$FONESTER_DIR" && git pull; else
    git clone https://github.com/livedialai/fonester.git "$FONESTER_DIR"; fi
cd "$FONESTER_DIR"

# ═══ 4. .env ══════════════════════════════════════════════════
log "Konfiguriere .env..."
export IP="$SERVER_IP" EMAIL="$ADMIN_EMAIL" PASS="$ADMIN_PASS" SECRET="$SESSION_SECRET"
python3 << 'PYENV'
import os, re
with open('.env', 'r') as f: content = f.read()
content = content.replace('SET_YOUR_IP', os.environ['IP'])
content = re.sub(r'ROUTR_RTPENGINE_HOST=\S+', 'ROUTR_RTPENGINE_HOST=' + os.environ['IP'], content)
content = re.sub(r'APISERVER_OWNER_EMAIL=\S*', 'APISERVER_OWNER_EMAIL=' + os.environ['EMAIL'], content)
content = re.sub(r'APISERVER_OWNER_PASSWORD=\S*', 'APISERVER_OWNER_PASSWORD=' + os.environ['PASS'], content)
if 'SERVER_DASHBOARD_SESSION_SECRET=' not in content:
    content += '\nSERVER_DASHBOARD_SESSION_SECRET=' + os.environ['SECRET'] + '\n'
with open('.env', 'w') as f: f.write(content)
PYENV

# ═══ 5. compose.yaml fixes ═══════════════════════════════════
python3 << 'PYFIX'
with open('compose.yaml', 'r') as f: lines = f.readlines()
seen = set(); result = []
for l in lines:
    s = l.strip()
    if s in ('PORT_MAX: ${RTPENGINE_PORT_MAX}', 'PORT_MIN: ${RTPENGINE_PORT_MIN}', 'PUBLIC_IP: ${RTPENGINE_PUBLIC_IP}'):
        if s in seen: continue; seen.add(s)
    result.append(l)
with open('compose.yaml', 'w') as f:
    # add DASHBOARD_ALLOW_INSECURE after SERVER_DASHBOARD_SESSION_SECRET if missing
    final = []
    for l in result:
        final.append(l)
        if 'SERVER_DASHBOARD_SESSION_SECRET' in l and 'DASHBOARD_ALLOW_INSECURE' not in ''.join(result):
            final.append('      - DASHBOARD_ALLOW_INSECURE=true\n')
    f.writelines(final)
PYFIX

docker compose config -q 2>/dev/null || err "compose.yaml ungültig."

# ═══ 6. envoy.yaml fix ═══════════════════════════════════════
sed -i -E 's#^(application/grpc|application/grpc-web-text)$#^(application/grpc|application/grpc-web-text|application/grpc-web[+]proto)$#g' config/envoy.yaml

# ═══ 7. integrations.json ════════════════════════════════════
rm -rf config/integrations.json
cp config/integrations.example.json config/integrations.json

# ═══ 8. Dashboard-Source patchen ═════════════════════════════
info "Patch Dashboard-Source..."

cat > mods/dashboard/src/core/sdk/stores/fonoster.config.ts << 'TSCFG'
const INTERNAL_API_URL = "http://envoy:8449";
const { hostname, port } = new URL(INTERNAL_API_URL);
export const FONOSTER_CLIENT_CONFIG = Object.freeze({
  url: "", accessKeyId: "",
  allowInsecure: typeof window !== "undefined"
});
export const FONOSTER_SERVER_CONFIG = Object.freeze({
  endpoint: `${hostname}${port ? `:${port}` : ""}`,
  accessKeyId: "", allowInsecure: true, accessToken: ""
});
export const FONOSTER_RESET_PASSWORD_URL = "";
export const IS_CLOUD = false;
export const IS_PRIVATE_BETA = false;
export const IS_SIGNUP_ENABLED = false;
TSCFG

cat > mods/dashboard/src/core/sdk/client/fonoster.client.ts << 'TSCLI'
import * as SDK from "@fonoster/sdk/dist/web/index.esm.js";
import { Logger } from "~/core/shared/logger";
export const getClient = () => {
  Logger.debug("[fonoster.client] Creating Fonoster WebClient instance");
  const url = typeof window !== "undefined" ? window.location.origin : "";
  return new SDK.WebClient({ url, accessKeyId: "" });
};
export { SDK };
TSCLI

log "Dashboard-Source gepatcht"

# ═══ 9. Dashboard bauen ═════════════════════════════════════
info "Baue Dashboard (2-5 min)..."
cd mods/dashboard
docker build -t fonoster-dashboard-local:0.17.1 . 2>&1 | tail -3
cd "$FONESTER_DIR"
sed -i 's|image: fonoster/dashboard:0.17.1|image: fonoster-dashboard-local:0.17.1|' compose.yaml

# ═══ 10. SSL ══════════════════════════════════════════════════
info "SSL-Zertifikat..."
if [[ ! -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    mkdir -p /var/www/html
    cat > /etc/nginx/sites-available/fonoster-temp << NGINXTMP
server { listen 80; server_name $DOMAIN; root /var/www/html; }
NGINXTMP
    ln -sf /etc/nginx/sites-available/fonoster-temp /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl start nginx 2>/dev/null || true
    certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
        --non-interactive --agree-tos --email "$ADMIN_EMAIL" --quiet
fi

# ═══ 11. Nginx ════════════════════════════════════════════════
cat > /etc/nginx/sites-available/fonoster << NGINX
server {
    listen 80; server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; server_name $DOMAIN;
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

# ═══ 12. Keys ═════════════════════════════════════════════════
mkdir -p config/keys
if [[ ! -f config/keys/private.pem ]]; then
    openssl genpkey -algorithm RSA -out config/keys/private.pem 2>/dev/null
    openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem 2>/dev/null
fi

# ═══ 13. Starten ══════════════════════════════════════════════
info "Starte Fonester..."
docker compose pull 2>&1 | tail -3
docker compose up -d 2>&1
sleep 15

# ═══ 14. Healthcheck ══════════════════════════════════════════
for svc in dashboard apiserver routr envoy postgres; do
    s=$(docker inspect "fonester-${svc}-1" --format '{{.State.Status}}' 2>/dev/null || echo "down")
    [[ "$s" == "running" ]] && log "$svc" || warn "$svc: $s"
done
HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/" 2>/dev/null || echo "000")
[[ "$HTTP" == "200" || "$HTTP" == "302" ]] && log "HTTPS: $HTTP" || warn "HTTPS: $HTTP"

# ═══ Fertig ═══════════════════════════════════════════════════
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║     https://$DOMAIN"
echo "║     $ADMIN_EMAIL  /  (dein Passwort)"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
