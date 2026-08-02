# Palworld + WireGuard on Steam Deck (Game Mode)

WireGuard stays **off** until you press Play on Palworld in Game Mode. A Steam launch script brings the tunnel up (`wg-quick up wg0`), starts the game, then tears WireGuard down when Palworld exits (including Force Quit / crash).

If WireGuard fails (bad sudoers, offline endpoint, missing conf), **Palworld still launches** — you just will not be able to join the private server until the tunnel works. Check `~/.local/state/palworld-wg/launch.log` for `WARN` lines.

```
Play Palworld → wg-quick up wg0 (best effort) → wait for 10.8.0.1 → run game → wg-quick down
```

## Files in this folder

| File | Purpose |
|------|---------|
| `palworld-wg.sh` | Steam Launch Options wrapper (runs as `deck`) |
| `palworld-wg-ctl` | Helper that runs `wg-quick` up/down/status (via passwordless sudo) |
| `palworld-wg.conf` | Interface name + host IP |
| `sudoers.palworld-wg` | Passwordless sudo rule for the helper only |

Copy all of these to the Deck (USB, scp, Discord, etc.).

---

## Prerequisites

- Steam Deck on SteamOS
- Peer config installed as **`/etc/wireguard/wg0.conf`** (from Relay / VPN UI, `AllowedIPs = 10.8.0.1/32`)
- `wg-quick` available (`wireguard-tools`)
- Palworld installed in Steam
- Comfort switching to **Desktop Mode** once for setup

---

## Step 1 — Switch to Desktop Mode

1. Hold the power button → **Switch to Desktop**
2. Open **Konsole** (keyboard: Steam + X)

---

## Step 2 — Confirm WireGuard config (once)

You should already have:

```bash
sudo ls -l /etc/wireguard/wg0.conf
```

Manual activate / deactivate test:

```bash
sudo wg-quick up wg0
sudo wg show
ping -c 2 10.8.0.1
sudo wg-quick down wg0
```

Do **not** enable `wg-quick@wg0` at boot — we only want the tunnel while Palworld runs.

If `wg-quick` is missing:

```bash
sudo steamos-readonly disable
sudo pacman -Sy wireguard-tools
sudo steamos-readonly enable
```

---

## Step 3 — Install the scripts

```bash
mkdir -p /home/deck/bin /home/deck/.config

# Wherever you put these files, e.g.:
cd ~/Palworld-Script-main

cp palworld-wg.sh palworld-wg-ctl /home/deck/bin/
cp palworld-wg.conf /home/deck/.config/palworld-wg.conf

chmod 755 /home/deck/bin/palworld-wg.sh /home/deck/bin/palworld-wg-ctl
```

Lock down the privileged helper (required for safe sudoers):

```bash
sudo chown root:root /home/deck/bin/palworld-wg-ctl
sudo chmod 755 /home/deck/bin/palworld-wg-ctl
```

Config (defaults are fine if the interface is `wg0`):

```bash
nano /home/deck/.config/palworld-wg.conf
```

```conf
WG_INTERFACE=wg0
WG_HOST=10.8.0.1
WAIT_SECONDS=30
```

---

## Step 4 — Passwordless sudo (required for Game Mode)

Game Mode cannot type a sudo password. Allow **only** the control helper:

```bash
sudo steamos-readonly disable

sudo cp sudoers.palworld-wg /etc/sudoers.d/palworld-wg
sudo chown root:root /etc/sudoers.d/palworld-wg
sudo chmod 0440 /etc/sudoers.d/palworld-wg

# Validate syntax — must print: parse OK
sudo visudo -cf /etc/sudoers.d/palworld-wg

sudo steamos-readonly enable
```

The sudoers file includes `!requiretty` for the ctl command. That matters in **Game Mode**, where Steam launches the script with no terminal — without it, `sudo -n` can fail even though the same command works in Desktop Konsole.

Test with **no password prompt** (`-n` = fail instead of asking):

```bash
sudo -l

sudo -n /home/deck/bin/palworld-wg-ctl up
sudo -n /home/deck/bin/palworld-wg-ctl status
sudo wg show
sudo -n /home/deck/bin/palworld-wg-ctl down
```

- Success: `status` prints `active`, `wg show` lists `wg0`, no password asked.
- If you see `sudo: a password is required`, reinstall sudoers and `chown root:root` the ctl script again.

---

## Step 5 — Set Palworld Launch Options

1. Open Steam (Desktop or Game Mode)
2. Palworld → **Properties** → **General** → **Launch Options**
3. Paste **exactly**:

```text
/home/deck/bin/palworld-wg.sh %command%
```

Do not use `~/bin/...` — Steam may not expand `~`.

---

## Step 6 — Verify from Game Mode

1. **Return to Gaming Mode**
2. Launch **Palworld**
3. Join the server at `10.8.0.1`
4. Quit Palworld — tunnel should go down

Logs:

```bash
cat /home/deck/.local/state/palworld-wg/launch.log
```

---

## How it works

1. Steam runs `/home/deck/bin/palworld-wg.sh` with the real Palworld command (`%command%`).
2. The script calls `sudo -n /home/deck/bin/palworld-wg-ctl up` → `wg-quick up wg0`.
3. It waits briefly for `10.8.0.1` (or an active `wg0`). If up/wait fails, it logs a `WARN` and continues.
4. Palworld runs as a child process so an `EXIT` trap still fires.
5. On exit / crash / Force Quit → `wg-quick down wg0`.

---

## Manual tunnel control (Desktop)

```bash
# up
sudo -n /home/deck/bin/palworld-wg-ctl up
# or: sudo wg-quick up wg0

# status
sudo -n /home/deck/bin/palworld-wg-ctl status
sudo wg show

# down
sudo -n /home/deck/bin/palworld-wg-ctl down
# or: sudo wg-quick down wg0
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Works in Desktop, fails in Game Mode | Reinstall updated sudoers (includes `!requiretty`) and updated `palworld-wg.sh`. Relaunch once, then check log for `ctl up output:` / `ctl up exit=`. |
| `unknown connection 'palworld-wg'` | Old NM-based script. Re-copy updated `palworld-wg-ctl` / `palworld-wg.sh` (wg-quick version). |
| `Unable to access interface: No such device` | Tunnel is down. Run `ctl up` or `sudo wg-quick up wg0`. |
| Cannot join private server but game opens | WG failed; read log for `WARN` / `ctl up output`. Test `ctl up` + `ping 10.8.0.1`. |
| `password is required` / `must have a tty` | Reinstall `/etc/sudoers.d/palworld-wg` from this folder (has NOPASSWD + `!requiretty`). |
| SteamOS update broke sudoers | Re-run Step 4. |

---

## Uninstall

```bash
# Clear Launch Options in Steam first

sudo steamos-readonly disable
sudo rm -f /etc/sudoers.d/palworld-wg
sudo steamos-readonly enable

rm -f /home/deck/bin/palworld-wg.sh /home/deck/bin/palworld-wg-ctl
rm -f /home/deck/.config/palworld-wg.conf

# Optional: remove peer config
# sudo rm -f /etc/wireguard/wg0.conf
```

---

## Security note

The sudoers rule lets `deck` run **only** `/home/deck/bin/palworld-wg-ctl` as root with no password. Keep that file **root-owned** and mode `755`.

Never paste `/etc/wireguard/wg0.conf` (it contains a private key) into chat or screenshots. If it was exposed, revoke/rotate that peer on the Relay and install a new conf.
