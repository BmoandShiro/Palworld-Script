# Palworld + WireGuard on Steam Deck — process monitor

**Pivot:** no Steam Launch Options. A small **systemd service** runs at boot and every **60 seconds** checks whether Palworld is running:

- Palworld **running** → `wg-quick up wg0`
- Palworld **not running** → `wg-quick down wg0`

CPU cost is tiny (one `pgrep` per minute). 60s is the default; set `PALWORLD_WG_INTERVAL=180` in the unit if you prefer 3 minutes.

## Install

Desktop Mode Konsole:

```bash
cd ~/Downloads/Palworld-Script-main   # latest folder
bash install.sh
```

Needs your Deck peer `.conf` in `~/Downloads` (or next to the script as `wg0.conf`).

Then in Steam → Palworld → Properties → **clear Launch Options** (empty).

Press Play. Within about a minute the tunnel should be up; after you quit, it goes down on the next check.

## Status / logs

```bash
systemctl status palworld-wg-monitor.service
cat /home/deck/.local/state/palworld-wg/monitor-status
tail -50 /home/deck/.local/state/palworld-wg/monitor.log
sudo wg show
```

## Manual tunnel (optional)

```bash
sudo wg-quick up wg0
sudo wg-quick down wg0
```

## Uninstall

```bash
sudo steamos-readonly disable
sudo systemctl disable --now palworld-wg-monitor.service
sudo rm -f /etc/systemd/system/palworld-wg-monitor.service
sudo systemctl daemon-reload
sudo rm -f /home/deck/.local/lib/palworld-wg/palworld-wg-monitor.sh
sudo steamos-readonly enable
```

## Files

| File | Purpose |
|------|---------|
| `install.sh` | One-shot installer |
| `systemd/palworld-wg-monitor.sh` | Watcher loop |
| `systemd/palworld-wg-monitor.service` | Starts watcher at boot |

Legacy Launch Options scripts may still exist in this folder but are **not** used by `install.sh` anymore.
