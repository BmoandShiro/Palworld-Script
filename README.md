# Palworld + WireGuard on Steam Deck (Game Mode)

WireGuard stays **off** until you press Play on Palworld in Game Mode. A Steam launch script brings the tunnel up, starts the game, then tears WireGuard down when Palworld exits (including Force Quit / crash).

If WireGuard fails (bad sudoers, offline VPN endpoint, wrong connection name), **Palworld still launches** — you just will not be able to join the private server until the tunnel works. Check `~/.local/state/palworld-wg/launch.log` for `WARN` lines.

```
Play Palworld → up wg (best effort) → wait for 10.8.0.1 → run game → down wg
```

## Files in this folder

| File | Purpose |
|------|---------|
| `palworld-wg.sh` | Steam Launch Options wrapper (runs as `deck`) |
| `palworld-wg-ctl` | Small helper that runs `nmcli` up/down (via passwordless sudo) |
| `palworld-wg.conf` | Connection name + host IP |
| `sudoers.palworld-wg` | Passwordless sudo rule for the helper only |

Copy all of these to the Deck (USB, scp, Discord, etc.).

---

## Prerequisites

- Steam Deck on SteamOS
- WireGuard peer config for this Deck from your Relay / VPN UI (the `.conf` with `AllowedIPs = 10.8.0.1/32`)
- Palworld installed in Steam
- Comfort switching to **Desktop Mode** once for setup

---

## Step 1 — Switch to Desktop Mode

1. Hold the power button → **Switch to Desktop**
2. Open **Konsole** (keyboard: Steam + X)

---

## Step 2 — Import WireGuard into NetworkManager (once)

### Option A — GUI

1. Open **System Settings → Connections** (or Network)
2. **+** → **Import VPN connection…**
3. Select your Deck peer `.conf`
4. Save

### Option B — Terminal

```bash
nmcli connection import type wireguard file /path/to/your-deck-peer.conf
```

List connections and note the name NetworkManager gave it:

```bash
nmcli -t -f NAME,TYPE connection show | grep -i wireguard
```

**Rename it to match the script** (`palworld-wg`):

```bash
nmcli connection rename "OLD_NAME_HERE" palworld-wg
```

**Disable autoconnect** so the tunnel does not stay up at boot:

```bash
nmcli connection modify palworld-wg connection.autoconnect no
nmcli connection down palworld-wg 2>/dev/null || true
```

Quick test (optional):

```bash
nmcli connection up palworld-wg
ping -c 2 10.8.0.1
nmcli connection down palworld-wg
```

If ping fails but `nmcli connection show --active` lists `palworld-wg`, that can still be fine (some hosts block ICMP). Joining Palworld via `10.8.0.1` is the real test later.

---

## Step 3 — Install the scripts

```bash
mkdir -p /home/deck/bin /home/deck/.config

# If you copied this folder to Downloads:
cd "/home/deck/Downloads/Palworld Script"
# Or wherever you put these files.

cp palworld-wg.sh palworld-wg-ctl /home/deck/bin/
cp palworld-wg.conf /home/deck/.config/palworld-wg.conf

chmod 755 /home/deck/bin/palworld-wg.sh /home/deck/bin/palworld-wg-ctl
```

Lock down the privileged helper so only root can change it (required for safe sudoers):

```bash
sudo chown root:root /home/deck/bin/palworld-wg-ctl
sudo chmod 755 /home/deck/bin/palworld-wg-ctl
```

Edit the config if your NM name or host IP differs:

```bash
nano /home/deck/.config/palworld-wg.conf
```

```conf
WG_CONNECTION=palworld-wg
WG_HOST=10.8.0.1
WAIT_SECONDS=30
```

---

## Step 4 — Passwordless sudo (required for Game Mode)

Game Mode cannot type a sudo password. Allow **only** the control helper:

SteamOS is read-only by default. Unlock, install the rule, then lock again:

```bash
sudo steamos-readonly disable

sudo cp sudoers.palworld-wg /etc/sudoers.d/palworld-wg
sudo chown root:root /etc/sudoers.d/palworld-wg
sudo chmod 0440 /etc/sudoers.d/palworld-wg

# Validate syntax — must print: parse OK
sudo visudo -cf /etc/sudoers.d/palworld-wg

sudo steamos-readonly enable
```

If `visudo` reports errors, **fix them before rebooting** (a bad sudoers file can break sudo).

Test with **no password prompt**:

```bash
sudo -n /home/deck/bin/palworld-wg-ctl up
sudo -n /home/deck/bin/palworld-wg-ctl status
sudo -n /home/deck/bin/palworld-wg-ctl down
```

If you get `a password is required`, the sudoers file is wrong, not named correctly, or has bad permissions (must be `0440`).

---

## Step 5 — Set Palworld Launch Options

1. Open Steam (Desktop or Game Mode)
2. Palworld → **Properties** → **General** → **Launch Options**
3. Paste **exactly**:

```text
/home/deck/bin/palworld-wg.sh %command%
```

Do not use `~/bin/...` — Steam may not expand `~`.

Close Properties.

---

## Step 6 — Verify from Game Mode

1. **Return to Gaming Mode**
2. Launch **Palworld**
3. Join your server at the WireGuard host (`10.8.0.1` / whatever Relay shows)
4. Quit Palworld
5. Optional check from Desktop later:

```bash
nmcli -t -f NAME connection show --active | grep palworld-wg || echo "tunnel is down (good)"
```

### Logs

If launch fails or the tunnel misbehaves:

```bash
cat /home/deck/.local/state/palworld-wg/launch.log
```

---

## How it works

1. Steam runs `/home/deck/bin/palworld-wg.sh` with the real Palworld command as arguments (`%command%`).
2. The script calls `sudo -n /home/deck/bin/palworld-wg-ctl up` → `nmcli connection up id palworld-wg`.
3. It waits until the host responds (or the connection is active). If up or wait fails, it logs a `WARN` and continues.
4. It starts Palworld as a child process (**not** `exec`), so an `EXIT` trap still runs when the game ends.
5. On exit / crash / Force Quit, the trap runs `palworld-wg-ctl down`.

WireGuard is **not** left connected between sessions. A VPN failure never aborts the Steam launch.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Game launches but cannot join server | Confirm `WG_HOST` / join IP is `10.8.0.1`. Confirm peer is still valid on the Relay. Test `sudo -n /home/deck/bin/palworld-wg-ctl up` then ping/join. |
| Cannot join private server but game opens | WireGuard likely failed; read log for `WARN` / `ERROR`. Fix NM name or sudoers, then relaunch. |
| Steam shows instant fail / black flash | Usually a bad Launch Options line (missing `%command%`), not WG. Check log and Properties. |
| `password is required` | Reinstall `/etc/sudoers.d/palworld-wg`, mode `0440`, path must be exactly `/home/deck/bin/palworld-wg-ctl`. |
| Connection name not found | `nmcli connection show` and rename to `palworld-wg`, or change `WG_CONNECTION` in the conf **and** keep ctl in sync (ctl reads the same conf). |
| Tunnel stays up after quit | Trap failed; run `sudo -n /home/deck/bin/palworld-wg-ctl down` manually. Confirm you did **not** replace `%command%` incorrectly. |
| SteamOS update broke sudoers | Re-run Step 4 after major OS updates if `/etc/sudoers.d/palworld-wg` disappeared. |
| Edited `palworld-wg-ctl` and sudo refuses it | Re-apply `chown root:root` and `chmod 755` on the ctl script. |

---

## Uninstall

```bash
# Clear Launch Options in Steam first (empty the field)

sudo steamos-readonly disable
sudo rm -f /etc/sudoers.d/palworld-wg
sudo steamos-readonly enable

rm -f /home/deck/bin/palworld-wg.sh /home/deck/bin/palworld-wg-ctl
rm -f /home/deck/.config/palworld-wg.conf

nmcli connection delete palworld-wg   # optional: remove VPN connection
```

---

## Security note

The sudoers rule lets the `deck` user run **only** `/home/deck/bin/palworld-wg-ctl` as root with no password. Keep that file **root-owned** and mode `755`. Do not point sudoers at a script the `deck` user can overwrite without re-checking ownership.
