# Palworld + Valheim WireGuard on Steam Deck — process monitor

A **systemd service** runs at boot and every **60 seconds** checks whether Palworld or Valheim is running:

- Palworld **or** Valheim running → `wg-quick up wg0`
- Neither running → `wg-quick down wg0`

Detection covers Proton (e.g. `valheim.exe` / `Palworld.exe`), Steam AppIDs, and install paths.

CPU cost is tiny. Default interval is 60s (`PALWORLD_WG_INTERVAL=180` for 3 minutes).

## Install / update

Desktop Mode Konsole (re-run anytime to overwrite + restart the monitor):

```bash
cd ~/Downloads/Palworld-Script-main   # latest folder from this PC
bash install.sh
```

Needs your Deck peer `.conf` in `~/Downloads` (or `wg0.conf` next to the script).

Clear Launch Options for Palworld/Valheim (leave empty).

Press Play. Within ~1 minute the tunnel should be up; after quit, down on the next check.

## Status / logs

```bash
systemctl status palworld-wg-monitor.service
cat /home/deck/.local/state/palworld-wg/monitor-status
tail -50 /home/deck/.local/state/palworld-wg/monitor.log
sudo wg show
```

With Valheim open you should see something like:

```text
up game=yes via=valheim.exe
```

and in the log:

```text
Game detected (valheim.exe) — bringing up wg0
```

Quick process check:

```bash
pgrep -afi 'valheim\.exe|AppId=892970'
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
| `install.sh` | One-shot installer / updater |
| `systemd/palworld-wg-monitor.sh` | Watcher loop (Palworld + Valheim) |
| `systemd/palworld-wg-monitor.service` | Starts watcher at boot |
