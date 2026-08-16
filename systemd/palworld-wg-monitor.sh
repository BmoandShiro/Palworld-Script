#!/usr/bin/env bash
# Game process watcher for Steam Deck (Palworld + Valheim).
# Runs as root via systemd. Every INTERVAL seconds:
#   - if a watched game is running  -> ensure wg0 is up
#   - if none are running           -> ensure wg0 is down
#
# No Steam Launch Options needed. Negligible CPU (pgrep + optional wg-quick).
set -u

MONITOR_VERSION="2026-08-16-pal-val2"
INTERVAL="${PALWORLD_WG_INTERVAL:-60}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_QUICK="${WG_QUICK:-/usr/bin/wg-quick}"
IP_BIN="/usr/sbin/ip"
[[ -x "$IP_BIN" ]] || IP_BIN="/bin/ip"
STATE_DIR="/home/deck/.local/state/palworld-wg"
LOG="${STATE_DIR}/monitor.log"
STATUS_FILE="${STATE_DIR}/monitor-status"
CONF="/etc/wireguard/${WG_INTERFACE}.conf"

# Steam AppIDs
PALWORLD_APPID="1623730"
VALHEIM_APPID="892970"

# Last detection reason (for logs / status)
DETECT_REASON=""

mkdir -p "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG" >&2
}

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

# Returns 0 if Palworld or Valheim is running; sets DETECT_REASON.
game_running() {
  DETECT_REASON=""

  # --- Palworld (Proton / native) ---
  if pgrep -fi 'palworld\.exe' >/dev/null 2>&1; then
    DETECT_REASON="palworld.exe"
    return 0
  fi
  if pgrep -f "AppId=${PALWORLD_APPID}" >/dev/null 2>&1; then
    DETECT_REASON="AppId=${PALWORLD_APPID}"
    return 0
  fi
  if pgrep -f 'steamapps/common/Palworld' >/dev/null 2>&1; then
    DETECT_REASON="path:Palworld"
    return 0
  fi
  if pgrep -x 'Palworld' >/dev/null 2>&1; then
    DETECT_REASON="proc:Palworld"
    return 0
  fi

  # --- Valheim (Proton shows valheim.exe; path often uses \Valheim\valheim.exe) ---
  # -fi = case-insensitive full cmdline (covers valheim.exe / Valheim.exe)
  if pgrep -fi 'valheim\.exe' >/dev/null 2>&1; then
    DETECT_REASON="valheim.exe"
    return 0
  fi
  # Install folder (Linux or Wine Z:\... paths)
  if pgrep -fi 'steamapps/common/Valheim' >/dev/null 2>&1; then
    DETECT_REASON="path:Valheim"
    return 0
  fi
  if pgrep -fi 'common.Valheim.valheim' >/dev/null 2>&1; then
    DETECT_REASON="path:Valheim-wine"
    return 0
  fi
  if pgrep -f "AppId=${VALHEIM_APPID}" >/dev/null 2>&1; then
    DETECT_REASON="AppId=${VALHEIM_APPID}"
    return 0
  fi
  # Process name alone (some Proton builds)
  if pgrep -xi 'valheim.exe' >/dev/null 2>&1; then
    DETECT_REASON="proc:valheim.exe"
    return 0
  fi
  if pgrep -xi 'valheim' >/dev/null 2>&1; then
    DETECT_REASON="proc:valheim"
    return 0
  fi

  return 1
}

wg_up() {
  if iface_up; then
    write_status "up game=yes via=${DETECT_REASON:-unknown}"
    return 0
  fi
  if [[ ! -f "$CONF" ]]; then
    log "ERROR: missing $CONF — cannot bring up WireGuard"
    write_status "error-missing-conf game=yes via=${DETECT_REASON:-unknown}"
    return 1
  fi
  log "Game detected (${DETECT_REASON}) — bringing up ${WG_INTERFACE}"
  if "$WG_QUICK" up "$WG_INTERFACE"; then
    write_status "up game=yes via=${DETECT_REASON}"
    log "WireGuard ${WG_INTERFACE} is up"
    return 0
  fi
  log "ERROR: wg-quick up ${WG_INTERFACE} failed"
  write_status "error-up-failed game=yes via=${DETECT_REASON}"
  return 1
}

wg_down() {
  if ! iface_up; then
    write_status "down game=no"
    return 0
  fi
  log "No watched game running — bringing down ${WG_INTERFACE}"
  if "$WG_QUICK" down "$WG_INTERFACE"; then
    write_status "down game=no"
    log "WireGuard ${WG_INTERFACE} is down"
    return 0
  fi
  log "ERROR: wg-quick down ${WG_INTERFACE} failed"
  write_status "error-down-failed game=no"
  return 1
}

tick() {
  if game_running; then
    wg_up || true
  else
    wg_down || true
  fi
}

log "monitor start version=${MONITOR_VERSION} interval=${INTERVAL}s interface=${WG_INTERFACE} games=palworld,valheim"
write_status "starting version=${MONITOR_VERSION}"

trim_log
tick

while true; do
  sleep "$INTERVAL"
  trim_log
  tick
done
