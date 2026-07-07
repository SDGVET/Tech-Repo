#!/bin/bash
# TEST 2 -- re-enable the previously-disabled per-user items on a RUNNING machine
# to check for the first-login black screen. The SDDM and VetBadger fixes are
# NOT here (already proven and moved into the post-install script). No secrets.
#
# Run:  sudo bash test-fixes.sh
# Then LOG OUT and back in and watch whether the desktop comes up or goes black.
set -u

U=$(getent passwd 1000 | cut -d: -f1); H=$(getent passwd 1000 | cut -d: -f6)
if [ -z "$U" ] || [ -z "$H" ]; then echo "No UID 1000 user found"; exit 1; fi
echo "Applying per-user test items for $U ($H)"

echo "=== first-login helper: Breeze Dark + Honeywave + natural scroll + Nextcloud ==="
cat > /usr/local/bin/sdgvet-first-login-appearance.sh <<'HELPER'
#!/bin/bash
for i in $(seq 1 30); do pgrep -x plasmashell >/dev/null && break; sleep 2; done
sleep 3
plasma-apply-lookandfeel -a org.kde.breezedark.desktop
plasma-apply-wallpaperimage /usr/share/wallpapers/Honeywave
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
command -v nextcloud >/dev/null 2>&1 && nohup nextcloud >/dev/null 2>&1 &
HELPER
chmod 755 /usr/local/bin/sdgvet-first-login-appearance.sh

install -d -o "$U" -g "$U" "$H/.config/autostart"
cat > "$H/.config/autostart/sdgvet-appearance.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=SDGVET Appearance Defaults
Exec=sh -c '/usr/local/bin/sdgvet-first-login-appearance.sh; rm -f "$HOME/.config/autostart/sdgvet-appearance.desktop"'
X-KDE-autostart-phase=2
NoDisplay=true
DESK
chown "$U:$U" "$H/.config/autostart/sdgvet-appearance.desktop"

echo "=== power profiles (powerdevilrc) ==="
cat > "$H/.config/powerdevilrc" <<'PWR'
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
PWR
chown "$U:$U" "$H/.config/powerdevilrc"

echo "=== screen auto-lock OFF (kscreenlockerrc) ==="
cat > "$H/.config/kscreenlockerrc" <<'LOCK'
[Daemon]
Autolock=false
LockGrace=300
LockOnResume=false
Timeout=0
LOCK
chown "$U:$U" "$H/.config/kscreenlockerrc"

echo
echo "=== DONE -- now LOG OUT and back in ==="
echo "On next login the helper applies Breeze Dark + Honeywave wallpaper +"
echo "natural scroll and launches Nextcloud. Watch the desktop:"
echo "  Desktop OK    -> theming/power/lock are safe (black screen was the"
echo "                   now-removed taskbar pinning)."
echo "  Black screen  -> one of these is the culprit; we bisect next."
