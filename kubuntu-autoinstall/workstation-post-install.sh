#!/bin/bash
# SDGVET workstation post-install
# Runs once on first boot (called by cloud-init from autoinstall user-data),
# but is safe to re-run by hand at any time:  sudo bash workstation-post-install.sh
#
# Installs: Google Chrome, Canon UFR-II driver, printer queues (Canon MF750C,
# both Arkscan label printers, DYMO if attached), Flathub + ONLYOFFICE.
#
# This file is SAFE to host in the public Tech-Repo — no passwords in here.

set -u

# ── SSH toggle ──────────────────────────────────────────────────────────────
# 1 = testing: SSH reachable from the admin laptop (sshd enabled, port 22 open
#     in ufw) so freshly imaged machines can be debugged remotely.
# 0 = production: sshd disabled and port 22 firewalled.
# FLIP TO 0 AND PUSH BEFORE IMAGING THE FINAL EMPLOYEE MACHINES — the
# installer fetches this script from GitHub main at install time.
# (Safe to flip on an already-imaged machine too: re-run this script by hand.)
ENABLE_SSH_FOR_TESTING=1

REPO_RAW="https://raw.githubusercontent.com/SDGVET/Tech-Repo/main"
CANON_TARBALL="https://github.com/SDGVET/Tech-Repo/releases/download/1.0/linux-UFRII-drv-v630-us-00.tar.gz"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# On first boot cloud-init sends our stdout/stderr to /var/log/sdgvet-post-
# install.log, so nothing shows on screen and the install looks frozen. Mirror
# everything to the system console too, so you can watch progress live by
# switching to a text console (Ctrl+Alt+F3) during first boot. tee keeps
# writing to the log file (its inherited stdout) as well. Skipped when the
# script is run by hand (stdout is a tty) to avoid double-printing.
if ! [ -t 1 ]; then
    exec > >(tee /dev/console) 2>&1
fi

log() { echo "[$(date '+%F %T')] $*"; }

# ---- Install-progress viewer (seeded FIRST, before any slow work) ---------
# The viewer's autostart entry must exist BEFORE anyone logs in, or nothing
# opens: autostart is evaluated at login time, and the slow sections below
# (Chrome, Canon driver, flatpaks) take minutes — an employee logging in
# mid-run would get no viewer if this were seeded at the end (it used to be,
# and that's exactly what happened). The account already exists: subiquity
# creates it during install, before this first-boot script runs.
cat > /usr/local/bin/sdgvet-show-install-log.sh <<'EOF'
#!/bin/bash
# Self-delete the autostart entry FIRST so this shows exactly once (must live
# here, not in Exec= -- the systemd xdg-autostart generator mangles $HOME).
rm -f "$HOME/.config/autostart/sdgvet-install-progress.desktop"
konsole --hold -e bash -c 'echo "=== SDGVET post-install progress -- close this window when it reads: Post-install complete. ==="; echo; tail -n +1 -F /var/log/sdgvet-post-install.log'
EOF
chmod 755 /usr/local/bin/sdgvet-show-install-log.sh

USER_NAME="$(getent passwd 1000 | cut -d: -f1)"
USER_HOME="$(getent passwd 1000 | cut -d: -f6)"
if [ -n "$USER_NAME" ] && [ -d "$USER_HOME" ]; then
    log "Seeding install-progress viewer autostart for $USER_NAME..."
    install -d -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.config/autostart"
    # install -d only chowns the FINAL dir; re-own ~/.config itself too
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.config"
    # Bare absolute path in Exec= (systemd generator garbles anything fancier);
    # the viewer script deletes this .desktop itself, first thing.
    cat > "$USER_HOME/.config/autostart/sdgvet-install-progress.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SDGVET Install Progress
Exec=/usr/local/bin/sdgvet-show-install-log.sh
X-KDE-autostart-phase=2
EOF
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.config/autostart/sdgvet-install-progress.desktop"
fi

# ---- wait for network (first boot may still be associating with wifi) ----
log "Waiting for network..."
for i in $(seq 1 60); do
    curl -Ifs --max-time 5 https://github.com >/dev/null 2>&1 && break
    sleep 5
done

# ---- Google Chrome (its .deb also registers the Google apt repo) ----------
if ! dpkg -s google-chrome-stable >/dev/null 2>&1; then
    log "Installing Google Chrome..."
    curl -fsSL -o "$WORKDIR/chrome.deb" \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        && apt-get install -y "$WORKDIR/chrome.deb"
else
    log "Google Chrome already installed."
fi

# ---- VetBadger web app (installed as a Chrome PWA) -------------------------
# Force-install the VetBadger PWA fleet-wide via Chrome enterprise policy.
# url points at login.vetbadger.com's login page, which serves the PWA manifest
# (name + icon) WITHOUT auth. Force-installing the clinic subdomain
# (livingwatersvet.vetbadger.com) instead produced a broken PLACEHOLDER app with
# no icon, because that host redirects to login before exposing a manifest.
# custom_name keeps the label "VetBadger". Verified on a live machine: this
# installs with VetBadger's real icon straight from the manifest, so no
# custom_icon override (and no hosted icon file) is needed.
#
# Chrome's apt install above is synchronous, but guard anyway so the policy is
# never written before Chrome (and its /etc/opt/chrome tree) is fully installed.
for i in $(seq 1 30); do dpkg -s google-chrome-stable >/dev/null 2>&1 && break; sleep 2; done
log "Configuring VetBadger web app (Chrome force-install policy)..."
mkdir -p /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/sdgvet-web-apps.json <<'EOF'
{
  "WebAppInstallForceList": [
    {
      "url": "https://login.vetbadger.com/login?originator=%2Fhome",
      "create_desktop_shortcut": true,
      "default_launch_container": "window",
      "custom_name": "VetBadger"
    }
  ]
}
EOF
chmod 644 /etc/opt/chrome/policies/managed/sdgvet-web-apps.json

# ---- Canon UFR-II driver v6.30 (for the MF750C II) ------------------------
if ! dpkg -s cnrdrvcups-ufr2-us >/dev/null 2>&1; then
    log "Installing Canon UFR-II driver..."
    curl -fsSL -o "$WORKDIR/ufr2.tar.gz" "$CANON_TARBALL" \
        && tar -xzf "$WORKDIR/ufr2.tar.gz" -C "$WORKDIR"
    DEB="$(find "$WORKDIR" -name 'cnrdrvcups-ufr2-us_*amd64.deb' | head -n1)"
    if [ -n "$DEB" ]; then
        apt-get install -y "$DEB"
    else
        log "ERROR: Canon driver .deb not found in tarball."
    fi
else
    log "Canon UFR-II driver already installed."
fi

# ---- Arkscan (Zebra-compatible) PPD from Tech-Repo -------------------------
log "Fetching Arkscan PPD..."
mkdir -p /usr/local/share/ppd
curl -fsSL -o /usr/local/share/ppd/Arkscan-Zebra.ppd "$REPO_RAW/Arkscan-Zebra.ppd"

# ---- Printer queues --------------------------------------------------------
log "Creating printer queues..."
lpadmin -p Canon-MF750C-II -E -v socket://10.25.35.170 -m CNRCUPSMF750C2ZS.ppd \
    -D "Canon MF750C II (main office)" || log "ERROR adding Canon queue"

lpadmin -p Arkscan-Reception -E -v socket://10.25.35.218 \
    -P /usr/local/share/ppd/Arkscan-Zebra.ppd \
    -D "Arkscan label printer (reception)" || log "ERROR adding Arkscan-Reception"

lpadmin -p Arkscan1 -E -v socket://10.25.35.125 \
    -P /usr/local/share/ppd/Arkscan-Zebra.ppd \
    -D "Arkscan label printer 1" || log "ERROR adding Arkscan1"

# DYMO LabelWriter 450 Turbo — only on machines where one is plugged in
if lpinfo -v 2>/dev/null | grep -q 'usb://DYMO/LabelWriter%20450%20Turbo'; then
    log "DYMO LabelWriter detected, adding queue..."
    lpadmin -p LabelWriter-450-Turbo -E \
        -v 'usb://DYMO/LabelWriter%20450%20Turbo' \
        -m dymo:0/cups/model/lw450t.ppd || log "ERROR adding DYMO queue"
fi

# Default printer
lpadmin -d Canon-MF750C-II || true

# Arkscan orientation fix (a CUPS/package update can reset this — same fix
# as fix-arkscan-orientation.sh in Tech-Repo)
for PRINTER in Arkscan-Reception Arkscan1; do
    PPD="/etc/cups/ppd/${PRINTER}.ppd"
    [ -f "$PPD" ] && sed -i 's/^\*LandscapeOrientation:.*/*LandscapeOrientation: Minus90/' "$PPD"
done

# Stop cups-browsed from auto-creating duplicate "driverless" queues for the
# Canon (we define our queues explicitly above)
systemctl disable --now cups-browsed >/dev/null 2>&1 || true

systemctl restart cups

# ---- Flatpak: Flathub + ONLYOFFICE ----------------------------------------
log "Setting up Flathub + ONLYOFFICE..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y --noninteractive --system flathub org.onlyoffice.desktopeditors \
    || log "ERROR installing ONLYOFFICE (re-run this script to retry)"

# Proton Pass (password manager) + Proton Mail (email client)
flatpak install -y --noninteractive --system flathub me.proton.Pass \
    || log "ERROR installing Proton Pass (re-run this script to retry)"
flatpak install -y --noninteractive --system flathub me.proton.Mail \
    || log "ERROR installing Proton Mail (re-run this script to retry)"

# ---- Firewall (ufw) + SSH (testing only, see ENABLE_SSH_FOR_TESTING) -------
# Default policy: deny all incoming, allow all outgoing. While the image is
# being tested, SSH is additionally let through so machines can be debugged
# from the admin laptop; production machines get sshd disabled and port 22
# closed. openssh-server is in the autoinstall package list either way (it's
# inert while sshd is disabled), so flipping the toggle later needs no network.
log "Enabling firewall (ufw)..."
if [ "$ENABLE_SSH_FOR_TESTING" = "1" ]; then
    log "TESTING mode: enabling sshd and opening port 22..."
    dpkg -s openssh-server >/dev/null 2>&1 || apt-get install -y openssh-server
    systemctl enable --now ssh || log "ERROR enabling sshd"
    ufw allow ssh || log "ERROR allowing ssh through ufw"
else
    log "Production mode: disabling sshd and closing port 22..."
    systemctl disable --now ssh 2>/dev/null || true
    ufw delete allow ssh 2>/dev/null || true
fi
ufw --force enable || log "ERROR enabling ufw"

# ---- Quiet graphical boot (Kubuntu-style Plymouth splash) -----------------
# Ubuntu Server boots verbose -- the scrolling green "[ OK ]" systemd log,
# which looks alarming to non-technical staff. Make it boot like Kubuntu: a
# quiet kernel with the Kubuntu logo splash, and a hidden GRUB menu.
# plymouth-theme-kubuntu-logo is already in the package list; we just select
# it (rebuilding the initramfs so the splash is available early) and add
# quiet/splash to the kernel command line. Employees never see the verbose
# boot -- it only happens during imaging, before this runs.
# NOTE: plymouth-set-default-theme no longer exists in 26.04 (the old code
# path always hit the WARN). Themes are picked via the default.plymouth
# alternative now; update-initramfs bakes the theme in so it shows early.
log "Configuring quiet graphical (Plymouth) boot..."
PLYTHEME=/usr/share/plymouth/themes/kubuntu-logo/kubuntu-logo.plymouth
if [ -f "$PLYTHEME" ]; then
    update-alternatives --set default.plymouth "$PLYTHEME" \
        && update-initramfs -u || log "ERROR setting plymouth theme"
else
    log "WARN: kubuntu-logo plymouth theme not found; skipping splash theme."
fi
GRUBCFG=/etc/default/grub
if [ -f "$GRUBCFG" ]; then
    # quiet + splash on the kernel cmdline (Server ships this empty)
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUBCFG"; then
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' "$GRUBCFG"
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> "$GRUBCFG"
    fi
    # Hide the GRUB menu (hold Shift/Esc at boot to show it for recovery)
    if grep -q '^GRUB_TIMEOUT_STYLE=' "$GRUBCFG"; then
        sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' "$GRUBCFG"
    else
        echo 'GRUB_TIMEOUT_STYLE=hidden' >> "$GRUBCFG"
    fi
    if grep -q '^GRUB_TIMEOUT=' "$GRUBCFG"; then
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' "$GRUBCFG"
    else
        echo 'GRUB_TIMEOUT=0' >> "$GRUBCFG"
    fi
    update-grub || log "ERROR running update-grub"
else
    log "WARN: /etc/default/grub not found; skipping kernel cmdline update."
fi

# ---- Desktop defaults (appearance + power) --------------------------------
# SDDM login theme is system-wide (set here). The Plasma dark theme + Honeywave
# wallpaper need the live Plasma session/D-Bus, so a one-shot first-login
# autostart applies them. The power profiles are just a config file PowerDevil
# reads at login, so we write it straight into the user's home.

# SDDM login theme. A `budgie-sddm-theme` package got pulled onto this Plasma
# build and ships /etc/sddm.conf.d/50-ubuntu-budgie.conf, which forced the
# Ubuntu Budgie greeter -- and since it sorts after our old 50-sdgvet-theme.conf
# it silently overrode us too (this is why the login "kept showing the old
# sddm"). Purge it, then set Breeze via a 90-* drop-in that sorts LAST so
# nothing (budgie, kubuntu-settings, a later kde_settings.conf, etc.) beats it.
# Greeter only -- unrelated to the first-login session black screen, so this
# stays enabled while the session theming is off.
log "Removing Budgie SDDM theme, setting Breeze login screen..."
apt-get purge -y budgie-sddm-theme >/dev/null 2>&1 || true
mkdir -p /etc/sddm.conf.d
rm -f /etc/sddm.conf.d/50-sdgvet-theme.conf   # retire the old name budgie beat
cat > /etc/sddm.conf.d/90-sdgvet-theme.conf <<'EOF'
[Theme]
Current=breeze
EOF

# Helper that applies the per-user Plasma bits that need the live session on
# first login: dark theme, Honeywave wallpaper, and natural scrolling. (Taskbar
# pinning was here too but is DISABLED -- it black-screened the desktop; see
# the pins note below.) Waits for plasmashell so the D-Bus calls don't race the
# desktop coming up.
log "Installing first-login Plasma helper..."
cat > /usr/local/bin/sdgvet-first-login-appearance.sh <<'EOF'
#!/bin/bash
for i in $(seq 1 30); do pgrep -x plasmashell >/dev/null && break; sleep 2; done
sleep 3

# Dark global theme first, THEN wallpaper -- applying a theme can reset the
# wallpaper, so doing Honeywave last makes it stick.
plasma-apply-lookandfeel -a org.kde.breezedark.desktop
plasma-apply-wallpaperimage /usr/share/wallpapers/Honeywave

# Natural scrolling on every detected touchpad/mouse. KDE stores this per
# device under [Libinput][vid][pid][name] in kcminputrc, so there's no fixed
# section to ship -- patch whatever device groups exist. Applies next login.
INPUTRC="$HOME/.config/kcminputrc"
[ -f "$INPUTRC" ] && python3 - "$INPUTRC" <<'PY'
import sys
p=sys.argv[1]
lines=open(p).read().split("\n")
out=[]; hdr=None; body=[]
def is_dev(h):
    h=h.rstrip()
    return h.startswith("[Libinput]") and (h.endswith("Touchpad]") or h.endswith("Mouse]"))
def flush():
    b=body
    if hdr is not None and is_dev(hdr):
        if any(l.startswith("NaturalScroll=") for l in b):
            b=["NaturalScroll=true" if l.startswith("NaturalScroll=") else l for l in b]
        else:
            b=["NaturalScroll=true"]+b
    if hdr is not None: out.append(hdr)
    out.extend(b)
for l in lines:
    if l.startswith("["):
        flush(); hdr=l; body=[]
    elif hdr is None:
        out.append(l)
    else:
        body.append(l)
flush()
open(p,"w").write("\n".join(out))
PY

# Taskbar pins: DISABLED. Editing the live panel appletsrc + refreshCurrentShell
# left plasmashell unable to load on a fresh image (black screen with only a
# cursor at first login). Needs a safe, non-live-edit approach before re-enabling
# -- see memory note [[workstation-autoinstall-project]]. VetBadger and Chrome
# still get menu entries; Calculator is a stock app; Konsole stays for now.

# Launch the Nextcloud desktop client once so it registers itself in autostart
# (it writes its own ~/.config/autostart entry on first run) and shows the
# employee the account sign-in prompt.
command -v nextcloud >/dev/null 2>&1 && nohup nextcloud >/dev/null 2>&1 &

# Start Chrome once, windowless, so the WebAppInstallForceList policy actually
# installs the VetBadger PWA -- the policy only applies while Chrome is
# running, so on a machine where the employee never opens Chrome the icon
# would never appear. --no-startup-window keeps it invisible; the resident
# process is simply reused when the employee opens Chrome normally.
command -v google-chrome >/dev/null 2>&1 && \
    nohup google-chrome --no-startup-window --no-first-run >/dev/null 2>&1 &

# Self-delete the autostart entry so this runs exactly once. This rm MUST live
# in here, not in the .desktop's Exec=: on Plasma 6 autostart entries run via
# systemd-xdg-autostart-generator, which mangles $HOME in Exec lines
# ("Ignoring unknown escape sequences" in the journal) -- the rm then targets a
# literal '$HOME/...' path and the entry re-fires at every login.
rm -f "$HOME/.config/autostart/sdgvet-appearance.desktop"
EOF
chmod 755 /usr/local/bin/sdgvet-first-login-appearance.sh

# (The install-progress viewer is created and seeded at the TOP of this
# script, before the slow sections, so it exists by the time anyone logs in.)

# Drop the one-shot autostart entry into the employee's account. The account
# is created interactively during install as UID 1000, and this first-boot
# script runs AFTER that -- so /etc/skel is too late; write the real home.
# The .desktop deletes itself after running (the helper stays, harmless).
USER_NAME="$(getent passwd 1000 | cut -d: -f1)"
USER_HOME="$(getent passwd 1000 | cut -d: -f6)"
if [ -n "$USER_NAME" ] && [ -d "$USER_HOME" ]; then
    log "Seeding first-login appearance autostart for $USER_NAME..."
    install -d -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.config/autostart"
    # `install -d` only chowns the FINAL dir, so if it had to create ~/.config
    # itself (fresh first boot, before the user has ever logged in) that parent
    # is left owned by root -- which then blocks the user's own apps (Nextcloud,
    # KDE, ...) from writing their config. Re-own ~/.config to the user. This is
    # why we ALSO run a broad chown of $USER_HOME/.config at the end of this block.
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.config"
    # Exec must be a bare absolute path: Plasma 6 runs autostart entries through
    # systemd-xdg-autostart-generator, which garbles $HOME (and quoting) in
    # Exec= lines. The helper deletes this .desktop itself when it finishes.
    cat > "$USER_HOME/.config/autostart/sdgvet-appearance.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SDGVET Appearance Defaults
Exec=/usr/local/bin/sdgvet-first-login-appearance.sh
X-KDE-autostart-phase=2
NoDisplay=true
EOF
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.config/autostart/sdgvet-appearance.desktop"

    # Full PowerDevil config copied from the reference machine: Performance on
    # AC / Power Save on battery + low battery, plus battery-only display
    # dimming & brightness, suspend timeouts, and lid/power-button actions.
    # PowerDevil reads this at login; power-profiles-daemon (in the package
    # list) provides the profiles the PowerProfile= names refer to.
    log "Writing power settings for $USER_NAME..."
    cat > "$USER_HOME/.config/powerdevilrc" <<'EOF'
[AC][Performance]
PowerProfile=performance

[AC][SuspendAndShutdown]
AutoSuspendAction=0
InhibitLidActionWhenExternalMonitorPresent=false
PowerButtonAction=1

[Battery][Display]
DimDisplayIdleTimeoutSec=300
DisplayBrightness=20
TurnOffDisplayIdleTimeoutSec=600
UseProfileSpecificDisplayBrightness=true

[Battery][Performance]
PowerProfile=power-saver

[Battery][SuspendAndShutdown]
AutoSuspendIdleTimeoutSec=300
InhibitLidActionWhenExternalMonitorPresent=false

[LowBattery][Display]
DisplayBrightness=13

[LowBattery][Performance]
PowerProfile=power-saver

[LowBattery][SuspendAndShutdown]
AutoSuspendIdleTimeoutSec=120
InhibitLidActionWhenExternalMonitorPresent=false
PowerButtonAction=1
EOF
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.config/powerdevilrc"

    # Screen auto-lock OFF (matches the reference machine). kscreenlocker reads
    # this at login. NOTE: these are shared-office workstations that may sit
    # unattended -- reconsider enabling lock later for anything with client data.
    log "Disabling screen auto-lock for $USER_NAME..."
    cat > "$USER_HOME/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockGrace=300
LockOnResume=false
Timeout=0
EOF
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.config/kscreenlockerrc"

    # (Install-progress viewer autostart is seeded at the TOP of this script.
    # If the employee logged in mid-run and the viewer already ran and deleted
    # its .desktop, nothing here re-creates it. VetBadger's launcher + icon
    # come from the Chrome force-install policy above, so there's nothing to
    # pre-create for it either.)

    # Belt-and-suspenders: everything above under ~/.config was written as root,
    # so re-own the whole tree to the user. A single root-owned dir/file here
    # (especially ~/.config itself) blocks the user's apps -- e.g. the Nextcloud
    # client can't access ~/.config/Nextcloud/nextcloud.cfg.
    chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.config"
else
    log "WARN: no UID 1000 user found; skipping per-user desktop defaults."
fi

# ---- Hand wifi to NetworkManager so the Plasma applet shows networks -------
# The installer sets up wifi through netplan's *networkd* renderer, and that
# carries over to the installed system, where networkd keeps owning the wifi
# NIC. networkd holds the link up (so the terminal, apt, and everything above
# in this script have network) but NetworkManager marks the device
# "unmanaged" -- so the Plasma applet shows NO networks even though you're
# online. Switch the installed system to the NetworkManager renderer so the
# LWVC / Epigenetics keyfiles that cloud-init dropped into
# /etc/NetworkManager/system-connections/ take over and show up in the applet.
# This runs LAST because netplan apply briefly drops the link. Idempotent.
log "Switching wifi from networkd to NetworkManager renderer..."
# 1. stop cloud-init from regenerating the networkd netplan on future boots
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
# 2. retire the installer's networkd wifi netplan (kept as a backup)
[ -f /etc/netplan/50-cloud-init.yaml ] && mv /etc/netplan/50-cloud-init.yaml /root/50-cloud-init.yaml.bak
# 3. make NetworkManager the renderer for everything
cat > /etc/netplan/01-network-manager-all.yaml <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 600 /etc/netplan/01-network-manager-all.yaml
# 4. apply; NM then reconnects via the keyfiles above
netplan apply || log "ERROR: netplan apply failed"
systemctl restart NetworkManager || true
# 5. networkd no longer manages any interface, so its wait-online service just
#    times out (~120s) every boot, making boot take minutes. Disable it --
#    NetworkManager-wait-online covers "system is online" now.
systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true

log "Post-install complete."
