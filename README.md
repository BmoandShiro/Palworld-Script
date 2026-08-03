# Palworld + WireGuard on Steam Deck (Game Mode + Desktop Steam)

WireGuard stays **off** until you press Play on Palworld. The launch script creates a request file; a **systemd path unit** (running as root) brings `wg0` up, then tears it down when the game exits.

**Why this design?** Steam sets `NO_NEW_PRIVS` when you press Play (Desktop Steam and Game Mode). That blocks `sudo`. Desktop Konsole also has a polkit password agent that Steam does not, so “works in Konsole / fails on Play” is expected for sudo/polkit approaches.

If WireGuard fails, **Palworld still launches**. Check:

- `~/.local/state/palworld-wg/launch.log` — full session log
- `~/.local/state/palworld-wg/last-status` — `up` / `down (...)`
- `~/.local/state/palworld-wg/last-failure.log` — detailed dump on failure

```
Play → touch want-up → systemd runs wg-quick up → game → touch want-down → wg-quick down
```

## Files

| File | Purpose |
|------|---------|
| `install.sh` | One-shot Konsole installer (run this) |
| `palworld-wg.sh` | Steam Launch Options wrapper |
| `palworld-wg-ctl` | Creates want-up / want-down request files |
| `palworld-wg.conf` | Interface + host IP |
| `systemd/*` | Path/service units + root helper scripts |

---

## Prerequisites

- Deck peer `.conf` from Relay (WireGuard), saved as e.g. `~/Downloads/wg0.conf` or next to `install.sh` as `wg0.conf`
- `wireguard-tools` (`/usr/bin/wg-quick`)
- Palworld installed

`install.sh` will copy that peer file to `/etc/wireguard/wg0.conf` automatically when it finds it.
---

## Install (one command)

In **Desktop Mode** Konsole:

```bash
cd ~/Palworld-Script-main   # or wherever this folder is
bash install.sh
```

Enter the Deck password when asked. The script **creates any missing dirs**, **overwrites** previous helper files, enables systemd path watchers, and tests tunnel up/down **without** sudo.

When it prints `Install OK`, set Launch Options once:

```text
/home/deck/bin/palworld-wg.sh %command%
```

Then press Play (Desktop Steam or Game Mode).

After playing, check:

```bash
cat /home/deck/.local/state/palworld-wg/last-status
tail -50 /home/deck/.local/state/palworld-wg/launch.log
# If it failed:
cat /home/deck/.local/state/palworld-wg/last-failure.log
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Konsole/`ctl up` works, Play does not | Old sudo/polkit install. Re-run `bash install.sh` (path-unit version). Confirm Launch Options. |
| `last-status` down after Play | Paste `last-failure.log`. Check `systemctl status palworld-wg-up.path --no-pager`. |
| `last-status` is `up` but Relay shows offline | Handshake/traffic: join via `10.8.0.1`, `ping 10.8.0.1` while in-game/tunnel up. |
| Path unit inactive | `sudo systemctl enable --now palworld-wg-up.path palworld-wg-down.path` |

---

## Uninstall

```bash
# Clear Launch Options in Steam

sudo steamos-readonly disable
sudo systemctl disable --now palworld-wg-up.path palworld-wg-down.path
sudo rm -f /etc/systemd/system/palworld-wg-up.path \
  /etc/systemd/system/palworld-wg-up.service \
  /etc/systemd/system/palworld-wg-down.path \
  /etc/systemd/system/palworld-wg-down.service
sudo systemctl daemon-reload
sudo rm -rf /home/deck/.local/lib/palworld-wg
sudo rm -f /etc/polkit-1/rules.d/99-palworld-wg.rules /etc/sudoers.d/palworld-wg
sudo steamos-readonly enable

rm -f /home/deck/bin/palworld-wg.sh /home/deck/bin/palworld-wg-ctl
rm -f /home/deck/.config/palworld-wg.conf
```

---

## Security note

The path units only run the two small root scripts that call `wg-quick up/down wg0`. Do not paste `wg0.conf` (private key) into chat.
