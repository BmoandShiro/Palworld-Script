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

# Hard-fail if an old ctl (with broken conf visibility check) somehow remains
if grep -q 'missing /etc/wireguard' "${BIN_DIR}/palworld-wg-ctl"; then
  echo "ERROR: installed ctl still contains old 'missing /etc/wireguard' check."
  echo "Update the Palworld-Script folder from the latest copy and re-run."
  exit 1
fi

CTL_VER="$("${BIN_DIR}/palworld-wg-ctl" version 2>/dev/null || echo unknown)"
echo "==> ctl version: ${CTL_VER} (expect 2026-08-02c or newer)"

echo "==> Overwriting ${CONF_DST}"
install -m 644 -T "${SCRIPT_DIR}/palworld-wg.conf" "$CONF_DST"

find_peer_conf() {
  local f
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
    if [[ -f "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  # Any .conf in the script folder that looks like WireGuard (has [Interface])
  # except our helper palworld-wg.conf
  while IFS= read -r -d '' f; do
    [[ "$(basename "$f")" == "palworld-wg.conf" ]] && continue
    if grep -q '^\[Interface\]' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)

  local newest=""
  local newest_m=0
  local m
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

PEER_SRC=""
if PEER_SRC="$(find_peer_conf)"; then
  echo "==> Found WireGuard peer config: ${PEER_SRC}"
else
  PEER_SRC=""
fi

if [[ ! -x /usr/bin/wg-quick ]]; then
  echo
  echo "WARNING: /usr/bin/wg-quick not found. Install wireguard-tools first."
fi

echo "==> Installing systemd path units + root helpers (sudo password once)"
sudo steamos-readonly disable || true

sudo mkdir -p "$LIB_DIR" "$UNIT_DIR" /etc/wireguard

if [[ -n "$PEER_SRC" ]]; then
  echo "==> Installing /etc/wireguard/wg0.conf (overwrite)"
  sudo install -m 600 -o root -g root -T "$PEER_SRC" /etc/wireguard/wg0.conf
elif sudo test -f /etc/wireguard/wg0.conf; then
  echo "==> Keeping existing /etc/wireguard/wg0.conf"
else
  echo
  echo "ERROR: No WireGuard peer config found."
  echo "Put your Deck peer file in one of these places, then re-run:"
  echo "  ${SCRIPT_DIR}/wg0.conf"
  echo "  ~/Downloads/wg0.conf"
  echo "Or:  WG_PEER_CONF=/path/to/peer.conf bash install.sh"
  echo
  echo "(Systemd units will still be installed so you only need the conf next.)"
fi

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

# /etc/wireguard is often mode 700 — deck cannot see files with a normal test -f
if ! sudo test -f /etc/wireguard/wg0.conf; then
  echo
  echo "Install partial: helpers/units OK, but /etc/wireguard/wg0.conf missing."
  if [[ -n "$PEER_SRC" ]]; then
    echo "Retry copy from: $PEER_SRC"
    echo "  sudo steamos-readonly disable"
    echo "  sudo mkdir -p /etc/wireguard"
    echo "  sudo install -m 600 -o root -g root -T \"$PEER_SRC\" /etc/wireguard/wg0.conf"
    echo "  sudo steamos-readonly enable"
  else
    echo "Place your peer .conf then re-run install, or:"
    echo "  WG_PEER_CONF=/path/to/peer.conf bash install.sh"
  fi
  echo "  /home/deck/bin/palworld-wg-ctl up"
  exit 1
fi

echo "==> Verified /etc/wireguard/wg0.conf (via sudo)"

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
