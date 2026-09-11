#!/usr/bin/env bash
# Disable the KDE Plasma desktop zoom (magnifier) fleet-wide.
# Run as root in Landscape.
#
# What it does:
#   Turns off the KWin "Zoom" effect via the system-wide default in
#   /etc/xdg/kwinrc. With the effect unloaded, KWin no longer registers
#   its keyboard shortcuts (Meta++ / Meta+- / Meta+0, Meta+scroll) or its
#   touchpad pinch gesture, so all of them stop working.
#
# Enforcement level: DEFAULT OFF, user-overridable.
#   Per-user ~/.config/kwinrc is not touched, and no [$i] immutable markers
#   are written, so a user can still re-enable it in
#   System Settings > Desktop Effects > Accessibility > Zoom.
#   To lock it instead, run with --lock (writes zoomEnabled[$i]=false).
#
# Usage:
#   disable-plasma-zoom.sh            # disable (default)
#   disable-plasma-zoom.sh --lock     # disable and make it immutable
#   disable-plasma-zoom.sh --enable   # revert: restore the stock default
#   disable-plasma-zoom.sh --status   # report only, change nothing

set -euo pipefail

CONF="${KWINRC:-/etc/xdg/kwinrc}"
GROUP="Plugins"
KEY="zoomEnabled"
LOG="${ZOOMLOG:-/var/log/disable-plasma-zoom.log}"

MODE="disable"
case "${1:-}" in
    ""|--disable) MODE="disable" ;;
    --lock)       MODE="lock" ;;
    --enable)     MODE="enable" ;;
    --status)     MODE="status" ;;
    *) echo "ERROR: unknown option '$1' (use --lock, --enable, --status)" >&2; exit 2 ;;
esac

exec > >(tee -a "$LOG") 2>&1
echo "=== disable-plasma-zoom ($MODE) : $(date -Is) ==="

# --- 0. Only act on Plasma hosts; a mixed fleet should not fail here -------
if ! command -v kwin_wayland >/dev/null 2>&1 && ! command -v kwin_x11 >/dev/null 2>&1; then
    echo "KWin not installed - not a Plasma host. Nothing to do."
    exit 0
fi

# --- helpers ---------------------------------------------------------------

# kde_get <file> <group> <key>  -> prints "key=value" line if present
kde_get() {
    local file="$1" group="$2" key="$3"
    [ -f "$file" ] || return 0
    awk -v g="[$group]" -v kre="^[ \t]*$key(\\\\[\\\\\$i\\\\])?[ \t]*=" '
        /^[ \t]*\[/ { ing = ($0 == g); next }
        ing && $0 ~ kre { print; exit }
    ' "$file"
}

# kde_set <file> <group> <key> <value>   (idempotent, preserves the rest)
kde_set() {
    local file="$1" group="$2" key="$3" val="$4" tmp
    [ -f "$file" ] || { install -d -m 755 "$(dirname "$file")"; : > "$file"; }
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v g="[$group]" -v out="$key=$val" \
        -v kre="^[ \t]*${key%%\[*}(\\\\[\\\\\$i\\\\])?[ \t]*=" '
        BEGIN { ing = 0; done = 0; nb = 0 }
        function flush(  i) { for (i = 1; i <= nb; i++) print buf[i]; nb = 0 }
        /^[ \t]*\[/ {
            if (ing && !done) { print out; done = 1 }
            flush(); ing = ($0 == g); print; next
        }
        ing && $0 ~ kre { flush(); if (!done) { print out; done = 1 } next }
        ing && /^[ \t]*$/ { buf[++nb] = $0; next }
        { flush(); print }
        END {
            if (!done) {
                if (!ing && NR > 0) print ""
                if (!ing) print g
                print out
            }
            flush()
        }
    ' "$file" > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$file"
}

# kde_unset <file> <group> <key>  (drops the key, leaves the stock default)
kde_unset() {
    local file="$1" group="$2" key="$3" tmp
    [ -f "$file" ] || return 0
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v g="[$group]" -v kre="^[ \t]*$key(\\\\[\\\\\$i\\\\])?[ \t]*=" '
        /^[ \t]*\[/ { ing = ($0 == g); print; next }
        ing && $0 ~ kre { next }
        { print }
    ' "$file" > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$file"
}

# --- 1. Apply the setting --------------------------------------------------
case "$MODE" in
    status)
        line="$(kde_get "$CONF" "$GROUP" "$KEY")"
        echo "System default in $CONF: ${line:-<unset - stock default, zoom ENABLED>}"
        for home in /home/*; do
            u="$(basename "$home")"
            ul="$(kde_get "$home/.config/kwinrc" "$GROUP" "$KEY")"
            [ -n "$ul" ] && echo "  user override: $u -> $ul"
        done
        exit 0
        ;;
    disable)
        kde_unset "$CONF" "$GROUP" "$KEY"          # clear any prior [$i] form
        kde_set   "$CONF" "$GROUP" "$KEY" "false"
        echo "Set $CONF [$GROUP] $KEY=false"
        ;;
    lock)
        kde_unset "$CONF" "$GROUP" "$KEY"
        kde_set   "$CONF" "$GROUP" "${KEY}[\$i]" "false"
        echo "Set $CONF [$GROUP] ${KEY}[\$i]=false (immutable)"
        ;;
    enable)
        kde_unset "$CONF" "$GROUP" "$KEY"
        echo "Removed $KEY from $CONF - stock default (zoom on) restored"
        ;;
esac

# --- 2. Report users whose own kwinrc overrides the system default ----------
# In --disable mode these users keep zoom until they change it themselves.
for home in /home/*; do
    [ -d "$home" ] || continue
    ul="$(kde_get "$home/.config/kwinrc" "$GROUP" "$KEY")"
    if [ -n "$ul" ]; then
        echo "NOTE: $(basename "$home") has a personal override: $ul"
    fi
done

# --- 3. Apply live to logged-in Plasma sessions (no logout needed) ----------
# Note: org.kde.KWin.reconfigure only re-reads settings - it does not load or
# unload effect plugins. The Desktop Effects KCM writes the config and then
# calls loadEffect/unloadEffect explicitly, so we do the same.

kwin_dbus() {   # uid user object interface.method [args...]
    local uid="$1" user="$2"; shift 2
    runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        dbus-send --session --type=method_call --dest=org.kde.KWin \
                  "$@" >/dev/null 2>&1
}

applied=0
while read -r uid user; do
    [ -n "${uid:-}" ] || continue
    [ -S "/run/user/$uid/bus" ] || continue

    # No KWin on this bus (tty/ssh session, or a non-Plasma desktop) - skip.
    kwin_dbus "$uid" "$user" /KWin org.kde.KWin.reconfigure || continue

    if [ "$MODE" = "enable" ]; then
        kwin_dbus "$uid" "$user" /Effects org.kde.kwin.Effects.loadEffect \
                  string:zoom || true
        echo "Live session $user (uid $uid): config reloaded, zoom effect loaded"
        applied=$((applied + 1))
        continue
    fi

    # Respect a personal override in --disable mode: that user chose zoom on,
    # and unloading it here would only last until their next reconfigure.
    uhome="$(getent passwd "$user" | cut -d: -f6)"
    uov="$(kde_get "${uhome:-/nonexistent}/.config/kwinrc" "$GROUP" "$KEY")"
    if [ "$MODE" = "disable" ] && [ "${uov#*=}" = "true" ]; then
        echo "Live session $user (uid $uid): config reloaded, zoom left ON (personal override)"
        applied=$((applied + 1))
        continue
    fi

    kwin_dbus "$uid" "$user" /Effects org.kde.kwin.Effects.unloadEffect \
              string:zoom || true
    echo "Live session $user (uid $uid): config reloaded, zoom effect unloaded"
    applied=$((applied + 1))
done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $2, $3}' | sort -u)
echo "Live sessions updated: $applied (others pick it up at next login)"

# --- 4. Verification -------------------------------------------------------
echo "--- $CONF [$GROUP] ---"
kde_get "$CONF" "$GROUP" "$KEY" || true
while read -r uid user; do
    [ -n "${uid:-}" ] || continue
    [ -S "/run/user/$uid/bus" ] || continue
    st="$(runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            dbus-send --session --print-reply --dest=org.kde.KWin /Effects \
                      org.kde.kwin.Effects.isEffectLoaded string:zoom \
            2>/dev/null | awk '/boolean/{print $2}')"
    [ -n "$st" ] && echo "live: zoom effect loaded for $user = $st"
done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $2, $3}' | sort -u)
echo "=== Done: $(date -Is) ==="
exit 0
