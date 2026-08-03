#!/usr/bin/env bash
# One-shot installer for Palworld WireGuard launch helper on Steam Deck.
# Run in Desktop Mode Konsole as user "deck":
#   bash install.sh
#
# Creates missing directories and always overwrites previous helper files.
set -euo pipefail

if [[ "$(id -un)" != "deck" ]]; then
  echo "ERROR: run this as user 'deck' (Steam Deck Desktop Konsole)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/home/deck/bin"
CONF_DIR="/home/deck/.config"
STATE_DIR="/home/deck/.local/state/palworld-wg"
CONF_DST="${CONF_DIR}/palworld-wg.conf"
POLKIT_DIR="/etc/polkit-1/rules.d"
POLKIT_DST="${POLKIT_DIR}/99-palworld-wg.rules"
SUDOERS_DST="/etc/sudoers.d/palworld-wg"

need=(
  "${SCRIPT_DIR}/palworld-wg.sh"
  "${SCRIPT_DIR}/palworld-wg-ctl"
  "${SCRIPT_DIR}/palworld-wg.conf"
  "${SCRIPT_DIR}/99-palworld-wg.rules"
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
mkdir -p "$BIN_DIR" "$CONF_DIR" "$STATE_DIR"

echo "==> Overwriting scripts in ${BIN_DIR}"
install -m 755 -T "${SCRIPT_DIR}/palworld-wg.sh" "${BIN_DIR}/palworld-wg.sh"
install -m 755 -T "${SCRIPT_DIR}/palworld-wg-ctl" "${BIN_DIR}/palworld-wg-ctl"

echo "==> Overwriting ${CONF_DST}"
install -m 644 -T "${SCRIPT_DIR}/palworld-wg.conf" "$CONF_DST"

if [[ ! -f /etc/wireguard/wg0.conf ]]; then
  echo
  echo "WARNING: /etc/wireguard/wg0.conf not found."
  echo "         Install your WireGuard peer config there before testing."
fi

if ! command -v wg-quick >/dev/null 2>&1 && [[ ! -x /usr/bin/wg-quick ]]; then
  echo
  echo "WARNING: wg-quick not found. Install wireguard-tools first."
fi

echo "==> Installing system files (sudo password may be required once)"
# steamos-readonly may already be disabled; ignore failures on disable/enable.
sudo steamos-readonly disable || true

sudo mkdir -p "$POLKIT_DIR" /etc/sudoers.d

echo "==> Overwriting ${POLKIT_DST}"
sudo install -m 644 -o root -g root -T "${SCRIPT_DIR}/99-palworld-wg.rules" "$POLKIT_DST"

if [[ -f "${SCRIPT_DIR}/sudoers.palworld-wg" ]]; then
  echo "==> Overwriting optional sudoers fallback ${SUDOERS_DST}"
  sudo install -m 440 -o root -g root -T "${SCRIPT_DIR}/sudoers.palworld-wg" "$SUDOERS_DST"
  if ! sudo visudo -cf "$SUDOERS_DST"; then
    echo "ERROR: sudoers file failed validation — removing it."
    sudo rm -f "$SUDOERS_DST"
    sudo steamos-readonly enable || true
    exit 1
  fi
fi

sudo steamos-readonly enable || true

echo "==> Reloading polkit (best effort)"
sudo systemctl reload polkit 2>/dev/null \
  || sudo systemctl restart polkit 2>/dev/null \
  || true

echo "==> Testing tunnel bring-up WITHOUT sudo (Game Mode path)"
# Ensure clean slate
"${BIN_DIR}/palworld-wg-ctl" down >/dev/null 2>&1 || true
sudo systemctl stop wg-quick@wg0 2>/dev/null || true

set +e
up_out="$("${BIN_DIR}/palworld-wg-ctl" up 2>&1)"
up_rc=$?
set -e

if [[ -n "$up_out" ]]; then
  echo "$up_out"
fi

if [[ $up_rc -ne 0 ]]; then
  echo
  echo "ERROR: ctl up failed (exit $up_rc)."
  echo "Polkit may need a reboot. Try:"
  echo "  reboot"
  echo "then re-run:  /home/deck/bin/palworld-wg-ctl up"
  exit 1
fi

echo "==> Status:"
"${BIN_DIR}/palworld-wg-ctl" status || true
if command -v wg >/dev/null 2>&1 || [[ -x /usr/bin/wg ]]; then
  sudo wg show wg0 2>/dev/null || /usr/bin/wg show wg0 2>/dev/null || true
fi

echo "==> Bringing tunnel back down (on-demand only while playing)"
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
echo "Then return to Game Mode and press Play."
echo
echo "After a play session, check:"
echo "  cat /home/deck/.local/state/palworld-wg/last-status"
echo "  tail -30 /home/deck/.local/state/palworld-wg/launch.log"
echo
