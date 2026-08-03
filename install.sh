#!/usr/bin/env bash
# One-shot installer for Palworld WireGuard launch helper on Steam Deck.
# Run in Desktop Mode Konsole as user "deck":
#   bash install.sh
#
# Creates missing directories and always overwrites previous helper files.
# Uses systemd path units (touch a file) so Steam Play works without sudo/polkit.
set -euo pipefail

if [[ "$(id -un)" != "deck" ]]; then
  echo "ERROR: run this as user 'deck' (Steam Deck Desktop Konsole)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/home/deck/bin"
CONF_DIR="/home/deck/.config"
STATE_DIR="/home/deck/.local/state/palworld-wg"
LIB_DIR="/home/deck/.local/lib/palworld-wg"
CONF_DST="${CONF_DIR}/palworld-wg.conf"
UNIT_DIR="/etc/systemd/system"

need=(
  "${SCRIPT_DIR}/palworld-wg.sh"
  "${SCRIPT_DIR}/palworld-wg-ctl"
  "${SCRIPT_DIR}/palworld-wg.conf"
  "${SCRIPT_DIR}/systemd/palworld-wg-up.path"
  "${SCRIPT_DIR}/systemd/palworld-wg-up.service"
  "${SCRIPT_DIR}/systemd/palworld-wg-down.path"
  "${SCRIPT_DIR}/systemd/palworld-wg-down.service"
  "${SCRIPT_DIR}/systemd/palworld-wg-up.sh"
  "${SCRIPT_DIR}/systemd/palworld-wg-down.sh"
)

for f in "${need[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing file: $f"
    echo "Run this from the Palworld Script folder (keep all files together)."
    exit 1
  fi
done

echo "==> Installing Palworld WireGuard helper (overwrite mode)"
echo "    source: ${SCRIPT_DIR}"

echo "==> Ensuring directories exist"
mkdir -p "$BIN_DIR" "$CONF_DIR" "$STATE_DIR" "$LIB_DIR"

echo "==> Overwriting user scripts in ${BIN_DIR}"
install -m 755 -T "${SCRIPT_DIR}/palworld-wg.sh" "${BIN_DIR}/palworld-wg.sh"
install -m 755 -T "${SCRIPT_DIR}/palworld-wg-ctl" "${BIN_DIR}/palworld-wg-ctl"

echo "==> Overwriting ${CONF_DST}"
install -m 644 -T "${SCRIPT_DIR}/palworld-wg.conf" "$CONF_DST"

if [[ ! -f /etc/wireguard/wg0.conf ]]; then
  echo
  echo "WARNING: /etc/wireguard/wg0.conf not found."
  echo "         Install your WireGuard peer config there before testing."
fi

if [[ ! -x /usr/bin/wg-quick ]]; then
  echo
  echo "WARNING: /usr/bin/wg-quick not found. Install wireguard-tools first."
fi

echo "==> Installing systemd path units + root helpers (sudo password once)"
sudo steamos-readonly disable || true

sudo mkdir -p "$LIB_DIR" "$UNIT_DIR"

# Root-owned helpers invoked by systemd
sudo install -m 755 -o root -g root -T \
  "${SCRIPT_DIR}/systemd/palworld-wg-up.sh" "${LIB_DIR}/palworld-wg-up.sh"
sudo install -m 755 -o root -g root -T \
  "${SCRIPT_DIR}/systemd/palworld-wg-down.sh" "${LIB_DIR}/palworld-wg-down.sh"

sudo install -m 644 -o root -g root -T \
  "${SCRIPT_DIR}/systemd/palworld-wg-up.path" "${UNIT_DIR}/palworld-wg-up.path"
sudo install -m 644 -o root -g root -T \
  "${SCRIPT_DIR}/systemd/palworld-wg-up.service" "${UNIT_DIR}/palworld-wg-up.service"
sudo install -m 644 -o root -g root -T \
  "${SCRIPT_DIR}/systemd/palworld-wg-down.path" "${UNIT_DIR}/palworld-wg-down.path"
sudo install -m 644 -o root -g root -T \
  "${SCRIPT_DIR}/systemd/palworld-wg-down.service" "${UNIT_DIR}/palworld-wg-down.service"

sudo systemctl daemon-reload
sudo systemctl enable --now palworld-wg-up.path palworld-wg-down.path

# Clean leftover request flags
rm -f "${STATE_DIR}/want-up" "${STATE_DIR}/want-down"

sudo steamos-readonly enable || true

echo "==> Testing tunnel bring-up WITHOUT sudo (Steam Play path)"
"${BIN_DIR}/palworld-wg-ctl" down >/dev/null 2>&1 || true

set +e
up_out="$("${BIN_DIR}/palworld-wg-ctl" up 2>&1)"
up_rc=$?
set -e

echo "$up_out"

if [[ $up_rc -ne 0 ]]; then
  echo
  echo "ERROR: ctl up failed (exit $up_rc)."
  echo "Debug:"
  echo "  systemctl status palworld-wg-up.path palworld-wg-up.service --no-pager"
  echo "  journalctl -u palworld-wg-up.service -n 50 --no-pager"
  exit 1
fi

echo "==> Status:"
"${BIN_DIR}/palworld-wg-ctl" status || true
sudo wg show wg0 2>/dev/null || true

echo "==> Bringing tunnel back down"
"${BIN_DIR}/palworld-wg-ctl" down >/dev/null 2>&1 || true

echo
echo "=============================================="
echo " Install OK (files overwritten)"
echo "=============================================="
echo
echo "ONE manual Steam step left:"
echo "  Palworld → Properties → Launch Options:"
echo
echo "    /home/deck/bin/palworld-wg.sh %command%"
echo
echo "Test from Desktop OR Game Mode — press Play."
echo "(Steam blocks sudo; this install uses file triggers instead.)"
echo
echo "After a play session, check:"
echo "  cat /home/deck/.local/state/palworld-wg/last-status"
echo "  tail -50 /home/deck/.local/state/palworld-wg/launch.log"
echo "  cat /home/deck/.local/state/palworld-wg/last-failure.log   # only if it failed"
echo
