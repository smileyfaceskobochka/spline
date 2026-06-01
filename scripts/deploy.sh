#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. sudo ./scripts/deploy.sh)"
  exit 1
fi

cd "$(dirname "$0")/.."

echo "Building production executables..."
zig build -Doptimize=ReleaseSafe

echo "Creating spline user/group if they do not exist..."
getent group spline >/dev/null || groupadd -r spline
getent passwd spline >/dev/null || useradd -r -g spline -d /var/lib/spline -s /sbin/nologin -c "Spline Daemon User" spline

echo "Creating deployment directories..."
mkdir -p /etc/spline
mkdir -p /var/lib/spline
chown spline:spline /var/lib/spline
chmod 755 /var/lib/spline

echo "Installing configuration..."
if [ -f .env ]; then
    cp .env /etc/spline/spline.env
    chmod 600 /etc/spline/spline.env
    chown root:root /etc/spline/spline.env
    echo "✔ Copied .env to /etc/spline/spline.env"
else
    echo "⚠ Warning: .env not found in project root. Service will fail to start without it."
fi

echo "Installing executables..."
install -m 755 zig-out/bin/spline /usr/local/bin/spline
install -m 755 zig-out/bin/lyfta-spline /usr/local/bin/lyfta-spline

echo "Installing systemd service..."
cp spline-core.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable spline-core.service

echo "Starting service..."
systemctl restart spline-core.service

echo "=========================================================="
echo "Deployment Complete!"
echo "Database location: /var/lib/spline/spline.db"
echo "Config location:   /etc/spline/spline.env"
echo "Check daemon logs: journalctl -fu spline-core"
echo "=========================================================="
