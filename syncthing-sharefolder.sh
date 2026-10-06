#!/usr/bin/env bash
# Move the shared LWVC folder from Nextcloud to Syncthing.
# Run as root in Landscape (setup / verify), or as yourself on the base PC (seed).
#
# What it does:
#   Gives every PC the same shared folder at ~/Documents/ShareFolder, synced by
#   Syncthing with the unraid box as the always-on hub. The Nextcloud client is
#   left installed and keeps syncing everything else; only the LWVC team folder
#   moves. See sharefolder-syncthing-plan.md for the whole cutover.
#
#   The old Nextcloud copy sits in a different place on every PC (each client
#   was pointed at a hand-picked folder), so it is located by reading the
#   client's own ~/.config/Nextcloud/nextcloud.cfg rather than guessed.
#
# Modes (first argument, or SHARE_MODE= when pasted through run-from-repo.sh):
#   status   Report only, change nothing. The default.
#   seed     Base PC only, as yourself: copy the Nextcloud LWVC folder to
#            ~/Documents/ShareFolder and offer it to the NAS.
#   setup    Install/start Syncthing for the PC's user, add the NAS and an
#            empty ~/Documents/ShareFolder, print the device ID to add on the NAS.
#   verify   Once the folder has synced: compare the old Nextcloud copy against
#            it. Anything that exists only in the old copy, or is newer there,
#            is copied to ~/Documents/ShareFolder-rescued-from-nextcloud.
#
# This script never deletes the old Nextcloud copy. Deleting it by hand while
# the client is still syncing would delete it on the server for everyone;
# removing the user's access on the server makes the client clean it up itself.
#
# Exit codes: 0 ok, 1 verify found unsynced files (rescued, needs a look),
#             2 not ready / misconfigured.
#
# NAS_ID is deliberately not stored here: this repo is public, and a device ID
# lets anyone look up the NAS's address through Syncthing's global discovery.
#
# Usage:
#   NAS_ID=XXXXXXX-... bash syncthing-sharefolder.sh seed
#   In the Landscape paste of run-from-repo.sh, above the SCRIPT= line:
#       export NAS_ID=XXXXXXX-... SHARE_MODE=setup      # then SHARE_MODE=verify

set -euo pipefail

FOLDER_ID="${FOLDER_ID:-lwvc-share}"
FOLDER_LABEL="${FOLDER_LABEL:-ShareFolder}"
SHARE_REL="${SHARE_REL:-Documents/ShareFolder}"
RESCUE_REL="${RESCUE_REL:-Documents/ShareFolder-rescued-from-nextcloud}"
NC_REMOTE="${NC_REMOTE:-/LWVC}"          # the folder's path on the Nextcloud server
NAS_ID="${NAS_ID:-}"
NAS_NAME="${NAS_NAME:-unraid-tower}"

MODE="${1:-${SHARE_MODE:-status}}"
case "$MODE" in
    status|seed|setup|verify) ;;
    *) echo "ERROR: unknown mode '$MODE' (use status, seed, setup, verify)" >&2; exit 2 ;;
esac

echo "=== syncthing-sharefolder ($MODE) on $(hostname) : $(date -Is) ==="

die() { echo "ERROR: $*" >&2; exit 2; }

# --- who are we acting for --------------------------------------------------

# As root (Landscape) the PC's user is whoever owns a Nextcloud client config.
# TARGET_USER= overrides, for a PC with more than one.
pick_user() {
    if [ "$(id -u)" -ne 0 ]; then id -un; return; fi
    if [ -n "${TARGET_USER:-}" ]; then echo "$TARGET_USER"; return; fi
    local cfg users=()
    for cfg in /home/*/.config/Nextcloud/nextcloud.cfg; do
        [ -f "$cfg" ] && users+=("$(stat -c %U "$cfg")")
    done
    case "${#users[@]}" in
        1) echo "${users[0]}" ;;
        0) die "no user with a Nextcloud client config under /home - set TARGET_USER=" ;;
        *) die "several users have a Nextcloud config (${users[*]}) - set TARGET_USER=" ;;
    esac
}

U="$(pick_user)"
HOME_U="$(getent passwd "$U" | cut -d: -f6)"
[ -d "$HOME_U" ] || die "no home directory for user '$U'"
SHARE="$HOME_U/$SHARE_REL"
RESCUE="$HOME_U/$RESCUE_REL"
echo "User: $U   Shared folder: $SHARE"

as_user() {
    if [ "$(id -u)" -eq 0 ]; then
        (cd / && sudo -H -u "$U" -- "$@")
    else
        "$@"
    fi
}
st() { as_user syncthing cli "$@"; }

# --- helpers ----------------------------------------------------------------

# Where this PC's Nextcloud client keeps LWVC. Prints nothing if it has none.
# The client may sync the whole account (LWVC is then a subfolder of its local
# path) or just the team folder (the local path is the folder itself).
find_old() {
    if [ -n "${OLD_DIR:-}" ]; then echo "$OLD_DIR"; return; fi
    local cfg="$HOME_U/.config/Nextcloud/nextcloud.cfg"
    [ -f "$cfg" ] || return 0
    python3 - "$cfg" "$NC_REMOTE" <<'PY'
import os, re, sys
cfg, remote = sys.argv[1], sys.argv[2].rstrip("/")
folders = {}
for line in open(cfg, encoding="utf-8", errors="replace"):
    m = re.match(r"^(\d+\\Folders\w*\\[^\\]+)\\(localPath|targetPath)=(.*)$", line.rstrip("\n"))
    if m:
        folders.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
for f in folders.values():
    local, target = f.get("localPath"), (f.get("targetPath") or "/").rstrip("/")
    if not local:
        continue
    if target == remote:
        cand = local
    elif remote.startswith(target + "/"):
        cand = os.path.join(local, remote[len(target):].lstrip("/"))
    else:
        continue
    if os.path.isdir(cand):
        print(os.path.normpath(cand))
        break
PY
}

st_running() { st show system >/dev/null 2>&1; }

start_syncthing() {
    if ! command -v syncthing >/dev/null 2>&1; then
        [ "$(id -u)" -eq 0 ] || die "syncthing is not installed (sudo apt install syncthing)"
        echo "Installing syncthing..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq syncthing curl
    fi
    if ! pgrep -u "$U" -x syncthing >/dev/null 2>&1; then
        # The system unit runs as the user from boot, so the folder syncs
        # whether or not anyone is logged in.
        if [ "$(id -u)" -eq 0 ]; then
            systemctl enable --now "syncthing@${U}.service"
        else
            systemctl --user enable --now syncthing.service
        fi
    fi
    local i
    for i in $(seq 1 60); do
        st_running && return 0
        sleep 1
    done
    die "syncthing did not come up for $U within 60s"
}

my_id() { st show system | python3 -c 'import json,sys; print(json.load(sys.stdin)["myID"])'; }

api() {
    local key addr scheme=http
    key="$(st config gui apikey get)"
    addr="$(st config gui raw-address get)"
    [ "$(st config gui raw-use-tls get)" = "true" ] && scheme=https
    curl -fsSk -H "X-API-Key: $key" "${scheme}://${addr}$1"
}

folder_configured() { st config folders list 2>/dev/null | grep -qxF "$FOLDER_ID"; }

# sync_state -> "state needItems globalFiles", e.g. "idle 0 228"
sync_state() {
    api "/rest/db/status?folder=${FOLDER_ID}" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(s["state"], s["needTotalItems"], s["globalFiles"])'
}

nas_connected() {
    [ -n "$NAS_ID" ] || { echo unknown; return; }
    api /rest/system/connections | NAS_ID="$NAS_ID" python3 -c '
import json, os, sys
c = json.load(sys.stdin)["connections"].get(os.environ["NAS_ID"])
print("yes" if c and c["connected"] else "no")'
}

add_nas_and_folder() {
    [ -n "$NAS_ID" ] || die "NAS_ID is not set (the unraid Syncthing device ID)"
    if ! st config devices list | grep -qxF "$NAS_ID"; then
        # Introducer: the NAS tells this PC about the other PCs sharing the
        # folder, so office machines sync directly with each other as well.
        st config devices add --device-id "$NAS_ID" --name "$NAS_NAME" --introducer
        echo "Added NAS device $NAS_NAME."
    fi
    if ! folder_configured; then
        as_user mkdir -p "$SHARE"
        st config folders add --id "$FOLDER_ID" --label "$FOLDER_LABEL" --path "$SHARE"
        echo "Added folder $FOLDER_ID at $SHARE."
    fi
    if ! st config folders "$FOLDER_ID" devices list | grep -qxF "$NAS_ID"; then
        st config folders "$FOLDER_ID" devices add --device-id "$NAS_ID"
        echo "Shared $FOLDER_ID with $NAS_NAME."
    fi
}

# compare <old> <new>: fills SAME, UNSYNCED[] and NEWER_IN_SHARE[].
# UNSYNCED is what would be lost with the old copy: files that exist only
# there, or that differ and are newer there. A file that differs but is newer
# in the shared folder was simply edited after the cutover.
compare() {
    local old="$1" new="$2" rel
    SAME=0; UNSYNCED=(); NEWER_IN_SHARE=()
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        if [ ! -e "$new/$rel" ]; then
            UNSYNCED+=("$rel")
        elif cmp -s "$old/$rel" "$new/$rel"; then
            SAME=$((SAME + 1))
        elif [ "$old/$rel" -nt "$new/$rel" ]; then
            UNSYNCED+=("$rel")
        else
            NEWER_IN_SHARE+=("$rel")
        fi
    done < <(cd "$old" && find . -type f \
                ! -name '.sync_*.db*' ! -name '._sync_*.db*' \
                ! -name '.nextcloudsync.log' ! -name '.owncloudsync.log' \
                ! -name '*.nextcloud' ! -name '.~lock.*#' -print0)
}

# --- modes ------------------------------------------------------------------

do_status() {
    local old
    old="$(find_old)"
    echo "Old Nextcloud copy: ${old:-none found}"
    if ! command -v syncthing >/dev/null 2>&1; then
        echo "Syncthing: not installed"
        return 0
    fi
    if ! st_running; then
        echo "Syncthing: installed, not running for $U"
        return 0
    fi
    echo "Syncthing: running, device ID $(my_id)"
    if folder_configured; then
        echo "Folder $FOLDER_ID: configured, state/need/global = $(sync_state), NAS connected: $(nas_connected)"
    else
        echo "Folder $FOLDER_ID: not configured"
    fi
}

do_seed() {
    [ "$(id -u)" -ne 0 ] || die "seed runs as yourself on the base PC, not as root"
    local old
    old="$(find_old)"
    [ -n "$old" ] || die "no Nextcloud copy of $NC_REMOTE found on this PC"
    start_syncthing
    if folder_configured; then
        echo "Folder $FOLDER_ID already exists here - not copying again."
    else
        if [ -d "$SHARE" ] && [ -n "$(ls -A "$SHARE")" ]; then
            die "$SHARE already exists and is not empty"
        fi
        mkdir -p "$SHARE"
        echo "Copying $old -> $SHARE"
        cp -a "$old/." "$SHARE/"
        compare "$old" "$SHARE"
        [ "${#UNSYNCED[@]}" -eq 0 ] && [ "${#NEWER_IN_SHARE[@]}" -eq 0 ] \
            || die "copy does not match the source - check $SHARE"
        echo "Copied and verified $SAME files."
    fi
    add_nas_and_folder
    echo
    echo "Next: in the NAS Syncthing GUI, accept the folder '$FOLDER_LABEL' ($FOLDER_ID)"
    echo "offered by $(hostname) and turn on Staggered File Versioning for it."
}

do_setup() {
    start_syncthing
    if ! folder_configured && [ -d "$SHARE" ] && [ -n "$(ls -A "$SHARE")" ]; then
        die "$SHARE already exists and is not empty - move it aside first"
    fi
    add_nas_and_folder
    echo
    echo "ADD ON NAS: $(my_id)   ($(hostname), user $U)"
    echo "Then share '$FOLDER_LABEL' with it, and run verify once it has synced."
}

do_verify() {
    command -v syncthing >/dev/null 2>&1 && st_running || die "syncthing is not running - run setup first"
    folder_configured || die "folder $FOLDER_ID is not configured - run setup first"

    # Comparing against a folder that has not finished arriving would flag
    # every file as unsynced, so insist on a completed, non-empty sync.
    local state need global
    read -r state need global <<<"$(sync_state)"
    if [ "$state" != "idle" ] || [ "$need" != "0" ] || [ "$global" = "0" ]; then
        echo "Not synced yet: state=$state, items still needed=$need, files known=$global," \
             "NAS connected: $(nas_connected)."
        echo "If files known is 0, the NAS has not shared the folder with this PC yet."
        exit 2
    fi
    echo "Shared folder is in sync ($global files)."

    local old
    old="$(find_old)"
    if [ -z "$old" ]; then
        echo "OK: no Nextcloud copy of $NC_REMOTE on this PC - nothing to compare."
        return 0
    fi
    echo "Comparing old copy $old"
    compare "$old" "$SHARE"
    echo "Identical: $SAME   Edited since in ShareFolder: ${#NEWER_IN_SHARE[@]}   Unsynced in old copy: ${#UNSYNCED[@]}"

    if [ "${#UNSYNCED[@]}" -eq 0 ]; then
        echo "OK: nothing would be lost. Safe to remove $U's Nextcloud access to $NC_REMOTE."
        return 0
    fi

    local rel
    echo "Rescuing to $RESCUE:"
    for rel in "${UNSYNCED[@]}"; do
        echo "  $rel"
        as_user mkdir -p "$RESCUE/$(dirname "$rel")"
        as_user cp -p "$old/$rel" "$RESCUE/$rel"
    done
    echo "These exist only in the old Nextcloud copy, or are newer there. Move the ones"
    echo "that matter into $SHARE, then remove $U's Nextcloud access to $NC_REMOTE."
    exit 1
}

"do_$MODE"
