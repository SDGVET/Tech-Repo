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

# Optional extras — uncomment if employees should get these:
# flatpak install -y --noninteractive --system flathub me.proton.Pass   # password manager
# flatpak install -y --noninteractive --system flathub me.proton.Mail   # email client

log "Post-install complete."
