#!/usr/bin/env bash
# Runs as root via systemd. Always clears the want-down flag.
set -u
STATE=/home/deck/.local/state/palworld-wg
/usr/bin/wg-quick down wg0 || true
rm -f "${STATE}/want-down"
if /usr/sbin/ip link show wg0 >/dev/null 2>&1 || /bin/ip link show wg0 >/dev/null 2>&1; then
  echo "down-failed" >"${STATE}/agent-status"
  exit 1
fi
echo down >"${STATE}/agent-status"
exit 0
