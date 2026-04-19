#!/usr/bin/env bash
# Coriolis user script: $1 = root disk path. Prepares the migrated disk so the
# finalized VM enrolls with MLM on first boot (not the minion).
set -euo pipefail

# ceva
root_disk="${1:?Usage: $0 <root_disk_path>}"
mlm_ip="10.100.0.39"
mlm_host="mlm.local.testing"

# OS -> activation key map (format: "<os_id>:<version_or_major>" => "<activation_key>")
# Match order in mlm-register.sh: ID:VERSION_ID, ID:MAJOR, then each ID_LIKE token with the same.
# Examples of os_id from /etc/os-release: rocky, rhel, sles, almalinux, centos, opensuse-leap
declare -A os_activation_key_map=(
  ["rocky:9"]="1-demo-rocky9"
  ["rhel:9"]="1-demo-rhel9"
  ["rhel:8"]="1-demo-rhel8"
  ["almalinux:9"]="1-demo-rhel9"
  ["centos:9"]="1-demo-rhel9"
  ["sles:15"]="1-demo-sles15"
)

# Optional: DNS that can resolve updates.suse.com (VM often has no internet DNS).
# Set to a nameserver IP (e.g. 8.8.8.8 or your gateway) or leave empty.
fallback_nameserver="8.8.8.8"

mkdir -p "$root_disk/usr/local/sbin"
# Single source of truth for the guest: bash can `source` this file to recreate the map.
declare -p os_activation_key_map >"$root_disk/usr/local/sbin/mlm-os-key-map.inc"
chmod 600 "$root_disk/usr/local/sbin/mlm-os-key-map.inc"

mkdir -p "$root_disk/etc/systemd/system"
mkdir -p "$root_disk/etc/systemd/system/multi-user.target.wants"
mkdir -p "$root_disk/etc/systemd/system/default.target.wants"

# First-boot script: no set -e so we always log; writes to /tmp first (writable early).
# Debug on VM: journalctl -u mlm-register.service; cat /var/log/mlm-register.log /tmp/mlm-register.log
cat > "$root_disk/usr/local/sbin/mlm-register.sh" <<'INNER'
#!/usr/bin/env bash
LOG=/var/log/mlm-register.log
TMPLOG=/tmp/mlm-register.log
TMP_BOOTSTRAP=/tmp/bootstrap.sh

log() { echo "$(date -Iseconds) $*" >> "$TMPLOG"; echo "$(date -Iseconds) $*" >> "$LOG" 2>/dev/null || true; }
cleanup_bootstrap() { rm -f "$TMP_BOOTSTRAP" 2>/dev/null || true; }

trap cleanup_bootstrap EXIT

# Prove the service ran (even if script fails immediately)
touch /tmp/mlm-register.started 2>/dev/null || true
log "mlm-register: service started"

# Safety: some migrations create ifcfg profiles with NM_CONTROLLED=no, which
# makes NetworkManager treat NICs as "unmanaged". Fix that and restart NM.
ifcfg_dir="/etc/sysconfig/network-scripts"
nm_controlled_changed=0
if [[ -d "$ifcfg_dir" ]]; then
  shopt -s nullglob
  for f in "$ifcfg_dir"/ifcfg-*; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*NM_CONTROLLED[[:space:]]*=[[:space:]]*no[[:space:]]*$' "$f"; then
      log "mlm-register: fixing NM_CONTROLLED=no in $f"
      sed -i.bak 's/^[[:space:]]*NM_CONTROLLED[[:space:]]*=[[:space:]]*no[[:space:]]*$/NM_CONTROLLED=yes/' "$f" >>"$TMPLOG" 2>&1 || true
      nm_controlled_changed=1
    elif ! grep -qE '^[[:space:]]*NM_CONTROLLED[[:space:]]*=' "$f"; then
      log "mlm-register: adding NM_CONTROLLED=yes to $f"
      echo "NM_CONTROLLED=yes" >> "$f" 2>>"$TMPLOG" || true
      nm_controlled_changed=1
    fi
  done
  shopt -u nullglob
fi

if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'NetworkManager.service'; then
  if [[ "$nm_controlled_changed" -eq 1 ]]; then
    log "mlm-register: restarting NetworkManager.service (NM_CONTROLLED fixed)"
  else
    log "mlm-register: restarting NetworkManager.service"
  fi
  systemctl restart NetworkManager.service >>"$TMPLOG" 2>&1 || log "mlm-register: NetworkManager restart failed (ignored)"
  systemctl is-active NetworkManager.service >>"$TMPLOG" 2>&1 || true
  nmcli device status >>"$TMPLOG" 2>&1 || true
fi

mlm_ip="MLM_IP_PLACEHOLDER"
mlm_host="MLM_HOST_PLACEHOLDER"
fallback_nameserver="FALLBACK_NAMESERVER_PLACEHOLDER"
MAX_ATTEMPTS=5
RETRY_SLEEP=60

if [[ -f /usr/local/sbin/mlm-os-key-map.inc ]]; then
  # shellcheck disable=SC1091
  source /usr/local/sbin/mlm-os-key-map.inc
else
  log "mlm-register: missing /usr/local/sbin/mlm-os-key-map.inc (Coriolis user-script did not install map), aborting"
  exit 1
fi

detect_activation_key() {
  local os_id=""
  local version_id=""
  local major=""
  local candidate=""
  local like=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
  fi

  os_id="${os_id,,}"
  major="${version_id%%.*}"

  for candidate in "$os_id:$version_id" "$os_id:$major"; do
    if [[ -n "${os_activation_key_map[$candidate]+x}" ]]; then
      echo "${os_activation_key_map[$candidate]}"
      return 0
    fi
  done

  # Fallback: try ID_LIKE tokens (e.g. ID=centos ID_LIKE="rhel fedora")
  if [[ -n "${ID_LIKE:-}" ]]; then
    for like in $ID_LIKE; do
      like="${like,,}"
      for candidate in "$like:$version_id" "$like:$major"; do
        if [[ -n "${os_activation_key_map[$candidate]+x}" ]]; then
          echo "${os_activation_key_map[$candidate]}"
          return 0
        fi
      done
    done
  fi

  echo ""
}

activation_key="$(detect_activation_key)"
# detect_activation_key runs under command substitution (subshell), so re-source for logging.
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
fi
if [[ -z "$activation_key" ]]; then
  log "mlm-register: no activation key mapping for detected OS (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown}, ID_LIKE=${ID_LIKE:-}), aborting"
  exit 1
fi
log "mlm-register: selected activation_key=${activation_key} for OS (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown}, ID_LIKE=${ID_LIKE:-})"

# Ensure MLM is in hosts
grep -qF "$mlm_host" /etc/hosts 2>/dev/null || echo "$mlm_ip $mlm_host" >> /etc/hosts

# Bootstrap needs to resolve updates.suse.com (zypper fetches salt from SUSE CDN).
# If VM DNS does not resolve it, add a fallback nameserver.
if [[ -n "$fallback_nameserver" ]]; then
  if ! grep -qF "nameserver $fallback_nameserver" /etc/resolv.conf 2>/dev/null; then
    echo "nameserver $fallback_nameserver" >> /etc/resolv.conf
    log "mlm-register: added fallback nameserver $fallback_nameserver for updates.suse.com"
  fi
fi

log "mlm-register: up to $MAX_ATTEMPTS attempts"

attempt=1
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  log "mlm-register: attempt $attempt/$MAX_ATTEMPTS"

  # Remove any stale bootstrap from previous try
  cleanup_bootstrap

  # Wait for network (retry up to 2 min)
  for i in $(seq 1 24); do
    if curl -kfsS --connect-timeout 5 -o /dev/null "https://$mlm_host/pub/" 2>/dev/null; then
      log "mlm-register: network OK"
      break
    fi
    if [[ $i -eq 24 ]]; then
      log "mlm-register: network unreachable this attempt"
      attempt=$((attempt + 1))
      [[ $attempt -le $MAX_ATTEMPTS ]] && sleep $RETRY_SLEEP
      continue 2
    fi
    sleep 5
  done

  if ! curl -kfsSL -o "$TMP_BOOTSTRAP" "https://$mlm_host/pub/bootstrap/bootstrap.sh" 2>>"$TMPLOG"; then
    log "mlm-register: failed to download bootstrap"
    cleanup_bootstrap
    attempt=$((attempt + 1))
    [[ $attempt -le $MAX_ATTEMPTS ]] && sleep $RETRY_SLEEP
    continue
  fi
  chmod +x "$TMP_BOOTSTRAP"

  if MGR_SERVER_HOSTNAME="$mlm_host" ACTIVATION_KEYS="$activation_key" "$TMP_BOOTSTRAP" >> "$TMPLOG" 2>&1; then
    log "mlm-register: enrollment succeeded, removing one-shot"
    cleanup_bootstrap
    systemctl disable mlm-register.service 2>/dev/null || true
    rm -f /etc/systemd/system/mlm-register.service /usr/local/sbin/mlm-register.sh /usr/local/sbin/mlm-os-key-map.inc
    exit 0
  fi

  cleanup_bootstrap
  log "mlm-register: attempt $attempt bootstrap failed, retrying in ${RETRY_SLEEP}s"
  attempt=$((attempt + 1))
  [[ $attempt -le $MAX_ATTEMPTS ]] && sleep $RETRY_SLEEP
done

log "mlm-register: all $MAX_ATTEMPTS attempts failed, will retry on next boot"
exit 1
INNER

sed -i "s/MLM_IP_PLACEHOLDER/$mlm_ip/g; s/MLM_HOST_PLACEHOLDER/$mlm_host/g; s/FALLBACK_NAMESERVER_PLACEHOLDER/$fallback_nameserver/g" "$root_disk/usr/local/sbin/mlm-register.sh"
chmod +x "$root_disk/usr/local/sbin/mlm-register.sh"

# Run after network is up; also start after network.target if network-online never fires
cat > "$root_disk/etc/systemd/system/mlm-register.service" <<'SVC'
[Unit]
Description=Register system to SUSE Manager (MLM) on first boot
After=network-online.target network.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mlm-register.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

ln -sf ../mlm-register.service "$root_disk/etc/systemd/system/multi-user.target.wants/mlm-register.service"
ln -sf ../mlm-register.service "$root_disk/etc/systemd/system/default.target.wants/mlm-register.service"

# --- NetworkManager / ifcfg safety fixes (Rocky/RHEL family) ---
ifcfg_dir="$root_disk/etc/sysconfig/network-scripts"
if [[ -d "$ifcfg_dir" ]]; then
  for f in "$ifcfg_dir"/ifcfg-*; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*NM_CONTROLLED[[:space:]]*=[[:space:]]*no[[:space:]]*$' "$f"; then
      sed -i.bak 's/^[[:space:]]*NM_CONTROLLED[[:space:]]*=[[:space:]]*no[[:space:]]*$/NM_CONTROLLED=yes/' "$f" || true
    elif ! grep -qE '^[[:space:]]*NM_CONTROLLED[[:space:]]*=' "$f"; then
      echo "NM_CONTROLLED=yes" >> "$f"
    fi
  done
fi

# Additionally, drop a NetworkManager override to ensure eth0 is managed even if
# some vendor/template config marks it unmanaged.
mkdir -p "$root_disk/etc/NetworkManager/conf.d"
cat > "$root_disk/etc/NetworkManager/conf.d/10-coriolis-managed-eth0.conf" <<'NMCONF'
[keyfile]
unmanaged-devices=

[device]
match-device=interface-name:eth0
managed=true
NMCONF
