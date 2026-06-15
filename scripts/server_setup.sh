#!/usr/bin/env bash
# FieldTrack — one-time VPS bootstrap.
#
# Run ONCE as root on a fresh Ubuntu 22.04 VPS:
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/scripts/server_setup.sh | bash
# or copy the file over and run:
#   sudo bash server_setup.sh
#
# After this script finishes, all further deploys happen via GitHub Actions
# (.github/workflows/deploy.yml) over SSH as the `deploy` user.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/your-org/fieldtrack.git}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

echo "==> Updating system packages"
apt-get update -y
apt-get upgrade -y

echo "==> Installing core packages"
apt-get install -y \
    docker.io \
    docker-compose-plugin \
    nginx \
    certbot \
    python3-certbot-nginx \
    git \
    curl \
    ufw \
    fail2ban

echo "==> Configuring firewall (UFW)"
# Deny everything inbound by default; allow outbound (updates, pulling images,
# calling FCM, etc). Only SSH/HTTP/HTTPS are reachable from the internet.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (redirects to HTTPS + ACME renewal)
ufw allow 443/tcp   # HTTPS
ufw --force enable

echo "==> Enabling Docker"
systemctl enable docker
systemctl start docker

echo "==> Creating deploy user (if missing) and adding to docker group"
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
# So the deploy user can run `systemctl restart` / reload nginx etc without a
# password prompt — GitHub Actions SSHes in as this user non-interactively.
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx, /usr/bin/systemctl restart nginx" \
    > /etc/sudoers.d/90-fieldtrack-deploy
chmod 440 /etc/sudoers.d/90-fieldtrack-deploy

echo "==> Creating FieldTrack directory layout"
mkdir -p /opt/fieldtrack
mkdir -p /opt/fieldtrack/backups
mkdir -p /var/www/fieldtrack
mkdir -p /var/log/fieldtrack
chown -R "$DEPLOY_USER":"$DEPLOY_USER" /opt/fieldtrack /var/www/fieldtrack /var/log/fieldtrack

echo "==> Cloning FieldTrack repo to /opt/fieldtrack/app"
if [ ! -d /opt/fieldtrack/app/.git ]; then
    sudo -u "$DEPLOY_USER" git clone "$REPO_URL" /opt/fieldtrack/app
else
    echo "    /opt/fieldtrack/app already exists — skipping clone"
fi

echo "==> Configuring fail2ban for SSH"
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port    = 22
filter  = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime  = 1h
findtime = 10m
EOF
systemctl enable fail2ban
systemctl restart fail2ban

echo ""
echo "================================================================"
echo " FieldTrack server setup complete."
echo "================================================================"
echo "Next steps:"
echo "  1. Copy .env.prod.example -> /opt/fieldtrack/app/.env.prod and fill"
echo "     in real secrets (as the '$DEPLOY_USER' user)."
echo "  2. Point your domain's DNS A record at this server's IP."
echo "  3. Run scripts/ssl_setup.sh <your-domain.com> to obtain SSL certs."
echo "  4. Add this server's SSH details + a deploy key to your GitHub repo"
echo "     secrets (see .github/workflows/deploy.yml for the full list)."
echo "  5. Push to main — GitHub Actions will build and deploy automatically."
echo "================================================================"
