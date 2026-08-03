# Palworld + WireGuard on Steam Deck (Game Mode)

WireGuard stays **off** until you press Play on Palworld. The launch script starts `wg-quick@wg0` via **systemctl + polkit**, runs the game, then stops the tunnel.

**Why not sudo?** Steam Game Mode sets `NO_NEW_PRIVS` on launched processes. That blocks `sudo` / setuid even with NOPASSWD. Desktop Konsole tests can pass while Game Mode still fails — that is expected. Polkit + systemctl talks to systemd over D-Bus and works under Game Mode.

If WireGuard fails, **Palworld still launches**. Check:

- `~/.local/state/palworld-wg/launch.log`
- `~/.local/state/palworld-wg/last-status`

```
Play → systemctl start wg-quick@wg0 → wait for 10.8.0.1 → game → systemctl stop
```

## Files

| File | Purpose |
|------|---------|
| `install.sh` | One-shot Konsole installer (run this) |
| `palworld-wg.sh` | Steam Launch Options wrapper |
| `palworld-wg-ctl` | Starts/stops/status via `systemctl` |
| `palworld-wg.conf` | Interface + host IP |
| `99-palworld-wg.rules` | Polkit: allow `deck` to start/stop `wg-quick@wg0` |
| `sudoers.palworld-wg` | Optional Desktop-only sudo fallback (not used by Game Mode path) |

---

## Prerequisites

- `/etc/wireguard/wg0.conf` installed
- `wireguard-tools` (`wg-quick`, `wg-quick@.service`)
- Palworld installed

Manual tunnel test (Desktop):

```bash
sudo systemctl start wg-quick@wg0
sudo wg show
ping -c 2 10.8.0.1
sudo systemctl stop wg-quick@wg0
```

Do **not** `systemctl enable wg-quick@wg0` (that would auto-start at boot).

---

## Install (one command)

In **Desktop Mode** Konsole:

```bash
cd ~/Palworld-Script-main   # or wherever this folder is
bash install.sh
```

Enter the Deck password when asked. The script **creates any missing dirs** and **overwrites** previous helper files, then tests tunnel up/down **without** sudo.

When it prints `Install OK`, set Launch Options once:

```text
/home/deck/bin/palworld-wg.sh %command%
```

Then Game Mode → Play Palworld.

If `install.sh` says polkit failed, reboot once and run:

```bash
/home/deck/bin/palworld-wg-ctl up
```

After playing, check:

```bash
cat /home/deck/.local/state/palworld-wg/last-status
tail -30 /home/deck/.local/state/palworld-wg/launch.log
```


---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Desktop `sudo wg-quick` works, Game Mode does not | Normal if using sudo only. Install **polkit** rule and use **ctl without sudo**. |
| `NoNewPrivs=1` in log + bring-up failed | Polkit missing/wrong. Reinstall `99-palworld-wg.rules`, then `ctl up` with no sudo. |
| `last-status` is `up` but Relay shows offline | Handshake/traffic issue: `ping 10.8.0.1`, confirm peer still on server, endpoint reachable. |
| Auth popup on `ctl up` | Polkit rule not applied; fix Step 2 (reboot if needed). |
| Game opens, cannot join server | WG failed open; read launch.log. |

---

## Uninstall

```bash
# Clear Launch Options in Steam

sudo steamos-readonly disable
sudo rm -f /etc/polkit-1/rules.d/99-palworld-wg.rules
sudo rm -f /etc/sudoers.d/palworld-wg
sudo steamos-readonly enable

rm -f /home/deck/bin/palworld-wg.sh /home/deck/bin/palworld-wg-ctl
rm -f /home/deck/.config/palworld-wg.conf
```

---

## Security note

Polkit only allows `deck` to start/stop **`wg-quick@wg0.service`**. Do not paste `wg0.conf` (private key) into chat.
