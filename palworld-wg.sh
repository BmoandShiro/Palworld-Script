#!/usr/bin/env bash
# Steam Launch Options wrapper for Palworld on Steam Deck (Game Mode).
#
# Launch Options (exact):
#   /home/deck/bin/palworld-wg.sh %command%
#
# Brings WireGuard up (wg-quick), waits for the game host, runs Palworld,
# then tears the tunnel down on exit (including crash / Force Quit).
#
# If WireGuard fails to connect, Palworld still launches (offline / local play).
set -euo pipefail

CONF_CANDIDATES=(
  "${PALWORLD_WG_CONF:-}"
  /home/deck/.config/palworld-wg.conf
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/palworld-wg.conf"
)

WG_INTERFACE="wg0"
WG_HOST="10.8.0.1"
WAIT_SECONDS="30"
CTL="${PALWORLD_WG_CTL:-/home/deck/bin/palworld-wg-ctl}"
SUDO_BIN="${SUDO_BIN:-/usr/bin/sudo}"
IP_BIN="${IP_BIN:-/usr/sbin/ip}"
[[ -x "$IP_BIN" ]] || IP_BIN="/bin/ip"
[[ -x "$IP_BIN" ]] || IP_BIN="$(command -v ip || true)"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/palworld-wg"
LOG="$LOG_DIR/launch.log"

for conf in "${CONF_CANDIDATES[@]}"; do
  [[ -n "$conf" && -f "$conf" ]] || continue
  # shellcheck disable=SC1090
  source "$conf"
  break
done

mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG" >&2
}

iface_up() {
  [[ -n "$IP_BIN" ]] && "$IP_BIN" link show "$WG_INTERFACE" >/dev/null 2>&1
}

run_ctl() {
  local action="$1"
  local out
  local rc=0

  if [[ ! -x "$CTL" ]]; then
    log "ERROR: ctl missing or not executable: $CTL"
    return 127
  fi

  if [[ ! -x "$SUDO_BIN" ]]; then
    log "ERROR: sudo not found at $SUDO_BIN"
    return 127
  fi

  # Capture stderr/stdout so Game Mode failures are visible in the log.
  # env -i avoids Steam/Proton polluting sudo; keep a minimal PATH.
  set +e
  out="$(
    env -i \
      HOME="/home/deck" \
      USER="deck" \
      LOGNAME="deck" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      "$SUDO_BIN" -n "$CTL" "$action" 2>&1
  )"
  rc=$?
  set -e

  if [[ -n "$out" ]]; then
    log "ctl $action output: $out"
  fi
  if [[ $rc -ne 0 ]]; then
    log "ctl $action exit=$rc"
  fi
  return "$rc"
}

wg_up() {
  if iface_up; then
    log "WireGuard already active: $WG_INTERFACE"
    return 0
  fi

  log "Bringing up WireGuard: $WG_INTERFACE"

  if run_ctl up; then
    return 0
  fi

  log "WARN: failed to bring up '$WG_INTERFACE'."
  log "Check: /etc/wireguard/${WG_INTERFACE}.conf, sudoers (!requiretty), and: $SUDO_BIN -n $CTL up"
  return 1
}

wg_down() {
  log "Bringing down WireGuard: $WG_INTERFACE"
  run_ctl down || true
}

host_reachable() {
  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 1 "$WG_HOST" >/dev/null 2>&1 && return 0
  fi
  return 1
}

wait_for_host() {
  local deadline=$((SECONDS + WAIT_SECONDS))
  log "Waiting up to ${WAIT_SECONDS}s for $WG_HOST (or active tunnel)..."
  while (( SECONDS < deadline )); do
    if host_reachable; then
      log "Host reachable: $WG_HOST"
      return 0
    fi
    if iface_up; then
      sleep 2
      if iface_up; then
        log "Tunnel active (ping to $WG_HOST failed or filtered; continuing)"
        return 0
      fi
    fi
    sleep 1
  done
  log "WARN: timed out waiting for WireGuard / $WG_HOST"
  return 1
}

cleanup() {
  local status=$?
  wg_down || true
  log "Cleanup done (game exit status before trap: $status)"
}

if [[ $# -lt 1 ]]; then
  log "ERROR: no game command provided. Use Steam Launch Options:"
  log "  /home/deck/bin/palworld-wg.sh %command%"
  exit 2
fi

trap cleanup EXIT INT TERM HUP

# WireGuard is best-effort: never block the game from starting.
if wg_up; then
  if ! wait_for_host; then
    log "WARN: WireGuard up but host not ready; launching Palworld anyway"
  fi
else
  log "WARN: WireGuard unavailable; launching Palworld anyway"
fi

log "Starting game: $*"
set +e
"$@"
status=$?
set -e
log "Game exited with status $status"
exit "$status"
