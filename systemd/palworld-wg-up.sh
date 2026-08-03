#!/usr/bin/env bash
# Runs as root via systemd. Always clears the want-up flag.
set -u
STATE=/home/deck/.local/state/palworld-wg
/usr/bin/wg-quick up wg0 || true
rm -f "${STATE}/want-up"
# Mark result for the unprivileged waiter
if /usr/sbin/ip link show wg0 >/dev/null 2>&1 || /bin/ip link show wg0 >/dev/null 2>&1; then
  echo up >"${STATE}/agent-status"
  exit 0
fi
echo "up-failed" >"${STATE}/agent-status"
exit 1
