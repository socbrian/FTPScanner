#!/bin/bash
# Run this on the Proxmox HOST to create and configure the FTPScanner LXC.
# Usage: bash proxmox-install.sh
set -e

# ── Configuration ──────────────────────────────────────────────────────────────
VMID="${VMID:-200}"                        # LXC container ID
HOSTNAME="${HOSTNAME:-ftpscanner}"
MEMORY="${MEMORY:-512}"                    # MB
CORES="${CORES:-1}"
DISK="${DISK:-8}"                          # GB
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"                           # e.g. 192.168.1.50/24
GATEWAY="${GATEWAY:-}"                     # required if IP is static
DNS="${DNS:-1.1.1.1}"

FTP_PASS="${FTP_PASS:-changeme}"           # FTP user password — change this!
ONEDRIVE_FOLDER="${ONEDRIVE_FOLDER:-Scans}"

GITHUB_REPO="https://github.com/socbrian/FTPScanner"
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# Must run on Proxmox host
command -v pct &>/dev/null || error "pct not found — run this on the Proxmox host."

# ── 0. Pick storage ────────────────────────────────────────────────────────────
pick_storage() {
  local label="$1" var="$2" filter="$3"
  local -a options

  # Collect matching storage names from pvesm
  while IFS= read -r line; do
    local name type
    name=$(echo "$line" | awk '{print $1}')
    type=$(echo "$line" | awk '{print $2}')
    # filter: "content" checks what's in the Content column via pvesm status
    if [[ -z "$filter" ]] || pvesm status --storage "$name" 2>/dev/null | grep -q "$filter"; then
      options+=("$name ($type)")
    fi
  done < <(pvesm status 2>/dev/null | tail -n +2)

  [[ ${#options[@]} -eq 0 ]] && error "No suitable storage found for $label."

  echo ""
  echo -e "${YELLOW}Select storage for ${label}:${NC}"
  for i in "${!options[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${options[$i]}"
  done

  local choice
  while true; do
    read -rp "  Choice [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      # Extract just the storage name (before the space)
      printf -v "$var" '%s' "$(echo "${options[$((choice-1))]}" | awk '{print $1}')"
      break
    fi
    echo "  Invalid choice, try again."
  done
}

# Only prompt if not already set via env vars
if [[ -z "${STORAGE:-}" ]]; then
  pick_storage "container rootfs" STORAGE
fi
if [[ -z "${TEMPLATE_STORAGE:-}" ]]; then
  pick_storage "CT templates" TEMPLATE_STORAGE
fi

info "Rootfs storage : $STORAGE"
info "Template storage: $TEMPLATE_STORAGE"

# ── 1. Download Debian 12 template if needed ───────────────────────────────────
info "Checking for Debian 12 template..."
TEMPLATE=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-12-standard/{print $1; exit}')

if [[ -z "$TEMPLATE" ]]; then
  info "Downloading Debian 12 template..."
  pveam update
  REMOTE_TMPL=$(pveam available --section system | awk '/debian-12-standard/{print $2; exit}')
  [[ -z "$REMOTE_TMPL" ]] && error "Could not find debian-12-standard template."
  pveam download "$TEMPLATE_STORAGE" "$REMOTE_TMPL"
  TEMPLATE="$TEMPLATE_STORAGE:vztmpl/$REMOTE_TMPL"
else
  info "Template found: $TEMPLATE"
fi

# ── 2. Create the container ────────────────────────────────────────────────────
if pct status "$VMID" &>/dev/null; then
  warn "Container $VMID already exists. Skipping creation."
else
  info "Creating LXC container $VMID ($HOSTNAME)..."

  NET_OPTS="name=eth0,bridge=${BRIDGE}"
  if [[ "$IP" == "dhcp" ]]; then
    NET_OPTS+=",ip=dhcp"
  else
    NET_OPTS+=",ip=${IP}"
    [[ -n "$GATEWAY" ]] && NET_OPTS+=",gw=${GATEWAY}"
  fi

  pct create "$VMID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NET_OPTS" \
    --nameserver "$DNS" \
    --features nesting=0 \
    --unprivileged 1 \
    --start 0
fi

# ── 3. Start container ─────────────────────────────────────────────────────────
info "Starting container..."
pct start "$VMID"
sleep 5   # wait for network to come up

# ── 4. Bootstrap inside the container ─────────────────────────────────────────
info "Running setup inside container..."
pct exec "$VMID" -- bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq
  apt-get install -y -qq git curl

  rm -rf /root/FTPScanner
  git clone --depth=1 '${GITHUB_REPO}' /root/FTPScanner

  export FTP_PASS='${FTP_PASS}'
  export ONEDRIVE_FOLDER='${ONEDRIVE_FOLDER}'
  bash /root/FTPScanner/setup.sh
"

# ── 5. Report ──────────────────────────────────────────────────────────────────
LXC_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Container $VMID ready!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo " FTP  : ${LXC_IP}:21  (user: scanner / ${FTP_PASS})"
echo " Web  : http://${LXC_IP}:8080"
echo ""
echo " Next steps:"
echo "   1. Open Proxmox firewall: TCP 21, 8080, 10090-10100"
echo "   2. Configure OneDrive inside the container:"
echo "      pct exec $VMID -- rclone config"
echo "   3. Start sync timer:"
echo "      pct exec $VMID -- systemctl start ftpscanner-sync.timer"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
