#!/usr/bin/env bash
# Install Palworld WireGuard MONITOR on Steam Deck.
# Run in Desktop Mode Konsole as user "deck":
#   bash install.sh
#
# A background service checks every 60s whether Palworld is running:
#   running  -> wg-quick up wg0
#   not running -> wg-quick down wg0
#
# No Steam Launch Options needed. Clear them if you set any earlier.
set -euo pipefail

if [[ "$(id -un)" != "deck" ]]; then
  echo "ERROR: run this as user 'deck' (Steam Deck Desktop Konsole)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/home/deck/.local/state/palworld-wg"
LIB_DIR="/home/deck/.local/lib/palworld-wg"
UNIT_DIR="/etc/systemd/system"
MONITOR_SRC="${SCRIPT_DIR}/systemd/palworld-wg-monitor.sh"
MONITOR_DST="${LIB_DIR}/palworld-wg-monitor.sh"
SERVICE_SRC="${SCRIPT_DIR}/systemd/palworld-wg-monitor.service"
SERVICE_DST="${UNIT_DIR}/palworld-wg-monitor.service"

need=(
  "$MONITOR_SRC"
  "$SERVICE_SRC"
)

for f in "${need[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing file: $f"
    echo "Keep the whole Palworld Script folder together."
    exit 1
  fi
done

find_peer_conf() {
  local f newest="" newest_m=0 m
  if [[ -n "${WG_PEER_CONF:-}" && -f "${WG_PEER_CONF}" ]]; then
    printf '%s\n' "${WG_PEER_CONF}"
    return 0
  fi
  for f in \
    "${SCRIPT_DIR}/wg0.conf" \
    "${HOME}/Downloads/wg0.conf" \
    "${HOME}/Desktop/wg0.conf" \
    "${HOME}/wg0.conf"
  do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$f"
    return 0
  done
  while IFS= read -r -d '' f; do
    [[ "$(basename "$f")" == "palworld-wg.conf" ]] && continue
    grep -q '^\[Interface\]' "$f" 2>/dev/null || continue
    printf '%s\n' "$f"
    return 0
  done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)

  while IFS= read -r -d '' f; do
    grep -q '^\[Interface\]' "$f" 2>/dev/null || continue
    m=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    if (( m > newest_m )); then
      newest_m=$m
      newest=$f
    fi
  done < <(find "${HOME}/Downloads" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.wg' \) -print0 2>/dev/null)

  if [[ -n "$newest" ]]; then
    printf '%s\n' "$newest"
    return 0
  fi
  return 1
}

echo "==> Installing Palworld WireGuard MONITOR (overwrite mode)"
echo "    source: ${SCRIPT_DIR}"
echo "    interval: 60 seconds (negligible CPU)"

mkdir -p "$STATE_DIR" "$LIB_DIR"

PEER_SRC=""
if PEER_SRC="$(find_peer_conf)"; then
  echo "==> Found WireGuard peer config: ${PEER_SRC}"
else
  PEER_SRC=""
fi

if [[ ! -x /usr/bin/wg-quick ]]; then
  echo "WARNING: /usr/bin/wg-quick not found. Install wireguard-tools."
fi

echo "==> Installing system files (sudo password once)"
sudo steamos-readonly disable || true

sudo mkdir -p "$LIB_DIR" "$UNIT_DIR" /etc/wireguard

if [[ -n "$PEER_SRC" ]]; then
  echo "==> Installing /etc/wireguard/wg0.conf (overwrite)"
  sudo install -m 600 -o root -g root -T "$PEER_SRC" /etc/wireguard/wg0.conf
elif sudo test -f /etc/wireguard/wg0.conf; then
  echo "==> Keeping existing /etc/wireguard/wg0.conf"
else
  echo "ERROR: No WireGuard peer config found."
  echo "Put peer .conf in ~/Downloads (or set WG_PEER_CONF=...) and re-run."
  sudo steamos-readonly enable || true
  exit 1
fi

echo "==> Installing monitor script + service"
sudo install -m 755 -o root -g root -T "$MONITOR_SRC" "$MONITOR_DST"
sudo install -m 644 -o root -g root -T "$SERVICE_SRC" "$SERVICE_DST"

# Disable legacy path-unit helpers if previously installed (Launch Options era)
sudo systemctl disable --now palworld-wg-up.path palworld-wg-down.path 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable --now palworld-wg-monitor.service

sudo steamos-readonly enable || true

echo "==> Service status:"
systemctl --no-pager --full status palworld-wg-monitor.service | head -20 || true

echo
echo "=============================================="
echo " Install OK — monitor running"
echo "=============================================="
echo
echo "IMPORTANT: Clear Palworld Launch Options in Steam"
echo "  (leave the field EMPTY — no wrapper script)."
echo
echo "How it works:"
echo "  Every 60s: Palworld running -> wg0 up; otherwise -> wg0 down"
echo "  Starts automatically at boot."
echo
echo "Manual checks:"
echo "  systemctl status palworld-wg-monitor.service"
echo "  cat /home/deck/.local/state/palworld-wg/monitor-status"
echo "  tail -30 /home/deck/.local/state/palworld-wg/monitor.log"
echo "  sudo wg show"
echo
echo "Then just press Play on Palworld (Desktop or Game Mode)."
echo "Within ~1 minute WireGuard should come up; within ~1 minute"
echo "after quit it should go down."
echo
