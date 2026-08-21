#!/bin/bash
# SDGVET DYMO LabelWriter 450 Turbo installer
#
#   sudo bash install-dymo-printer.sh            # install the queue
#   sudo bash install-dymo-printer.sh --test     # ...and print a test label
#   sudo bash install-dymo-printer.sh --no-hook  # skip the hotplug hook
#   sudo bash install-dymo-printer.sh --rebind   # (used by the hotplug hook)
#
# THE PRINTER DOES NOT NEED TO BE ATTACHED. Ours lives in a truck and is only
# occasionally plugged in, so this script always creates the queue up front and
# leaves it waiting for the hardware. What happens after that is handled by
# CUPS and udev, no tech required:
#   plugged in  -> udev-configure-printer finds our queue by device URI and
#                  re-enables it (it matches even if the unit reports a USB
#                  serial that our URI does not, so no duplicate is created)
#   unplugged   -> the same helper pauses the queue, reason "Unplugged or
#                  turned off". Normal. It comes back on the next plug-in.
#   printed to
#   while away  -> the usb backend reports "Waiting for printer to become
#                  available" and Ubuntu's packaged `ErrorPolicy retry-job`
#                  keeps the job queued instead of killing the queue.
#
# Reproduces the known-good setup from the admin workstation:
#   driver  : printer-driver-dymo (Ubuntu package)  ->  lw450t.ppd
#   queue   : LabelWriter-450-Turbo  on usb://DYMO/LabelWriter%20450%20Turbo
#   default : w154h198  = 2-1/8" x 2-3/4" Diskette label (30258 / 30324)
#             NOT the PPD's stock default of w167h288 (30256 shipping) --
#             that is the one thing you must set by hand, and the reason
#             this script exists.
#
# Idempotent; safe to re-run at any time.
# Safe for the public Tech-Repo -- no credentials in here.

set -u

QUEUE="LabelWriter-450-Turbo"
PPD_MODEL="dymo:0/cups/model/lw450t.ppd"
LABEL_SIZE="w154h198"          # 2-1/8" x 2-3/4"  (30258 / 30324 Diskette)
DESC="DYMO LabelWriter 450 Turbo"

# The URI CUPS reports for this model. The 450 Turbo does not expose a USB
# serial number, so this string is the same on every unit and every machine --
# which is what lets us create the queue before the printer is ever plugged in.
# If a unit ever does report a serial, the hotplug hook re-points the queue at
# the real URI (see --rebind below).
CANONICAL_URI='usb://DYMO/LabelWriter%20450%20Turbo'

SELF="/usr/local/bin/sdgvet-install-dymo.sh"
HOOK_UNIT="/etc/systemd/system/sdgvet-dymo-hotplug.service"
HOOK_RULE="/etc/udev/rules.d/99-sdgvet-dymo.rules"

MODE="install"; DO_TEST=0; DO_HOOK=1
for a in "$@"; do
    case "$a" in
        --rebind)  MODE="rebind"; DO_HOOK=0 ;;
        --test)    DO_TEST=1 ;;
        --no-hook) DO_HOOK=0 ;;
        *) echo "unknown option: $a"; exit 2 ;;
    esac
done

log() { echo "[$(date '+%F %T')] dymo: $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run this with sudo."; exit 1; }

# ---- 1. Driver -------------------------------------------------------------
# printer-driver-dymo ships raster2dymolw plus the lw450t PPD that CUPS serves
# from the dymo: scheme. It is in the autoinstall package list, but install it
# here too so a hand-run on any machine works.
if [ "$MODE" = "install" ] && ! dpkg -s printer-driver-dymo >/dev/null 2>&1; then
    log "installing printer-driver-dymo..."
    apt-get install -y printer-driver-dymo || { log "ERROR: driver install failed"; exit 1; }
fi

systemctl is-active --quiet cups || systemctl start cups

# ---- 2. Look for the printer (absence is fine) -----------------------------
# Match on the vendor prefix rather than the full URI, so a unit that does
# report a serial still gets found. On a hotplug we may beat CUPS to the
# device, so retry briefly.
find_uri() { lpinfo -v 2>/dev/null | awk '/usb:\/\/DYMO\//{print $2}' | head -n1; }

URI="$(find_uri)"
if [ -z "$URI" ] && [ "$MODE" = "rebind" ]; then
    for _ in 1 2 3 4 5; do sleep 2; URI="$(find_uri)"; [ -n "$URI" ] && break; done
fi

if [ -n "$URI" ]; then
    log "printer is attached: $URI"
    ATTACHED=1
else
    URI="$CANONICAL_URI"
    log "printer not attached -- creating the queue anyway, pointed at $URI"
    ATTACHED=0
fi

# ---- 3. Clear CUPS auto-created duplicates ---------------------------------
# A duplicate is what puts the wrong label size in front of users: it carries
# the PPD's stock 30256 shipping default, and it is the one they pick in the
# print dialog. Remove only exact numeric-suffix duplicates of our queue;
# anything else is left alone and just reported.
for P in $(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\):.*/\1/p'); do
    [ "$P" = "$QUEUE" ] && continue
    lpstat -v "$P" 2>/dev/null | grep -q 'usb://DYMO/' || continue
    if [[ "$P" =~ ^${QUEUE}-[0-9]+$ ]]; then
        log "removing duplicate auto-created queue: $P"
        lpadmin -x "$P" 2>/dev/null || true
    else
        log "NOTE: other DYMO queue '$P' left in place (remove by hand if unwanted)"
    fi
done

# ---- 4. Create / update the queue ------------------------------------------
log "configuring queue '$QUEUE'..."
lpadmin -p "$QUEUE" -E \
    -v "$URI" \
    -m "$PPD_MODEL" \
    -D "$DESC" \
    -o "PageSize=${LABEL_SIZE}" \
    -o Resolution=300dpi \
    -o DymoPrintQuality=Text \
    -o DymoPrintDensity=Normal \
    -o DymoHalftoning=ErrorDiffusion \
    || { log "ERROR: lpadmin failed"; exit 1; }

# Only un-pause the queue when the hardware is actually here. While the printer
# is out in the truck, udev has paused it on purpose ("Unplugged or turned
# off") and forcing it back on would just hide that from users.
if [ "$ATTACHED" -eq 1 ]; then
    cupsenable "$QUEUE" 2>/dev/null || true
fi
cupsaccept "$QUEUE" 2>/dev/null || true

# ---- 5. Hotplug hook -------------------------------------------------------
# Ubuntu's own helper re-enables the queue on plug-in, which covers the normal
# case. This hook covers the one thing it does not do: if a unit turns up
# reporting a USB serial, our queue URI would no longer point at it, so we
# re-run in --rebind mode on plug-in and re-point the queue at the real URI.
if [ "$DO_HOOK" -eq 1 ]; then
    log "installing hotplug hook..."

    # Keep a copy at a stable path so the udev unit does not depend on wherever
    # this script happened to be run from.
    if [ "$(readlink -f "$0")" != "$SELF" ]; then
        install -m 755 "$0" "$SELF"
    fi

    cat > "$HOOK_UNIT" <<EOF
[Unit]
Description=SDGVET: re-bind the DYMO LabelWriter to its CUPS queue on hotplug
After=cups.service
Wants=cups.service

[Service]
Type=oneshot
ExecStart=$SELF --rebind
EOF

    # 0922 is DYMO's USB vendor ID. Mirrors the pattern Ubuntu's own
    # 70-printers.rules uses: hand off to systemd rather than running the work
    # inside udev, which kills long-running RUN+= children.
    cat > "$HOOK_RULE" <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0922", TAG+="systemd", ENV{SYSTEMD_WANTS}="sdgvet-dymo-hotplug.service"
EOF

    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
fi

# ---- 6. Verify -------------------------------------------------------------
echo
log "--- resulting configuration ---"
lpstat -v "$QUEUE"
lpstat -p "$QUEUE"
lpoptions -p "$QUEUE" -l | grep -E '^(PageSize|Resolution|DymoPrint)'
echo

ACTUAL="$(lpoptions -p "$QUEUE" -l | sed -n 's/^PageSize[^:]*:.*\*\([A-Za-z0-9_.]*\).*/\1/p')"
if [ "$ACTUAL" = "$LABEL_SIZE" ]; then
    log "OK: default label size is $LABEL_SIZE (2-1/8\" x 2-3/4\")"
else
    log "WARNING: default label size is '$ACTUAL', expected '$LABEL_SIZE'"
fi

if [ "$ATTACHED" -eq 0 ]; then
    log "Queue is installed and waiting. Plug the printer in and it comes up on"
    log "its own -- no need to re-run this."
fi

# ---- 7. Optional test label ------------------------------------------------
if [ "$DO_TEST" -eq 1 ]; then
    if [ "$ATTACHED" -eq 0 ]; then
        log "NOTE: printer is not attached -- the test label will sit in the"
        log "queue and print when it is next plugged in."
    fi
    log "sending test label..."
    printf 'SDGVET\nDYMO test label\n%s\n' "$(date '+%F %T')" \
        | lp -d "$QUEUE" -t "dymo-test" - >/dev/null \
        && log "test label queued." \
        || log "ERROR: test label failed to queue."
fi

log "done."
