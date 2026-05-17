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
echo "║    Fonoster ohne Cloud-Abhängigkeit                   ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# ── Root-Check ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Dieses Script muss als root ausgeführt werden."
fi

# ── 1. Abhängigkeiten prüfen & installieren ─────────────────
info "Prüfe Abhängigkeiten..."

install_if_missing() {
    local pkg=$1 cmd=$2 name=$3
    if ! command -v "$cmd" &>/dev/null; then
        warn "$name nicht gefunden — installiere..."
        apt-get install -y -qq "$pkg"
        log "$name installiert"
    else
        log "$name gefunden: $($cmd --version 2>/dev/null | head -1 || echo 'ok')"
    fi
}

apt-get update -qq

# Docker
if ! command -v docker &>/dev/null; then
    warn "Docker nicht gefunden — installiere..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    log "Docker installiert"
else
    log "Docker: $(docker --version)"
fi

# Docker Compose Plugin
if ! docker compose version &>/dev/null; then
    apt-get install -y -qq docker-compose-plugin
fi
log "Docker Compose: $(docker compose version 2>/dev/null | head -1)"

# Git, Nginx, Certbot
install_if_missing "git"    "git"     "Git"
install_if_missing "nginx"  "nginx"   "Nginx"
install_if_missing "certbot" "certbot" "Certbot"

# Python3-certbot-nginx plugin
if ! dpkg -l python3-certbot-nginx &>/dev/null; then
    apt-get install -y -qq python3-certbot-nginx
fi

systemctl enable nginx --now 2>/dev/null || true

log "Alle Abhängigkeiten bereit"
echo ""

# ── 2. Domain abfragen ───────────────────────────────────────
while true; do
    read -rp "Domain (z.B. fonester.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        warn "Domain darf nicht leer sein."
        continue
    fi
    break
done

# ── 3. DNS A-Record prüfen ───────────────────────────────────
info "Prüfe DNS A-Record für $DOMAIN..."

SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')
DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)

if [[ -z "$DNS_IP" ]]; then
    warn "Kein DNS A-Record für $DOMAIN gefunden!"
    warn "Bitte richte einen A-Record ein: $DOMAIN → $SERVER_IP"
    read -rp "Enter drücken wenn der DNS-Eintrag gesetzt ist... "
    # Re-check
    DNS_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1 || true)
    if [[ -z "$DNS_IP" ]]; then
        err "DNS-Eintrag immer noch nicht auflösbar. Abbruch."
    fi
fi

if [[ "$DNS_IP" != "$SERVER_IP" ]]; then
    warn "DNS zeigt auf $DNS_IP, aber Server-IP ist $SERVER_IP"
    read -rp "Trotzdem fortfahren? (j/N): " cont
    [[ "$cont" != "j" && "$cont" != "J" ]] && err "Abbruch durch Benutzer."
else
    log "DNS OK: $DOMAIN → $DNS_IP"
fi
echo ""

# ── 4. Login-Daten abfragen ──────────────────────────────────
read -rp "Admin Email [admin@$DOMAIN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

while true; do
    read -rsp "Admin Passwort (min. 8 Zeichen): " ADMIN_PASSWORD
    echo ""
    if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
        warn "Passwort muss mindestens 8 Zeichen lang sein."
        continue
    fi
    read -rsp "Passwort wiederholen: " ADMIN_PASSWORD2
    echo ""
    if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD2" ]]; then
        warn "Passwörter stimmen nicht überein."
        continue
    fi
    break
done
echo ""

# ── 5. Repo klonen / aktualisieren ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/compose.yaml" ]]; then
    # Script läuft aus existierendem Repo
    FONESTER_DIR="$SCRIPT_DIR"
    log "Nutze existierendes Repository: $FONESTER_DIR"
else
    FONESTER_DIR="/opt/fonester"
    if [[ -d "$FONESTER_DIR/.git" ]]; then
        log "Repository existiert bereits, aktualisiere..."
        cd "$FONESTER_DIR"
        git pull
    else
        log "Klone Repository..."
        git clone https://github.com/livedialai/fonester.git "$FONESTER_DIR"
    fi
fi

cd "$FONESTER_DIR"

# ── 6. .env konfigurieren ────────────────────────────────────
log "Konfiguriere .env..."

# IP setzen (3 Stellen)
sed -i "s/SET_YOUR_IP/$SERVER_IP/g" .env

# Login-Daten setzen
sed -i "s/APISERVER_OWNER_EMAIL=.*/APISERVER_OWNER_EMAIL=$ADMIN_EMAIL/" .env
sed -i "s/APISERVER_OWNER_PASSWORD=.*/APISERVER_OWNER_PASSWORD=$ADMIN_PASSWORD/" .env

# Session Secret generieren falls nicht vorhanden
if ! grep -q "SERVER_DASHBOARD_SESSION_SECRET=" .env; then
    SESSION_SECRET=$(openssl rand -hex 32)
    echo "SERVER_DASHBOARD_SESSION_SECRET=$SESSION_SECRET" >> .env
    log "Session Secret generiert"
fi

log ".env konfiguriert"
echo ""

# ── 7. Compose-YAML Fixes ────────────────────────────────────
log "Wende Compose-Fixes an..."

# Fix 1: Entferne doppelte PORT_MAX/PORT_MIN/PUBLIC_IP in rtpengine-Sektion
# Prüfe ob bereits korrigiert
if grep -c "PUBLIC_IP:" compose.yaml | grep -q "^2$" 2>/dev/null || \
   [[ $(grep -c "PUBLIC_IP:" compose.yaml) -gt 1 ]]; then
    # Entferne die zweite Gruppe (Zeilen nach dem ersten PUBLIC_IP)
    python3 << 'PYFIX'
with open('compose.yaml', 'r') as f:
    lines = f.readlines()

seen_public_ip = False
new_lines = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith('PUBLIC_IP:') or stripped.startswith('PORT_MAX:') or stripped.startswith('PORT_MIN:'):
        if not seen_public_ip:
            new_lines.append(line)
        seen_public_ip = True
        continue
    new_lines.append(line)

with open('compose.yaml', 'w') as f:
    f.writelines(new_lines)
PYFIX
    log "Doppelte rtpengine-Env-Einträge entfernt"
fi

# Fix 2: DASHBOARD_ALLOW_INSECURE=true für SSR
if ! grep -q "DASHBOARD_ALLOW_INSECURE" compose.yaml; then
    python3 << 'PYFIX2'
with open('compose.yaml', 'r') as f:
    content = f.read()
content = content.replace(
    '      - SERVER_DASHBOARD_SESSION_SECRET\n\n  apiserver:',
    '      - SERVER_DASHBOARD_SESSION_SECRET\n      - DASHBOARD_ALLOW_INSECURE=true\n\n  apiserver:'
)
with open('compose.yaml', 'w') as f:
    f.write(content)
PYFIX2
    log "DASHBOARD_ALLOW_INSECURE=true hinzugefügt"
fi

# Compose-Validierung
if ! docker compose config -q 2>/dev/null; then
    err "compose.yaml ist ungültig!"
fi

log "Compose-Fixes angewendet"
echo ""

# ── 8. Envoy-Config Fix ──────────────────────────────────────
log "Wende Envoy-Config-Fix an..."

# Fix: gRPC-Web Content-Type Regex erweitern
if ! grep -q "grpc-web\[+\]proto" config/envoy.yaml; then
    python3 << 'PYENVOY'
with open('config/envoy.yaml', 'r') as f:
    content = f.read()

# Alte Regex ersetzen mit neuer die auch grpc-web+proto matcht
old = '^(application/grpc|application/grpc-web-text)$'
new = '^(application/grpc|application/grpc-web-text|application/grpc-web[+]proto)$'
content = content.replace(old, new)

with open('config/envoy.yaml', 'w') as f:
    f.write(content)
PYENVOY
    log "Envoy gRPC-Web Regex gefixt"
else
    log "Envoy-Config bereits gefixt"
fi
echo ""

# ── 9. Integrations-Datei vorbereiten ────────────────────────
log "Bereite Config-Dateien vor..."

# integrations.json: Docker erstellt ein Verzeichnis wenn die Datei nicht existiert
rm -rf config/integrations.json
cp config/integrations.example.json config/integrations.json

# assistant.json falls vorhanden
if [[ -f config/assistant.example.json ]] && [[ ! -f config/assistant.json ]]; then
    cp config/assistant.example.json config/assistant.json
fi

log "Config-Dateien bereit"
echo ""

# ── 10. SSL-Zertifikat ───────────────────────────────────────
info "Hole Let's Encrypt Zertifikat für $DOMAIN..."

# Nginx kurz stoppen für standalone-Mode
systemctl stop nginx 2>/dev/null || true
sleep 1

if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    log "Zertifikat existiert bereits"
else
    certbot certonly --standalone \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --email "$ADMIN_EMAIL" \
        --quiet 2>&1 || {
            systemctl start nginx
            err "SSL-Zertifikat konnte nicht erstellt werden. Prüfe den DNS-Eintrag."
        }
    log "SSL-Zertifikat erstellt"
fi

# ── 11. Nginx konfigurieren ──────────────────────────────────
log "Konfiguriere Nginx..."

# Domain in nginx-fonoster.conf einsetzen
sed -i "s/fonoster\.DEINE_DOMAIN\.de/$DOMAIN/g" nginx-fonoster.conf

# proxy_pass https → http (Envoy spricht plain HTTP)
sed -i 's|proxy_pass https://127.0.0.1:8449;|proxy_pass http://127.0.0.1:8449;|g' nginx-fonoster.conf

# Nginx-Site aktivieren
cp nginx-fonoster.conf /etc/nginx/sites-available/fonoster
ln -sf /etc/nginx/sites-available/fonoster /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl start nginx && systemctl reload nginx

log "Nginx konfiguriert"
echo ""

# ── 12. Keys generieren ──────────────────────────────────────
log "Generiere RSA-Keys..."

mkdir -p config/keys
if [[ ! -f config/keys/private.pem ]]; then
    openssl genpkey -algorithm RSA -out config/keys/private.pem 2>/dev/null
    openssl rsa -pubout -in config/keys/private.pem -out config/keys/public.pem 2>/dev/null
    log "RSA-Keys generiert"
else
    log "Keys existieren bereits"
fi
echo ""

# ── 13. Dashboard bauen ──────────────────────────────────────
info "Baue Dashboard-Image (kann einige Minuten dauern)..."

cd mods/dashboard
docker build \
    --build-arg DASHBOARD_ALLOW_INSECURE=true \
    -t fonoster/dashboard:0.17.1 \
    . 2>&1 | tail -3
cd "$FONESTER_DIR"

log "Dashboard gebaut"
echo ""

# ── 14. Images pullen & starten ──────────────────────────────
info "Pulle Docker-Images..."
docker compose pull 2>&1 | tail -3

info "Starte Fonester..."
docker compose up -d 2>&1

log "Warte auf Services..."
sleep 15

# ── 15. Healthcheck ──────────────────────────────────────────
info "Prüfe Services..."

FAILED=0
for svc in dashboard apiserver routr envoy postgres; do
    STATUS=$(docker inspect "fonester-${svc}-1" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    if [[ "$STATUS" == "running" ]]; then
        log "$svc: running"
    else
        warn "$svc: $STATUS"
        FAILED=1
    fi
done

if [[ $FAILED -eq 1 ]]; then
    warn "Einige Services sind nicht gestartet. Prüfe mit: docker compose logs"
else
    log "Alle Services laufen!"
fi
echo ""

# ── 16. Login-Test ───────────────────────────────────────────
info "Teste HTTPS-Login..."

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
    log "HTTPS-Endpoint erreichbar (HTTP $HTTP_CODE)"
else
    warn "HTTPS-Endpoint antwortet mit $HTTP_CODE. Warte noch einen Moment..."
    sleep 10
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN/" 2>/dev/null || echo "000")
    log "HTTPS-Endpoint: HTTP $HTTP_CODE"
fi

# ── 17. Fertig ────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║         Fonester Installation abgeschlossen!           ║"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  URL:      https://$DOMAIN"
echo "║  Email:    $ADMIN_EMAIL"
echo "║  Passwort: **** (dein gewähltes Passwort)"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  Nach dem ersten Login Passwort in den                 ║"
echo "║  Account-Settings ändern!                              ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
