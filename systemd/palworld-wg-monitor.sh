#!/usr/bin/env bash
# Palworld process watcher for Steam Deck.
# Runs as root via systemd. Every INTERVAL seconds:
#   - if Palworld is running  -> ensure wg0 is up
#   - if Palworld is not      -> ensure wg0 is down
#
# No Steam Launch Options needed. Negligible CPU (one pgrep + optional wg-quick).
set -u

MONITOR_VERSION="2026-08-02-monitor1"
INTERVAL="${PALWORLD_WG_INTERVAL:-60}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_QUICK="${WG_QUICK:-/usr/bin/wg-quick}"
IP_BIN="/usr/sbin/ip"
[[ -x "$IP_BIN" ]] || IP_BIN="/bin/ip"
STATE_DIR="/home/deck/.local/state/palworld-wg"
LOG="${STATE_DIR}/monitor.log"
STATUS_FILE="${STATE_DIR}/monitor-status"
CONF="/etc/wireguard/${WG_INTERFACE}.conf"

# Steam AppID for Palworld
PALWORLD_APPID="1623730"

mkdir -p "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG" >&2
}

# Keep log small
trim_log() {
  if [[ -f "$LOG" ]]; then
    local sz
    sz=$(wc -c <"$LOG" 2>/dev/null || echo 0)
    if [[ "${sz:-0}" -gt 200000 ]]; then
      tail -c 100000 "$LOG" >"${LOG}.tmp" 2>/dev/null && mv -f "${LOG}.tmp" "$LOG"
    fi
  fi
}

write_status() {
  printf '%s\n' "$*" >"$STATUS_FILE"
}

iface_up() {
  "$IP_BIN" link show "$WG_INTERFACE" >/dev/null 2>&1
}

# True if Palworld (native or Proton) appears to be running.
palworld_running() {
  # Proton game binary
  if pgrep -f '[P]alworld\.exe' >/dev/null 2>&1; then
    return 0
  fi
  # Steam launch wrapper / reaper for this AppID
  if pgrep -f "AppId=${PALWORLD_APPID}" >/dev/null 2>&1; then
    return 0
  fi
  # Native Linux binary name (uncommon for this title, but cheap)
  if pgrep -x 'Palworld' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wg_up() {
  if iface_up; then
    return 0
  fi
  if [[ ! -f "$CONF" ]]; then
    log "ERROR: missing $CONF — cannot bring up WireGuard"
    write_status "error-missing-conf palworld=$(palworld_running && echo yes || echo no)"
    return 1
  fi
  log "Palworld detected — bringing up ${WG_INTERFACE}"
  if "$WG_QUICK" up "$WG_INTERFACE"; then
    write_status "up palworld=yes"
    log "WireGuard ${WG_INTERFACE} is up"
    return 0
  fi
  log "ERROR: wg-quick up ${WG_INTERFACE} failed"
  write_status "error-up-failed palworld=yes"
  return 1
}

wg_down() {
  if ! iface_up; then
    write_status "down palworld=no"
    return 0
  fi
  log "Palworld not running — bringing down ${WG_INTERFACE}"
  if "$WG_QUICK" down "$WG_INTERFACE"; then
    write_status "down palworld=no"
    log "WireGuard ${WG_INTERFACE} is down"
    return 0
  fi
  log "ERROR: wg-quick down ${WG_INTERFACE} failed"
  write_status "error-down-failed palworld=no"
  return 1
}

tick() {
  if palworld_running; then
    wg_up || true
  else
    wg_down || true
  fi
}

log "monitor start version=${MONITOR_VERSION} interval=${INTERVAL}s interface=${WG_INTERFACE}"
write_status "starting"

# Run once immediately at boot/start, then loop
trim_log
tick

while true; do
  sleep "$INTERVAL"
  trim_log
  tick
done
