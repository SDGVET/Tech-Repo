# SDGVET Employee Workstation Autoinstall

Automated install for new employee machines: lean KDE Plasma desktop (Kubuntu
look) with only the apps we use, office printers pre-configured, LWVC wifi
pre-configured, ONLYOFFICE from Flathub.

## Why the Ubuntu Server ISO and not the Kubuntu ISO

`autoinstall.yaml` is a **subiquity** feature (the Ubuntu Server/Desktop
installer). **Kubuntu 26.04 still ships Calamares, which cannot read
autoinstall files.** The standard workaround — and a better fit for a
"no default programs" build anyway — is to install from the **Ubuntu Server
26.04 LTS ISO** with autoinstall, and let the package list build a lean
Plasma desktop. You end up with the Kubuntu desktop, wallpapers, and theming,
but *without* LibreOffice, Thunderbird, games, Elisa, snap Firefox, etc.

## Files

| File | Where it lives | Contains secrets? |
|---|---|---|
| `autoinstall.yaml` | **Install USB only — gitignored, never GitHub** | **YES — LWVC wifi passphrase, Pro token, Landscape key in plaintext** |
| `workstation-post-install.sh` | Lives in `SDGVET/Tech-Repo` at `kubuntu-autoinstall/` (main branch) | No |

**Why the wifi password is plaintext:** LWVC uses WPA3 (`key-mgmt=sae`).
The hashed-PSK trick (`wpa_passphrase` → 64-hex string) only exists for
WPA2-PSK; SAE authenticates with the actual passphrase, so NetworkManager
must store it as-is. That's why the yaml stays off GitHub (Tech-Repo is
public) and travels only on the install USB. On the installed machine the
keyfile is root-only (`0600`), same as on any laptop that has joined LWVC.

## How to use

1. `workstation-post-install.sh` lives in `SDGVET/Tech-Repo` under
   `kubuntu-autoinstall/` (main branch). The yaml pulls it from
   `https://raw.githubusercontent.com/SDGVET/Tech-Repo/main/kubuntu-autoinstall/workstation-post-install.sh`
   on first boot. (`autoinstall.yaml` itself is gitignored — it stays on the
   install USB only.)

2. Download **Ubuntu Server 26.04 LTS** ISO and write it to a USB stick
   (Ventoy, `dd`, or Startup Disk Creator).

3. Make the autoinstall seed. Easiest method — a **second, small USB stick**:
   ```bash
   # format it FAT32 with the volume label CIDATA (label is what matters)
   sudo mkfs.vfat -n CIDATA /dev/sdX1
   # copy autoinstall.yaml as "user-data" and add an empty "meta-data"
   cp autoinstall.yaml /media/$USER/CIDATA/user-data
   touch /media/$USER/CIDATA/meta-data
   ```
   (Ventoy alternative: put the ISO on a Ventoy stick and use Ventoy's
   autoinstall plugin pointing at this yaml — one stick instead of two.)

4. Boot the new machine with both USB sticks inserted. The installer detects
   the CIDATA volume and asks to confirm running the automated install.

   **Networking during install:** these workstations have no ethernet, so the
   `network:` block in the yaml joins wifi from *inside the installer* (it
   tries both **LWVC** at the office and **Epigenetics** at home, connecting
   to whichever is in range). Packages, the Ubuntu Pro attach, and security
   updates all download during install, so it must get online here. Caveats:
   - **The Server live ISO doesn't ship `wpa_supplicant`**, so wifi during
     install is impossible stock — the symptom is an install that fails at
     the package step with "Unable to locate package plasma-desktop"
     (universe is only reachable online). The yaml's `early-commands`
     handles this: it installs `wpasupplicant` + `libpcsclite1` from the
     ISO's own pool (`/cdrom/pool/...`) right before the network comes up.
     If Canonical ever drops those debs from the ISO pool, put copies on
     the CIDATA stick and point the dpkg line there instead.
   - The wifi NIC must have a driver + firmware present in the live installer.
     Most Intel/Realtek/Atheros chips are covered by the ISO's linux-firmware;
     an exotic adapter may not be. If wifi never comes up, switch to a
     **USB-to-ethernet dongle** for the install — the first-boot wifi profiles
     are already configured, so the machine still ends up on wifi afterward.
   - The yaml must name the wifi interface **literally** (currently
     `wlp0s20f3`) — netplan's networkd backend does not allow `match:`
     globs for wifi, and using one fails the install immediately with
     "problem applying the network configuration". On a different hardware
     model, Alt-F2 to a shell, run `ip link`, and put that machine's `wl*`
     name in the yaml before installing.
   - To debug a stuck install, Alt-F2 to a shell and check `ip addr` /
     `journalctl -u systemd-networkd`.

5. The only prompt is **hostname / username / password** (the
   `interactive-sections: [identity]` block). Fill those per employee.
   For zero prompts, delete that block and use the commented `identity:`
   section instead (generate the hash with `openssl passwd -6 'password'`).

6. On first boot, cloud-init writes the LWVC wifi profile and runs the
   post-install script (Chrome, Canon driver, printers, ONLYOFFICE).
   Check `/var/log/sdgvet-post-install.log` if something looks missing;
   the script is idempotent — re-run it any time with
   `sudo bash /usr/local/sbin/workstation-post-install.sh`.

## What gets installed

**During install (apt):** Plasma desktop core, Konsole, Dolphin, Ark, Kate,
KCalc, Gwenview, Okular, Spectacle, Skanpage (+ sane-airscan so it finds the
Canon over the network), VLC, Nextcloud desktop client, CUPS +
print-manager + DYMO driver, Discover (with Flatpak backend), flatpak.

**First boot (post-install script):**
- Google Chrome (deb registers Google's repo, so it auto-updates)
- Canon UFR-II v6.30 driver from the Tech-Repo release tarball
- Printer queues: Canon MF750C II (`10.25.35.170`, set as default),
  Arkscan-Reception (`10.25.35.218`), Arkscan1 (`10.25.35.125`) with the
  Tech-Repo PPD + the Minus90 orientation fix, DYMO LabelWriter 450 Turbo
  (via `install-dymo-printer.sh` — the DYMO does not have to be plugged in at
  install time; the queue is created on every machine and waits for the
  hardware, since that printer lives in a truck. A copy is left at
  `/usr/local/bin/sdgvet-install-dymo.sh` for hand-runs.)
- Disables cups-browsed (prevents duplicate auto-"driverless" Canon queues)
- Flathub + ONLYOFFICE (Proton Pass / Proton Mail lines included, commented)

**Deliberately NOT installed** (on the office machine but dev/personal):
Docker, PostgreSQL, Node.js, VS Code, Zed, git tooling, Steam, Wine,
Spotify, Brave, Firefox, FreeCAD, Kdenlive, virt-manager, Planify,
Warehouse, Remmina, HPLIP, wifiman, synaptic/aptitude, landscape-client.
