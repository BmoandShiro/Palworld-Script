#!/usr/bin/env bash
# Steam Launch Options wrapper for Palworld on Steam Deck (Game Mode).
#
# Launch Options (exact):
#   /home/deck/bin/palworld-wg.sh %command%
#
# Uses a systemd path unit (touch want-up) so Steam Play works without sudo.
#
# If WireGuard fails, Palworld still launches.
# Diagnostics: ~/.local/state/palworld-wg/launch.log and last-failure.log
set -euo pipefail

# Steam injects 32-bit gameoverlayrenderer via LD_PRELOAD; strip it for host tools.
unset LD_PRELOAD LD_LIBRARY_PATH STEAM_RUNTIME_LIBRARY_PATH || true

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
PING_BIN="$(command -v ping || true)"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/palworld-wg"
LOG="$LOG_DIR/launch.log"
FAIL_LOG="$LOG_DIR/last-failure.log"
STATUS_FILE="$LOG_DIR/last-status"
SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"

LOADED_CONF=""

for conf in "${CONF_CANDIDATES[@]}"; do
  [[ -n "$conf" && -f "$conf" ]] || continue
  # shellcheck disable=SC1090
  source "$conf"
  LOADED_CONF="$conf"
  break
done

UNIT="wg-quick@${WG_INTERFACE}.service"
mkdir -p "$LOG_DIR"

# Keep launch.log from growing forever (~last 400KB kept on each start).
if [[ -f "$LOG" ]]; then
  local_size="$(wc -c <"$LOG" 2>/dev/null || echo 0)"
  if [[ "${local_size:-0}" -gt 400000 ]]; then
    tail -c 200000 "$LOG" >"${LOG}.tmp" 2>/dev/null && mv -f "${LOG}.tmp" "$LOG"
  fi
fi

log() {
  printf '[%s] [%s] %s\n' "$(date -Iseconds)" "$SESSION_ID" "$*" | tee -a "$LOG" >&2
}

write_status() {
  printf '%s\n' "$*" >"$STATUS_FILE"
}

# Run host binaries without Steam's LD_PRELOAD / weird PATH.
clean_run() {
  env -u LD_PRELOAD -u LD_LIBRARY_PATH -u STEAM_RUNTIME_LIBRARY_PATH \
    PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

iface_up() {
  [[ -n "$IP_BIN" ]] && clean_run "$IP_BIN" link show "$WG_INTERFACE" >/dev/null 2>&1
}

nonewprivs() {
  local v
  v="$(awk '/^NoNewPrivs:/{print $2}' /proc/self/status 2>/dev/null || echo unknown)"
  printf '%s' "$v"
}

dump_diagnostics() {
  local reason="$1"
  {
    echo "==== palworld-wg failure dump ===="
    echo "time=$(date -Iseconds)"
    echo "session=$SESSION_ID"
    echo "reason=$reason"
    echo "user=$(id -un) uid=$(id -u) home=${HOME:-}"
    echo "pwd=$(pwd 2>/dev/null || true)"
    echo "NoNewPrivs=$(nonewprivs)"
    echo "loaded_conf=${LOADED_CONF:-none}"
    echo "WG_INTERFACE=$WG_INTERFACE WG_HOST=$WG_HOST UNIT=$UNIT"
    echo "CTL=$CTL (exists=$([[ -e $CTL ]] && echo yes || echo no) exec=$([[ -x $CTL ]] && echo yes || echo no))"
    echo "ctl_version=$(clean_run "$CTL" version 2>/dev/null || echo unknown)"
    echo "SYSTEMCTL=$SYSTEMCTL (exec=$([[ -x $SYSTEMCTL ]] && echo yes || echo no))"
    echo "IP_BIN=$IP_BIN WG_BIN=$WG_BIN PING_BIN=${PING_BIN:-none}"
    # /etc/wireguard is often mode 700 — deck cannot -f the conf; do not call it MISSING.
    if [[ -d /etc/wireguard ]]; then
      echo "wg_conf_dir=/etc/wireguard (present; file visibility may require root)"
    else
      echo "wg_conf_dir=MISSING"
    fi
    echo "want-up=$([[ -f $LOG_DIR/want-up ]] && echo present || echo absent) want-down=$([[ -f $LOG_DIR/want-down ]] && echo present || echo absent)"
    echo "agent-status=$(cat "$LOG_DIR/agent-status" 2>/dev/null || echo none)"
    echo "path_up=$(clean_run "$SYSTEMCTL" is-enabled palworld-wg-up.path 2>&1 || true) $(clean_run "$SYSTEMCTL" is-active palworld-wg-up.path 2>&1 || true)"
    echo "path_down=$(clean_run "$SYSTEMCTL" is-enabled palworld-wg-down.path 2>&1 || true) $(clean_run "$SYSTEMCTL" is-active palworld-wg-down.path 2>&1 || true)"
    echo "iface_up=$(iface_up && echo yes || echo no)"
    echo "--- env (selected) ---"
    echo "PATH=${PATH:-}"
    echo "LD_PRELOAD=${LD_PRELOAD:-<unset>}"
    echo "DISPLAY=${DISPLAY:-} XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-} STEAM_RUNTIME=${STEAM_RUNTIME:-}"
    echo "DBUS_SYSTEM_BUS_ADDRESS=${DBUS_SYSTEM_BUS_ADDRESS:-} DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}"
    echo "--- ip link ---"
    clean_run "$IP_BIN" link show "$WG_INTERFACE" 2>&1 || echo "(no $WG_INTERFACE)"
    echo "--- systemctl status path/up ---"
    clean_run "$SYSTEMCTL" status palworld-wg-up.path palworld-wg-up.service --no-pager -l 2>&1 | tail -60 || true
    echo "--- journalctl palworld-wg-up (last 40) ---"
    clean_run journalctl -u palworld-wg-up.service -n 40 --no-pager 2>&1 | tail -50 || true
    if [[ -x "$WG_BIN" ]]; then
      echo "--- wg show ---"
      clean_run "$WG_BIN" show 2>&1 || true
    fi
    echo "--- recent launch.log tail ---"
    tail -40 "$LOG" 2>/dev/null || true
    echo "==== end dump ===="
  } >"$FAIL_LOG" 2>&1

  log "Failure diagnostics written to $FAIL_LOG"
  log "diag: NoNewPrivs=$(nonewprivs) ctl_version=$(clean_run "$CTL" version 2>/dev/null || echo ?) path_up=$(clean_run "$SYSTEMCTL" is-active palworld-wg-up.path 2>/dev/null || echo ?) iface=$(iface_up && echo up || echo down) agent=$(cat "$LOG_DIR/agent-status" 2>/dev/null || echo none)"
  if [[ -f "$FAIL_LOG" ]]; then
    while IFS= read -r line; do
      case "$line" in
        ERROR:*|Hint:*|Unit\ *|agent-status=*|ctl-version=*|requesting-*)
          log "diag: $line"
          ;;
      esac
    done < <(grep -E 'ERROR:|Failed|Access denied|Authentication|MISSING|agent-status|wg-quick|ctl-version|requesting-|timed out|want-up' "$FAIL_LOG" 2>/dev/null | grep -v 'ld.so: object' | tail -25)
  fi
}

log_session_banner() {
  log "======== session start ========"
  log "wrapper=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  log "user=$(id -un) uid=$(id -u) NoNewPrivs=$(nonewprivs)"
  log "conf=${LOADED_CONF:-none} interface=$WG_INTERFACE host=$WG_HOST"
  log "ctl=$CTL version=$(clean_run "$CTL" version 2>/dev/null || echo unknown)"
  log "path_units=$(clean_run "$SYSTEMCTL" is-enabled palworld-wg-up.path 2>/dev/null || echo unknown)/$(clean_run "$SYSTEMCTL" is-active palworld-wg-up.path 2>/dev/null || echo unknown)"
  log "args: $*"
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
  # Clean env so Steam LD_PRELOAD cannot break host bash/ip/systemctl.
  out="$(
    env -u LD_PRELOAD -u LD_LIBRARY_PATH -u STEAM_RUNTIME_LIBRARY_PATH \
      PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
      HOME="/home/deck" USER="deck" LOGNAME="deck" \
      "$CTL" "$action" 2>&1
  )"
  rc=$?
  set -e

  if [[ -n "$out" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # Drop noisy Steam overlay preload warnings
      [[ "$line" == *ld.so:object* ]] && continue
      [[ "$line" == *gameoverlayrenderer.so* ]] && continue
      log "ctl $action: $line"
    done <<<"$out"
  fi
  if [[ $rc -ne 0 ]]; then
    log "ctl $action exit=$rc"
  fi
  return "$rc"
}

wg_up() {
  if iface_up; then
    log "WireGuard already active: $WG_INTERFACE"
    write_status "up (already active)"
    return 0
  fi

  log "Bringing up WireGuard via request file (systemd path): $WG_INTERFACE"

  if run_ctl up && iface_up; then
    if [[ -x "$WG_BIN" ]]; then
      log "wg show: $("$WG_BIN" show "$WG_INTERFACE" 2>&1 | tr '\n' ' ')"
    fi
    write_status "up"
    return 0
  fi

  write_status "down (bring-up failed)"
  log "WARN: failed to bring up '$WG_INTERFACE'."
  dump_diagnostics "bring-up failed"
  return 1
}

wg_down() {
  log "Bringing down WireGuard: $WG_INTERFACE"
  run_ctl down || true
  if iface_up; then
    log "WARN: $WG_INTERFACE still present after down"
    write_status "up (down failed)"
  else
    write_status "down"
  fi
}

host_reachable() {
  if [[ -n "$PING_BIN" ]]; then
    "$PING_BIN" -c 1 -W 1 "$WG_HOST" >/dev/null 2>&1 && return 0
  fi
  return 1
}

wait_for_host() {
  local deadline=$((SECONDS + WAIT_SECONDS))
  local saw_iface=0
  log "Waiting up to ${WAIT_SECONDS}s for $WG_HOST (or active tunnel)..."
  while (( SECONDS < deadline )); do
    if host_reachable; then
      log "Host reachable: $WG_HOST"
      return 0
    fi
    if iface_up; then
      saw_iface=1
      sleep 2
      if iface_up; then
        log "Tunnel active (ping to $WG_HOST failed or filtered; continuing)"
        return 0
      fi
    fi
    sleep 1
  done
  log "WARN: timed out waiting for WireGuard / $WG_HOST (iface_seen=$saw_iface)"
  dump_diagnostics "host wait timed out"
  return 1
}

cleanup() {
  local status=$?
  wg_down || true
  log "Cleanup done (game exit status before trap: $status)"
  log "======== session end ========"
}

if [[ $# -lt 1 ]]; then
  mkdir -p "$LOG_DIR"
  log "ERROR: no game command provided. Use Steam Launch Options:"
  log "  /home/deck/bin/palworld-wg.sh %command%"
  exit 2
fi

log_session_banner "$@"
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
