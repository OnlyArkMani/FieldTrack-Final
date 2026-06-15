#!/usr/bin/env bash
# FieldTrack — build the admin-web SPA and deploy it to the VPS.
#
# Usage:
#   ./scripts/build_admin.sh [user@host]
#
# If a host is given, the built `dist/` is rsynced to
# /opt/fieldtrack/app/admin-web/dist on the VPS and Nginx is reloaded so it
# picks up the new files (nginx.prod.conf serves them from there).
# If no host is given, this just builds `dist/` locally for inspection.

set -euo pipefail

cd "$(dirname "$0")/../admin-web"

echo "==> Checking for production env file"
if [ ! -f .env.prod ]; then
    echo "ERROR: admin-web/.env.prod not found." >&2
    echo "Copy .env.prod.example -> .env.prod and fill in your real values." >&2
    exit 1
fi
cp .env.prod .env.production
echo "    copied .env.prod -> .env.production"

echo "==> Installing dependencies (clean install)"
npm ci

echo "==> Building production bundle"
npm run build

echo "==> Build complete: admin-web/dist/ ($(du -sh dist | cut -f1))"

VPS_TARGET="${1:-}"
if [ -z "$VPS_TARGET" ]; then
    echo ""
    echo "No deploy target given — dist/ left in place for manual inspection."
    echo "To deploy: ./scripts/build_admin.sh deploy@your-vps"
    exit 0
fi

echo "==> Syncing dist/ to $VPS_TARGET:/opt/fieldtrack/app/admin-web/dist"
rsync -avz --delete dist/ "${VPS_TARGET}:/opt/fieldtrack/app/admin-web/dist/"

echo "==> Reloading Nginx on the VPS"
ssh "$VPS_TARGET" "docker exec fieldtrack-nginx nginx -s reload"

echo "==> Done."

# ─────────────────────────────────────────────────────────────────────────
# GitHub Actions alternative (run this from a workflow instead of by hand):
#
#   - name: Build admin web
#     run: |
#       cd admin-web
#       cp .env.prod .env.production
#       npm ci
#       npm run build
#
#   - name: Deploy admin web
#     uses: burnett01/rsync-deployments@7.0.1
#     with:
#       switches: -avz --delete
#       path: admin-web/dist/
#       remote_path: /opt/fieldtrack/app/admin-web/dist/
#       remote_host: ${{ secrets.VPS_HOST }}
#       remote_user: ${{ secrets.VPS_USER }}
#       remote_key: ${{ secrets.VPS_SSH_KEY }}
#
#   - name: Reload Nginx
#     uses: appleboy/ssh-action@v1.0.3
#     with:
#       host: ${{ secrets.VPS_HOST }}
#       username: ${{ secrets.VPS_USER }}
#       key: ${{ secrets.VPS_SSH_KEY }}
#       script: docker exec fieldtrack-nginx nginx -s reload
# ─────────────────────────────────────────────────────────────────────────
