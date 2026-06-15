#!/usr/bin/env bash
# FieldTrack — obtain (or renew) a Let's Encrypt certificate for the domain
# Nginx serves the admin SPA + API on.
#
# Usage:
#   sudo bash ssl_setup.sh your-domain.com
#
# Run this AFTER scripts/server_setup.sh and AFTER DNS for the domain points
# at this server (Let's Encrypt validates ownership over the internet).

set -euo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain>" >&2
    echo "Example: $0 fieldtrack.example.com" >&2
    exit 1
fi

EMAIL="admin@${DOMAIN}"
COMPOSE_FILE="/opt/fieldtrack/app/docker-compose.prod.yml"

echo "==> Stopping Nginx so certbot can bind port 80 (--standalone)"
# certbot --standalone runs its own tiny webserver on port 80 to answer the
# ACME challenge, so anything else on port 80 must be down first. The Nginx
# *container* is what's actually listening, so stop that — not the host's
# systemd nginx (which server_setup.sh installed but which Compose's Nginx
# container shadows on 80/443).
docker compose -f "$COMPOSE_FILE" stop nginx || systemctl stop nginx || true

echo "==> Requesting certificate for $DOMAIN and www.$DOMAIN"
certbot certonly --standalone \
    -d "$DOMAIN" -d "www.$DOMAIN" \
    --non-interactive --agree-tos \
    --email "$EMAIL"

echo "==> Restarting Nginx"
docker compose -f "$COMPOSE_FILE" start nginx || systemctl start nginx || true

echo "==> Setting up auto-renewal (daily check via cron, 3am)"
# certbot only actually renews when the cert is within 30 days of expiry, so
# a daily check is cheap and standard. We stop the Nginx container before
# renewing (same port-80 reason as above) and start it again afterwards,
# reloading so the new cert is picked up without a full restart.
CRON_CMD="0 3 * * * docker compose -f $COMPOSE_FILE stop nginx && certbot renew --quiet && docker compose -f $COMPOSE_FILE start nginx && docker exec fieldtrack-nginx nginx -s reload"
( crontab -l 2>/dev/null | grep -vF "certbot renew" ; echo "$CRON_CMD" ) | crontab -

echo "==> Verifying renewal works (dry run)"
certbot renew --dry-run

echo ""
echo "================================================================"
echo " SSL setup complete for $DOMAIN"
echo "================================================================"
certbot certificates -d "$DOMAIN" | grep -E "Expiry Date|Certificate Path" || true
echo ""
echo "Next: edit nginx/nginx.prod.conf and replace every 'your-domain.com'"
echo "with '$DOMAIN', then restart the nginx container:"
echo "  docker compose -f $COMPOSE_FILE up -d nginx"
echo ""
echo "Test your config with SSL Labs once it's live:"
echo "  https://www.ssllabs.com/ssltest/analyze.html?d=$DOMAIN"
echo "================================================================"
