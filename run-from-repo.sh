#!/bin/bash
# SDGVET Tech-Repo runner — fetch a script from GitHub and run it
#
# Paste THIS file into Landscape as a stored script (interpreter /bin/bash,
# run as root) and change only the SCRIPT= line below. From then on the real
# script is edited in your code editor and pushed to GitHub, and the next
# Landscape run picks it up — no more editing script bodies in the Landscape
# UI, and no more wondering which machine got which version.
#
# Also fine to run by hand:
#     sudo bash run-from-repo.sh                       # runs $SCRIPT below
#     sudo bash run-from-repo.sh install-dymo-printer.sh --test
#     DRY_RUN=1 bash run-from-repo.sh                  # fetch + verify only
#
# Exits with the fetched script's own exit code, so a failure shows up as a
# failed activity in Landscape rather than a silent success.

set -u

# ── Edit this line (or pass the name as the first argument) ─────────────────
SCRIPT="${1:-install-dymo-printer.sh}"
[ $# -gt 0 ] && shift

BRANCH="${BRANCH:-main}"
REPO_RAW="https://raw.githubusercontent.com/SDGVET/Tech-Repo"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TARGET="$WORKDIR/$(basename "$SCRIPT")"

log() { echo "[$(date '+%F %T')] run-from-repo: $*"; }

# raw.githubusercontent.com sits behind a CDN that caches for a few minutes,
# which is exactly long enough to push a fix, re-run in Landscape, and get the
# old file back. The cache-buster and no-cache header avoid that.
URL="${REPO_RAW}/${BRANCH}/${SCRIPT}?cb=$(date +%s)"

log "fetching ${SCRIPT} from ${BRANCH}..."
if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 60 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        -o "$TARGET" "$URL"; then
    log "ERROR: could not fetch ${SCRIPT} (branch ${BRANCH}). Check the name and that it is pushed."
    exit 1
fi

# A 404 from a private/renamed path can still land as a small HTML body, and
# an empty file would 'run' successfully and report a false green. Check we
# actually got a script before executing anything.
if [ ! -s "$TARGET" ]; then
    log "ERROR: fetched an empty file — refusing to run it."
    exit 1
fi
if ! head -c2 "$TARGET" | grep -q '#!'; then
    log "ERROR: fetched file does not start with a shebang — refusing to run it."
    log "First line was: $(head -n1 "$TARGET")"
    exit 1
fi

# Print what we are about to run, so the Landscape activity output records the
# exact version each machine received.
log "got $(wc -c < "$TARGET") bytes, sha256 $(sha256sum "$TARGET" | cut -c1-16)..."

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 — fetched and verified, not executing."
    exit 0
fi

log "running: ${SCRIPT} $*"
echo "────────────────────────────────────────────────────────────"
bash "$TARGET" "$@"
RC=$?
echo "────────────────────────────────────────────────────────────"
log "${SCRIPT} exited ${RC}"
exit $RC
