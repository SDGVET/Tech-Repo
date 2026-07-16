#!/bin/bash
#
# chrome-wayland-click-fix.sh
#
# Works around a Chromium bug on KDE Plasma 6 / Wayland with fractional
# display scaling, where buttons in Chrome's own dialogs (notably the
# Print button in print preview) only respond to a press-and-hold click.
#
# Fix: divert Google Chrome's launcher script with dpkg-divert and install
# a wrapper that adds --disable-features=WaylandPerSurfaceScale,WaylandUiScale
# on Wayland sessions only. X11 sessions are unaffected. The diversion
# survives Chrome package updates and covers all launch paths (browser
# icon, terminal, and PWA/web-app launchers).
#
# Usage:
#   chrome-wayland-click-fix.sh            # install (default)
#   chrome-wayland-click-fix.sh remove     # undo everything
#
# Idempotent: safe to run repeatedly (e.g. as a recurring Landscape script).
# Takes effect the next time Chrome is fully restarted.

set -euo pipefail

CHROME_DIR=/opt/google/chrome
LAUNCHER="$CHROME_DIR/google-chrome"
REAL="$CHROME_DIR/google-chrome.real"
MARKER="chrome-wayland-click-fix"
ACTION="${1:-install}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

is_installed() {
    [ -f "$LAUNCHER" ] && grep -q "$MARKER" "$LAUNCHER"
}

case "$ACTION" in
install)
    if ! dpkg -s google-chrome-stable >/dev/null 2>&1; then
        echo "google-chrome-stable not installed; nothing to do"
        exit 0
    fi
    if is_installed; then
        echo "already installed; nothing to do"
        exit 0
    fi

    dpkg-divert --add --rename --divert "$REAL" "$LAUNCHER"

    cat > "$LAUNCHER" <<EOF
#!/bin/bash
# $MARKER
# Managed wrapper (deployed via Landscape) — do not edit by hand.
# Disables Chromium's per-surface Wayland scaling, which breaks quick
# clicks in Chrome dialogs under Plasma 6 with fractional scaling.
# The real launcher was diverted to google-chrome.real by dpkg-divert.
FLAGS=()
if [ "\${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "\${WAYLAND_DISPLAY:-}" ]; then
    FLAGS+=(--disable-features=WaylandPerSurfaceScale,WaylandUiScale)
fi
exec "$REAL" "\${FLAGS[@]}" "\$@"
EOF
    chmod 755 "$LAUNCHER"
    echo "installed: $LAUNCHER now wraps $REAL"
    echo "restart Chrome for the fix to take effect"
    ;;

remove)
    if ! is_installed; then
        echo "wrapper not present; nothing to do"
        exit 0
    fi
    rm -f "$LAUNCHER"
    dpkg-divert --remove --rename --divert "$REAL" "$LAUNCHER"
    echo "removed: original launcher restored"
    ;;

*)
    echo "usage: $0 [install|remove]" >&2
    exit 2
    ;;
esac
