#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# Fonester — Fonoster Self-Hosted Installer
# Vollständig selbstgehostet, keine Cloud-Abhängigkeit
# ═══════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║         Fonester — Self-Hosted Installer              ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# ── Root-Check ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Als root ausführen."

# ── 1. Abhängigkeiten ────────────────────────────────────────
info "Prüfe Abhängigkeiten..."

apt-get update -qq

# Docker
if ! command -v docker &>/dev/null; then
    warn "Installiere Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
fi
log "Docker: $(docker --version 2>/dev/null | head -1)"

# Docker Compose
if ! docker compose version &>/dev/null; then
    apt-get install -y -qq docker-compose-plugin
fi
log "Compose: $(docker compose version 2>/dev/null | head -1)"

# Git, Nginx, Certbot
for pkg in git nginx certbot python3-certbot-nginx; do
    if ! dpkg -l "$pkg" &>/dev/null && ! command -v "$pkg" &>/dev/null; then
        apt-get install -y -qq "$pkg"
    fi
done
systemctl enable nginx --now 2>/dev/null || true
log "Git: $(git --version)"
log "Nginx: $(nginx -v 2>&1)"
log "Certbot: $(certbot --version 2>/dev/null | head -1)"
echo ""

# ── 2. IP ermitteln ─────────────────────────────────────────
SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')
info "Server-IP: $SERVER_IP"

# ── 3. Domain abfragen ───────────────────────────────────────
while true; do
    read -rp "Domain: " DOMAIN
    [[ -z "$DOMAIN" ]] && warn "Domain darf nicht leer sein." && continue
    break
done

# ── 4. DNS prüfen ───────────────────────────────────────────
info "Prüfe DNS A-Record..."

if ! command -v dig &>/dev/null; then
    apt-get install -y -qq dnsutils
fi

DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)

if [[ -z "$DNS_IP" ]]; then
    warn "Kein A-Record für $DOMAIN!"
    warn "→ Richte ein: $DOMAIN A $SERVER_IP"
    read -rp "Enter drücken wenn fertig... "
    DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)
    [[ -z "$DNS_IP" ]] && err "DNS immer noch nicht auflösbar."
fi

if [[ "$DNS_IP" != "$SERVER_IP" ]]; then
    warn "DNS: $DOMAIN → $DNS_IP (Server: $SERVER_IP)"
    read -rp "Trotzdem fortfahren? (j/N): " cont
    [[ "$cont" != "j" && "$cont" != "J" ]] && err "Abbruch."
else
    log "DNS OK: $DOMAIN → $DNS_IP"
fi
echo ""

# ── 5. Login-Daten ──────────────────────────────────────────
read -rp "Admin Email [admin@$DOMAIN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

while true; do
    read -rsp "Admin Passwort (min. 8 Zeichen): " ADMIN_PASSWORD
    echo ""
    [[ ${#ADMIN_PASSWORD} -lt 8 ]] && warn "Mindestens 8 Zeichen." && continue
    read -rsp "Passwort wiederholen: " ADMIN_PASSWORD2
    echo ""
    [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD2" ]] && warn "Passwörter ungleich." && continue
    break
done
echo ""

# ── 6. Repo einrichten ──────────────────────────────────────
FONESTER_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$FONESTER_DIR/compose.yaml" ]]; then
    FONESTER_DIR="/opt/fonester"
    if [[ -d "$FONESTER_DIR/.git" ]]; then
        cd "$FONESTER_DIR" && git pull
    else
        git clone https://github.com/livedialai/fonester.git "$FONESTER_DIR"
    fi
fi
cd "$FONESTER_DIR"
log "Repository: $FONESTER_DIR"

# ── 7. .env konfigurieren ────────────────────────────────────
log "Konfiguriere .env..."

# IP (3 Stellen)
sed -i "s/SET_YOUR_IP/$SERVER_IP/g" .env

# Login-Daten
sed -i "s/APISERVER_OWNER_EMAIL=.*/APISERVER_OWNER_EMAIL=$ADMIN_EMAIL/" .env
sed -i "s/APISERVER_OWNER_PASSWORD=.*/APISERVER_OWNER_PASSWORD=$ADMIN_PASSWORD/" .env

# Session Secret
if ! grep -q "SERVER_DASHBOARD_SESSION_SECRET=" .env; then
    echo "SERVER_DASHBOARD_SESSION_SECRET=$(openssl rand -hex 32)" >> .env
fi

log ".env konfiguriert"
echo ""

# ── 8. Compose-YAML patchen ─────────────────────────────────
log "Patch compose.yaml..."

# Fix: Doppelte rtpengine-Keys entfernen
python3 << 'PYFIX'
with open('compose.yaml', 'r') as f:
    lines = f.readlines()

found_public_ip = False
result = []
for line in lines:
    s = line.strip()
    # Check if this is a duplicate rtpengine env key
    if s in ('PORT_MAX: ${RTPENGINE_PORT_MAX}', 'PORT_MIN: ${RTPENGINE_PORT_MIN}', 'PUBLIC_IP: ${RTPENGINE_PUBLIC_IP}'):
        if not found_public_ip:
            result.append(line)
        if s.startswith('PUBLIC_IP:'):
            found_public_ip = True
        continue
    result.append(line)

with open('compose.yaml', 'w') as f:
    f.writelines(result)
PYFIX

# Fix: DASHBOARD_ALLOW_INSECURE=true
if ! grep -q "DASHBOARD_ALLOW_INSECURE" compose.yaml; then
    python3 << 'PYFIX2'
with open('compose.yaml', 'r') as f:
    c = f.read()
c = c.replace(
    '      - SERVER_DASHBOARD_SESSION_SECRET\n\n  apiserver:',
    '      - SERVER_DASHBOARD_SESSION_SECRET\n      - DASHBOARD_ALLOW_INSECURE=true\n\n  apiserver:'
)
with open('compose.yaml', 'w') as f:
    f.write(c)
PYFIX2
fi

docker compose config -q 2>/dev/null || err "compose.yaml ungültig!"
log "compose.yaml OK"
echo ""

# ── 9. Envoy-Config patchen ─────────────────────────────────
log "Patch config/envoy.yaml..."

if ! grep -q "grpc-web\[+\]proto" config/envoy.yaml; then
    python3 << 'PYENVOY'
with open('config/envoy.yaml', 'r') as f:
    c = f.read()
old = '^(application/grpc|application/grpc-web-text)$'
new = '^(application/grpc|application/grpc-web-text|application/grpc-web[+]proto)$'
c = c.replace(old, new)
with open('config/envoy.yaml', 'w') as f:
    f.write(c)
PYENVOY
    log "Envoy gRPC-Web+proto Regex gefixt"
else
    log "Envoy-Config bereits gepatcht"
fi
echo ""

# ── 10. integrations.json ───────────────────────────────────
log "Bereite Config-Dateien vor..."
rm -rf config/integrations.json
cp config/integrations.example.json config/integrations.json
log "integrations.json erstellt"
echo ""

# ── 11. SSL-Zertifikat ──────────────────────────────────────
info "Hole Let's Encrypt Zertifikat..."

if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    log "Zertifikat existiert bereits"
else
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone \
        -d "$DOMAIN" \
        --non-interactive --agree-tos \
        --email "$ADMIN_EMAIL" \
        --quiet || {
        systemctl start nginx
        err "SSL fehlgeschlagen. DNS-Eintrag korrekt?"
    }
    log "SSL-Zertifikat erstellt"
fi

# ── 12. Nginx konfigurieren ─────────────────────────────────
log "Konfiguriere Nginx..."

# Domain einsetzen (Platzhalter: fonoster.DEINE_DOMAIN.de)
sed -i "s/fonoster\.DEINE_DOMAIN\.de/$DOMAIN/g" nginx-fonoster.conf

# proxy_pass http (Envoy spricht plain HTTP)
sed -i 's|proxy_pass https://127.0.0.1:8449;|proxy_pass http://127.0.0.1:8449;|g' nginx-fonoster.conf

cp nginx-fonoster.conf /etc/nginx/sites-available/fonoster
ln -sf /etc/nginx/sites-available/fonoster /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl start nginx && systemctl reload nginx
log "Nginx konfiguriert"
echo ""

# ── 13. Keys generieren ─────────────────────────────────────
log "Generiere RSA-Keys..."
mkdir -p config/keys
if [[ ! -f config/keys/private.pem ]]; then
    openssl genpkey -algorithm RSA -out config/keys/private.pem 2>/dev/null
    openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem 2>/dev/null
fi
log "Keys bereit"
echo ""

# ── 14. Dashboard bauen ─────────────────────────────────────
info "Baue Dashboard (2-5 Minuten)..."

cd mods/dashboard
docker build \
    --build-arg DASHBOARD_ALLOW_INSECURE=true \
    --build-arg DASHBOARD_EDITION="" \
    --build-arg DASHBOARD_AUTH_GITHUB_ENABLED=false \
    --build-arg DASHBOARD_AUTH_GITHUB_CLIENT_ID="" \
    --build-arg DASHBOARD_API_URL="" \
    -t fonoster/dashboard:0.17.1 \
    . 2>&1 | tail -3
cd "$FONESTER_DIR"
log "Dashboard gebaut"
echo ""

# ── 15. Images pullen & starten ─────────────────────────────
info "Pulle Docker-Images..."
docker compose pull 2>&1 | tail -3

info "Starte alle Services..."
docker compose up -d 2>&1

sleep 12

# ── 16. Healthcheck ─────────────────────────────────────────
info "Healthcheck..."

ALL_OK=true
for svc in dashboard apiserver routr envoy postgres; do
    STATUS=$(docker inspect "fonester-${svc}-1" --format '{{.State.Status}}' 2>/dev/null || echo "down")
    if [[ "$STATUS" == "running" ]]; then
        log "$svc"
    else
        warn "$svc: $STATUS"
        ALL_OK=false
    fi
done

# ── 17. HTTPS-Test ──────────────────────────────────────────
HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/" 2>/dev/null || echo "000")
if [[ "$HTTP" == "200" || "$HTTP" == "302" ]]; then
    log "HTTPS: https://$DOMAIN/ → $HTTP"
else
    warn "HTTPS: $HTTP — warte 10s..."
    sleep 10
    HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/" 2>/dev/null || echo "000")
    log "HTTPS: $HTTP"
fi

# ── 18. Fertig ──────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║     Fonester ist bereit!                               ║"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  URL:      https://$DOMAIN"
echo "║  Email:    $ADMIN_EMAIL"
echo "║  Passwort: (dein gewähltes)"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  Bitte Passwort nach dem ersten Login ändern!          ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
