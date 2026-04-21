# FTPScanner

A self-contained Proxmox LXC container that receives scanned documents from a network printer via FTP, serves them through a clean web UI, and automatically syncs them to OneDrive.

## Features

- **FTP server** (vsftpd) — accepts uploads from any network printer or scanner
- **Web UI** — browse all scans sorted newest first, with a one-click "Download Latest" button
- **OneDrive sync** — automatically copies scans to a OneDrive folder every 2 minutes via rclone

## Requirements

- Proxmox VE host
- Internet access from the LXC container (for rclone + package installs)
- A Microsoft account with OneDrive

---

## Quick Deploy

Run this on your **Proxmox host shell**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/socbrian/FTPScanner/master/proxmox-install.sh)
```

The script will:
1. Prompt you to select storage for the container rootfs and CT templates
2. Download the Debian 12 LXC template if not already present
3. Create and start the container
4. Install and configure all services automatically
5. Print the FTP and web UI addresses when done

### Custom options

You can override defaults with environment variables:

```bash
VMID=201 IP=192.168.1.50/24 GATEWAY=192.168.1.1 FTP_PASS=mysecretpass \
  bash <(curl -fsSL https://raw.githubusercontent.com/socbrian/FTPScanner/master/proxmox-install.sh)
```

| Variable | Default | Description |
|---|---|---|
| `VMID` | `200` | LXC container ID |
| `HOSTNAME` | `ftpscanner` | Container hostname |
| `MEMORY` | `512` | RAM in MB |
| `CORES` | `1` | vCPU count |
| `DISK` | `8` | Disk size in GB |
| `BRIDGE` | `vmbr0` | Network bridge |
| `IP` | `dhcp` | IP address (e.g. `192.168.1.50/24`) |
| `GATEWAY` | _(none)_ | Gateway (required for static IP) |
| `FTP_PASS` | `changeme` | FTP user password |
| `ONEDRIVE_FOLDER` | `Scans` | Destination folder on OneDrive |

---

## Firewall Ports

Open these on Proxmox for the container:

| Port | Protocol | Purpose |
|---|---|---|
| 21 | TCP | FTP control |
| 8080 | TCP | Web UI |
| 10090–10100 | TCP | FTP passive mode |

---

## Post-Install: OneDrive Setup

OneDrive requires a one-time OAuth setup. The recommended approach uses a custom Azure app registration to avoid browser dependencies on the server.

### 1. Register an Azure App

1. Go to [portal.azure.com](https://portal.azure.com) → **Microsoft Entra ID** → **App registrations** → **New registration**
2. Name it (e.g. `rclone`), click **Register**
3. Copy the **Application (client) ID**
4. Go to **Authentication** → **Add a platform** → **Mobile and desktop applications**
   - Tick `https://login.microsoftonline.com/common/oauth2/nativeclient`
   - Enable **Allow public client flows** → Yes → Save
5. Go to **Supported accounts** → set to **Any Entra ID Tenant + Personal Microsoft accounts** → Save
6. Go to **Manifest** → set `"requestedAccessTokenVersion": 2` → Save

### 2. Authenticate

Run this from a machine with a browser (e.g. Windows PowerShell — no install needed):

```powershell
$tmp = "$env:TEMP\rclone_auth"
Invoke-WebRequest https://downloads.rclone.org/rclone-current-windows-amd64.zip -OutFile "$tmp.zip"
Expand-Archive "$tmp.zip" -DestinationPath $tmp -Force
$exe = (Get-ChildItem "$tmp\rclone-*\rclone.exe")[0].FullName
& $exe authorize "onedrive" "YOUR_CLIENT_ID" ""
```

Follow the browser prompt, then paste the resulting token into `rclone config` inside the container.

### 3. Start sync

```bash
pct exec <VMID> -- systemctl start ftpscanner-sync.timer
```

---

## Project Structure

```
FTPScanner/
├── proxmox-install.sh        # Run on Proxmox host — creates and configures the LXC
├── setup.sh                  # Run inside the LXC — installs all services
├── config/
│   └── vsftpd.conf           # FTP server configuration
├── app/
│   ├── server.py             # Flask web server
│   ├── requirements.txt
│   └── templates/
│       └── index.html        # Web UI template
└── systemd/
    ├── ftpscanner-web.service
    ├── ftpscanner-sync.service
    └── ftpscanner-sync.timer
```

## Services Inside the Container

| Service | Description |
|---|---|
| `vsftpd` | FTP server, listens on port 21 |
| `ftpscanner-web` | Flask web UI on port 8080 |
| `ftpscanner-sync.timer` | Triggers OneDrive sync every 2 minutes |

Scans are stored at `/srv/scans/` inside the container.

---

> *This project was created with AI assistance using [Claude](https://claude.ai/claude-code) by Anthropic.*
