#!/bin/bash
# FTPScanner LXC setup script
# Run as root on a fresh Debian/Ubuntu LXC container
set -e

SCANS_DIR="/srv/scans"
FTP_USER="scanner"
FTP_PASS="changeme"        # <-- change this before running
ONEDRIVE_REMOTE="onedrive" # rclone remote name (set up with: rclone config)
ONEDRIVE_FOLDER="Scans"    # destination folder on OneDrive

# ── 1. Packages ────────────────────────────────────────────────────────────────
echo "[1/6] Installing packages..."
apt-get update -qq
apt-get install -y -qq vsftpd python3 python3-pip python3-venv curl unzip

# ── 2. rclone ──────────────────────────────────────────────────────────────────
if ! command -v rclone &>/dev/null; then
  echo "[2/6] Installing rclone..."
  curl -fsSL https://rclone.org/install.sh | bash
else
  echo "[2/6] rclone already installed, skipping."
fi

# ── 3. FTP user & scans directory ─────────────────────────────────────────────
echo "[3/6] Creating FTP user and scans directory..."
useradd -m -s /usr/sbin/nologin "$FTP_USER" 2>/dev/null || true
echo "$FTP_USER:$FTP_PASS" | chpasswd
# vsftpd PAM checks /etc/shells — nologin must be listed or logins are rejected
grep -qxF '/usr/sbin/nologin' /etc/shells || echo '/usr/sbin/nologin' >> /etc/shells

mkdir -p "$SCANS_DIR"
chown "$FTP_USER":"$FTP_USER" "$SCANS_DIR"
chmod 755 "$SCANS_DIR"

# ── 4. vsftpd config ──────────────────────────────────────────────────────────
echo "[4/6] Configuring vsftpd..."
cp "$(dirname "$0")/config/vsftpd.conf" /etc/vsftpd.conf

# Ensure PAM allows local users
mkdir -p /var/run/vsftpd/empty

systemctl enable vsftpd
systemctl restart vsftpd

# ── 5. Web app ────────────────────────────────────────────────────────────────
echo "[5/6] Installing web server..."
mkdir -p /opt/ftpscanner
cp "$(dirname "$0")/app/server.py" /opt/ftpscanner/
cp -r "$(dirname "$0")/app/templates" /opt/ftpscanner/

python3 -m venv /opt/ftpscanner/venv
/opt/ftpscanner/venv/bin/pip install -q flask

cp "$(dirname "$0")/systemd/ftpscanner-web.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable ftpscanner-web
systemctl restart ftpscanner-web

# ── 6. OneDrive sync ──────────────────────────────────────────────────────────
echo "[6/6] Installing OneDrive sync timer..."

# Patch the service with the configured remote/folder
sed "s|onedrive:Scans|${ONEDRIVE_REMOTE}:${ONEDRIVE_FOLDER}|g" \
  "$(dirname "$0")/systemd/ftpscanner-sync.service" \
  > /etc/systemd/system/ftpscanner-sync.service

cp "$(dirname "$0")/systemd/ftpscanner-sync.timer" /etc/systemd/system/

systemctl daemon-reload
systemctl enable ftpscanner-sync.timer
# Timer starts after rclone is configured — enable manually when ready:
# systemctl start ftpscanner-sync.timer

# ── Done ──────────────────────────────────────────────────────────────────────
LXC_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " FTP  : $LXC_IP:21  (user: $FTP_USER / $FTP_PASS)"
echo " Web  : http://$LXC_IP:8080"
echo " Scans: $SCANS_DIR"
echo ""
echo " OneDrive sync is DISABLED until you configure rclone:"
echo "   1. rclone config  (create a remote named '${ONEDRIVE_REMOTE}')"
echo "   2. systemctl start ftpscanner-sync.timer"
echo ""
echo " Firewall ports to open on Proxmox:"
echo "   TCP 21, TCP 8080, TCP 10090-10100 (FTP passive)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
