#!/usr/bin/env bash
# Steam Launch Options wrapper for Palworld on Steam Deck (Game Mode).
#
# Launch Options (exact):
#   /home/deck/bin/palworld-wg.sh %command%
#
# Uses systemctl to start/stop wg-quick@wg0 (polkit). This avoids sudo, which
# Steam Game Mode blocks via PR_SET_NO_NEW_PRIVS.
#
# If WireGuard fails, Palworld still launches.
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
SYSTEMCTL="${SYSTEMCTL:-/usr/bin/systemctl}"
IP_BIN="${IP_BIN:-/usr/sbin/ip}"
[[ -x "$IP_BIN" ]] || IP_BIN="/bin/ip"
[[ -x "$IP_BIN" ]] || IP_BIN="$(command -v ip || true)"
WG_BIN="${WG_BIN:-/usr/bin/wg}"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/palworld-wg"
LOG="$LOG_DIR/launch.log"
STATUS_FILE="$LOG_DIR/last-status"

for conf in "${CONF_CANDIDATES[@]}"; do
  [[ -n "$conf" && -f "$conf" ]] || continue
  # shellcheck disable=SC1090
  source "$conf"
  break
done

UNIT="wg-quick@${WG_INTERFACE}.service"
mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG" >&2
}

write_status() {
  printf '%s\n' "$*" >"$STATUS_FILE"
}

iface_up() {
  [[ -n "$IP_BIN" ]] && "$IP_BIN" link show "$WG_INTERFACE" >/dev/null 2>&1
}

nonewprivs() {
  local v
  v="$(awk '/^NoNewPrivs:/{print $2}' /proc/self/status 2>/dev/null || echo unknown)"
  printf '%s' "$v"
}

run_ctl() {
  local action="$1"
  local out
  local rc=0

  if [[ ! -x "$CTL" ]]; then
    log "ERROR: ctl missing or not executable: $CTL"
    return 127
  fi

  set +e
  # No sudo — ctl uses systemctl/polkit so Game Mode NO_NEW_PRIVS is OK.
  out="$("$CTL" "$action" 2>&1)"
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
  log "NoNewPrivs=$(nonewprivs) (1 means Steam blocked sudo; systemctl path required)"

  if iface_up; then
    log "WireGuard already active: $WG_INTERFACE"
    write_status "up (already active)"
    return 0
  fi

  log "Bringing up WireGuard via systemctl: $UNIT"

  if run_ctl up && iface_up; then
    if [[ -x "$WG_BIN" ]]; then
      log "wg show: $("$WG_BIN" show "$WG_INTERFACE" 2>&1 | tr '\n' ' ')"
    fi
    write_status "up"
    return 0
  fi

  # Last-resort Desktop fallback (will fail under Game Mode NO_NEW_PRIVS).
  if [[ "$(nonewprivs)" != "1" ]] && [[ -x /usr/bin/sudo ]]; then
    log "Trying sudo fallback (Desktop only)..."
    set +e
    out="$(/usr/bin/sudo -n /usr/bin/wg-quick up "$WG_INTERFACE" 2>&1)"
    rc=$?
    set -e
    [[ -n "$out" ]] && log "sudo wg-quick output: $out"
    if [[ $rc -eq 0 ]] && iface_up; then
      write_status "up (sudo fallback)"
      return 0
    fi
  fi

  write_status "down (bring-up failed)"
  log "WARN: failed to bring up '$WG_INTERFACE'."
  log "Install polkit rule 99-palworld-wg.rules and ensure systemctl start $UNIT works as deck."
  return 1
}

wg_down() {
  log "Bringing down WireGuard: $WG_INTERFACE"
  run_ctl down || true
  if ! iface_up; then
    write_status "down"
  fi
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
