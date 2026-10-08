#!/bin/bash
# SDGVET OnlyOffice + Canon colour printing fix
#
#   sudo bash fix-onlyoffice-canon-color.sh            # apply (the default)
#   sudo bash fix-onlyoffice-canon-color.sh status     # report only
#   sudo bash fix-onlyoffice-canon-color.sh revert     # take the option back out
#
# Mode is the first argument, or OO_COLOR_MODE= when pasted through
# run-from-repo.sh. Run as root.
#
# THE PROBLEM: OnlyOffice Desktop Editors locks its print panel to black and
# white on the Canon colour laser, while every other program prints in colour.
#
# OnlyOffice decides "this printer does colour" by looking for the standard
# PPD option ColorModel. Canon's UFR II driver does not have one -- it uses its
# own CNColorMode instead -- so OnlyOffice concludes the printer is mono, even
# though the PPD says ColorDevice: True. It then saves that verdict in a
# per-user printers.cache and never asks again, so fixing the PPD alone
# changes nothing until that file is gone.
#
# WHAT THIS DOES:
#   1. Every CUPS queue whose PPD is a colour Canon one (ColorDevice: True and
#      a CNColorMode option) but has no ColorModel gets a small ColorModel
#      option added (RGB / Gray, default RGB), re-installed with lpadmin. The
#      Canon filter ignores ColorModel; it is only there for OnlyOffice to
#      find. The untouched PPD is kept in $BACKUP_DIR.
#   2. Every user's OnlyOffice printers.cache older than the fixed PPD is
#      deleted (Flatpak, .deb and snap locations). OnlyOffice rebuilds it on
#      its next start.
#
# Users must fully quit and reopen OnlyOffice afterwards -- a running copy
# keeps the old answer in memory. This script does not close it for them.
#
# Safe to re-run: a queue that already has ColorModel is left alone, and a
# cache newer than the PPD is left alone. Queues are found by what their PPD
# contains, not by name, so it does not matter what each PC called the Canon.
#
# A driver reinstall or re-adding the printer puts the stock PPD back; run
# this again if the lock comes back.
#
# Exit codes: 0 ok (including "nothing to do"), 1 a queue could not be fixed,
#             2 not run as root / bad mode.

set -uo pipefail

PPD_DIR="${PPD_DIR:-/etc/cups/ppd}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/onlyoffice-canon-color}"

MARK_BEGIN='*% BEGIN fix-onlyoffice-canon-color.sh'
MARK_END='*% END fix-onlyoffice-canon-color.sh'

# printers.cache, relative to a home directory: Flatpak, .deb, snap.
CACHE_RELS=(
    ".var/app/org.onlyoffice.desktopeditors/data/onlyoffice/desktopeditors/printers.cache"
    ".local/share/onlyoffice/desktopeditors/printers.cache"
    "snap/onlyoffice-desktopeditors/current/.local/share/onlyoffice/desktopeditors/printers.cache"
)

MODE="${1:-${OO_COLOR_MODE:-apply}}"
case "$MODE" in
    apply|status|revert) ;;
    *) echo "ERROR: unknown mode '$MODE' (use apply, status, revert)" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (the PPDs in $PPD_DIR are not readable otherwise)" >&2
    exit 2
fi

echo "=== fix-onlyoffice-canon-color ($MODE) on $(hostname) : $(date -Is) ==="

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

is_color_canon() { grep -q '^\*ColorDevice:[[:space:]]*True' "$1" && grep -q '^\*OpenUI \*CNColorMode' "$1"; }
has_colormodel() { grep -q '^\*OpenUI \*ColorModel' "$1"; }
has_our_block()  { grep -qF "$MARK_BEGIN" "$1"; }

# Insert the ColorModel option right after Canon's own colour option.
add_colormodel() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        { print }
        /^\*CloseUI:[[:space:]]*\*CNColorMode/ && !done {
            print b
            print "*OpenUI *ColorModel/Color Model: PickOne"
            print "*OrderDependency: 10 AnySetup *ColorModel"
            print "*DefaultColorModel: RGB"
            print "*ColorModel RGB/Color: \"\""
            print "*ColorModel Gray/Grayscale: \"\""
            print "*CloseUI: *ColorModel"
            print e
            done = 1
        }' "$1"
}

remove_colormodel() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        index($0, b) == 1 { skip = 1; next }
        index($0, e) == 1 { skip = 0; next }
        !skip { print }' "$1"
}

failed=0
fixed_ppds=()      # PPDs that carry a ColorModel a cache may predate

shopt -s nullglob
ppds=("$PPD_DIR"/*.ppd)
[ ${#ppds[@]} -eq 0 ] && echo "No CUPS queues with a PPD in $PPD_DIR."

for ppd in "${ppds[@]}"; do
    queue="$(basename "$ppd" .ppd)"
    if ! is_color_canon "$ppd"; then
        echo "  $queue: not a colour Canon PPD, skipping"
        continue
    fi

    case "$MODE" in
    status)
        if has_our_block "$ppd"; then
            echo "  $queue: FIXED (ColorModel added by this script)"
        elif has_colormodel "$ppd"; then
            echo "  $queue: ok (PPD has its own ColorModel)"
        else
            echo "  $queue: NEEDS FIX (no ColorModel -- OnlyOffice will lock to black and white)"
        fi
        ;;

    apply)
        if has_colormodel "$ppd"; then
            echo "  $queue: already has ColorModel, nothing to do"
            fixed_ppds+=("$ppd")
            continue
        fi
        new="$WORKDIR/$queue.ppd"
        add_colormodel "$ppd" > "$new"
        if ! has_colormodel "$new"; then
            echo "  $queue: ERROR could not find where to add ColorModel, PPD left alone" >&2
            failed=1; continue
        fi
        mkdir -p "$BACKUP_DIR"
        [ -e "$BACKUP_DIR/$queue.ppd.orig" ] || cp -p "$ppd" "$BACKUP_DIR/$queue.ppd.orig"
        if lpadmin -p "$queue" -P "$new"; then
            echo "  $queue: ColorModel added (original kept in $BACKUP_DIR/$queue.ppd.orig)"
            fixed_ppds+=("$ppd")
        else
            echo "  $queue: ERROR lpadmin refused the patched PPD, queue unchanged" >&2
            failed=1
        fi
        ;;

    revert)
        if ! has_our_block "$ppd"; then
            echo "  $queue: no ColorModel from this script, nothing to revert"
            continue
        fi
        new="$WORKDIR/$queue.ppd"
        remove_colormodel "$ppd" > "$new"
        if lpadmin -p "$queue" -P "$new"; then
            echo "  $queue: ColorModel removed"
            fixed_ppds+=("$ppd")     # caches now hold a stale 'colour' verdict
        else
            echo "  $queue: ERROR lpadmin refused the reverted PPD, queue unchanged" >&2
            failed=1
        fi
        ;;
    esac
done

# --- OnlyOffice's saved verdict ----------------------------------------------

# A cache written before the PPD changed still holds the old answer. One
# written after it is already correct, which is what keeps re-runs quiet.
cache_is_stale() {
    local cache="$1" ppd
    for ppd in "${fixed_ppds[@]}"; do
        [ "$cache" -ot "$ppd" ] && return 0
    done
    return 1
}

while IFS=: read -r user _ uid _ _ home _; do
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] && [ -d "$home" ] || continue
    for rel in "${CACHE_RELS[@]}"; do
        cache="$home/$rel"
        [ -f "$cache" ] || continue
        if [ "$MODE" = status ]; then
            echo "  $user: has $cache ($(date -r "$cache" '+%F %T'))"
        elif [ ${#fixed_ppds[@]} -gt 0 ] && cache_is_stale "$cache"; then
            rm -f "$cache" && echo "  $user: removed stale $cache"
        fi
    done
done < <(getent passwd)

if [ "$MODE" != status ] && [ ${#fixed_ppds[@]} -gt 0 ] && pgrep -f 'desktopeditors/DesktopEditors' >/dev/null; then
    echo "NOTE: OnlyOffice is running on this PC -- it must be fully quit and reopened to pick up the change."
fi

[ "$failed" -eq 0 ] && echo "Done." || echo "Finished with errors."
exit "$failed"
