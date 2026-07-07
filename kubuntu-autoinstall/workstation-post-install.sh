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

REPO_RAW="https://raw.githubusercontent.com/SDGVET/Tech-Repo/main"
CANON_TARBALL="https://github.com/SDGVET/Tech-Repo/releases/download/1.0/linux-UFRII-drv-v630-us-00.tar.gz"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { echo "[$(date '+%F %T')] $*"; }

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
# On the next Chrome launch this installs a real installed web app (its own
# window, icon from the site manifest, and a desktop/app-menu shortcut) for
# whichever user is logged in -- no per-user setup, so it survives the
# interactive username prompt. To add more web apps later, append more
# objects to WebAppInstallForceList.
log "Configuring VetBadger web app (Chrome force-install policy)..."
mkdir -p /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/sdgvet-web-apps.json <<'EOF'
{
  "WebAppInstallForceList": [
    {
      "url": "https://livingwatersvet.vetbadger.com/",
      "create_desktop_shortcut": true,
      "default_launch_container": "window"
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

# ---- Firewall (ufw) -------------------------------------------------------
# Enable with the default policy: deny all incoming, allow all outgoing. A
# workstation runs no inbound services (printing, Nextcloud, VetBadger are all
# outbound), so nothing to open. Idempotent -- re-running just re-asserts it.
log "Enabling firewall (ufw)..."
ufw --force enable || log "ERROR enabling ufw"

# ---- Desktop defaults (appearance + power) --------------------------------
# SDDM login theme is system-wide (set here). The Plasma dark theme + Honeywave
# wallpaper need the live Plasma session/D-Bus, so a one-shot first-login
# autostart applies them. The power profiles are just a config file PowerDevil
# reads at login, so we write it straight into the user's home.

# SDDM login screen -> Breeze. A drop-in named 50-* sorts AFTER the packaged
# 20-kubuntu.conf (Current=kubuntu) so it wins on a fresh image; a later change
# via System Settings writes kde_settings.conf, which still overrides us.
log "Setting SDDM login theme to Breeze..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/50-sdgvet-theme.conf <<'EOF'
[Theme]
Current=breeze
EOF

# Helper that applies the per-user Plasma bits that need the live session on
# first login: dark theme, Honeywave wallpaper, natural scrolling, and taskbar
# pins. Waits for plasmashell so D-Bus calls and config edits don't race the
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

# Taskbar pins: add Chrome, VetBadger, Calculator; drop Konsole. The pin list
# lives on the task-manager applet's launchers= key in the panel config. Edit
# it in place, keeping whatever other default pins exist, then reload the shell.
APPLETS="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
[ -f "$APPLETS" ] && python3 - "$APPLETS" <<'PY'
import sys
p=sys.argv[1]
want=["applications:google-chrome.desktop",
      "applications:chrome-ojdepafgebajpbdahdokdolkoekmbooa-Default.desktop",
      "applications:org.kde.kcalc.desktop"]
out=[]
for l in open(p).read().split("\n"):
    if l.startswith("launchers="):
        items=[x for x in l[len("launchers="):].split(",") if x]
        items=[x for x in items if "konsole" not in x.lower()]
        for w in want:
            if not any(w.split(":")[-1]==x.split(":")[-1] for x in items):
                items.append(w)
        out.append("launchers="+",".join(items))
    else:
        out.append(l)
open(p,"w").write("\n".join(out))
PY

# Ask plasmashell to reload the edited panel config (qdbus name varies by ver).
for q in qdbus qdbus6 qdbus-qt6; do
    command -v "$q" >/dev/null 2>&1 && "$q" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null && break
done
EOF
chmod 755 /usr/local/bin/sdgvet-first-login-appearance.sh

# Drop the one-shot autostart entry into the employee's account. The account
# is created interactively during install as UID 1000, and this first-boot
# script runs AFTER that -- so /etc/skel is too late; write the real home.
# The .desktop deletes itself after running (the helper stays, harmless).
USER_NAME="$(getent passwd 1000 | cut -d: -f1)"
USER_HOME="$(getent passwd 1000 | cut -d: -f6)"
if [ -n "$USER_NAME" ] && [ -d "$USER_HOME" ]; then
    log "Seeding first-login appearance autostart for $USER_NAME..."
    install -d -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.config/autostart"
    cat > "$USER_HOME/.config/autostart/sdgvet-appearance.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SDGVET Appearance Defaults
Exec=sh -c '/usr/local/bin/sdgvet-first-login-appearance.sh; rm -f "$HOME/.config/autostart/sdgvet-appearance.desktop"'
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

    # Pre-create the VetBadger launcher so the taskbar pin (added by the
    # first-login helper) resolves from login one, instead of only after Chrome
    # first runs and the force-installed PWA writes this file itself. Same
    # app-id/filename Chrome uses, so it's not a duplicate -- Chrome just
    # rewrites it on PWA install. The icon resolves once Chrome drops its PNG.
    log "Pre-creating VetBadger launcher for $USER_NAME..."
    install -d -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.local/share/applications"
    cat > "$USER_HOME/.local/share/applications/chrome-ojdepafgebajpbdahdokdolkoekmbooa-Default.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Terminal=false
Type=Application
Name=VetBadger
Exec=/opt/google/chrome/google-chrome --profile-directory=Default --app-id=ojdepafgebajpbdahdokdolkoekmbooa
Icon=chrome-ojdepafgebajpbdahdokdolkoekmbooa-Default
StartupWMClass=crx_ojdepafgebajpbdahdokdolkoekmbooa
EOF
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.local/share/applications/chrome-ojdepafgebajpbdahdokdolkoekmbooa-Default.desktop"
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

log "Post-install complete."
