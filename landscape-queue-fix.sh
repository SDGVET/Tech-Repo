#!/bin/bash
#
# landscape-queue-fix.sh
#
# Fixes the Landscape client message backlog that stalls script and update
# delivery across the fleet.
#
# Cause: the monitor's ActiveProcessInfo plugin queues ~23 KB messages (the
# full process table) on every snapshot — on a KDE workstation that is ~43%
# of the message store by volume. The store is a strict ordered sequence, so
# one message the server won't accept blocks every message behind it while
# new telemetry piles up at ~12 per 15-minute exchange. Activities then sit
# at "Queued" in the dashboard because the client's result messages are stuck
# behind the block.
#
# The signature in /var/log/landscape/broker.log is a byte-identical payload
# being re-sent while "Pending messages remaining" climbs:
#
#   09:48:21  Sent 304001 bytes ... received 236 bytes   Pending: 105
#   10:03:22  Sent 304001 bytes ... received 236 bytes   Pending: 117
#
# This script:
#   1. pins monitor_plugins in /etc/landscape/client.conf, dropping
#      ActiveProcessInfo (the bulk of the payload) plus SwiftUsage and
#      CephUsage (OpenStack plugins that log "0 of N expected" noise and do
#      nothing on a workstation);
#   2. clears the message store if the backlog is at or over the threshold;
#   3. restarts landscape-client.
#
# Registration is preserved — the computer ID and secure ID live in
# broker.bpickle, which is never touched. Queued telemetry is discarded (a
# gap in the graphs); the machine's enrollment is not affected.
#
# Usage:
#   landscape-queue-fix.sh                 # apply; restart detached (Landscape-safe)
#   landscape-queue-fix.sh --now           # apply; restart inline (SSH / by hand)
#   landscape-queue-fix.sh status          # report only, change nothing
#   landscape-queue-fix.sh revert          # restore monitor_plugins = ALL
#
# Options:
#   --threshold N     reset the store at N+ queued messages (default 50)
#   --force-reset     reset the store regardless of backlog size
#   --fix-ping-url    also rewrite a plain-HTTP ping_url to HTTPS (see below)
#
# IMPORTANT when run from Landscape: restarting landscape-client kills the
# manager process running this script, so the result would never reach the
# dashboard. The default path therefore hands the disruptive work to a
# detached systemd transient unit that fires ~20s after this script exits,
# letting the result report first. Use --now only over SSH or at the console.
#
# --fix-ping-url is opt-in and unrelated to the backlog. The client's default
# ping_url is plain HTTP (http://landscape.canonical.com/ping) and our
# firewall blocks outbound port 80, which silently costs a machine the
# fast-dispatch path and drops it to the 15-minute exchange interval. Only
# useful on machines that never registered with an HTTPS ping URL.
#
# Idempotent: safe to run repeatedly, e.g. as a recurring Landscape script.

set -euo pipefail

CONF=/etc/landscape/client.conf
CLIENT_DIR=/var/lib/landscape/client
MSG_DIR="$CLIENT_DIR/messages"
BROKER_LOG=/var/log/landscape/broker.log
RESET_HELPER=/usr/local/sbin/landscape-queue-reset.sh
RESET_UNIT=landscape-queue-reset
STAMP=$(date +%F-%H%M%S)

# Every ALL_PLUGINS entry from landscape/client/monitor/config.py except
# ActiveProcessInfo, SwiftUsage and CephUsage. PackageMonitor and
# UpdateManager are kept — update management depends on them.
PLUGINS="ComputerInfo, LoadAverage, MemoryInfo, MountInfo, ProcessorInfo, Temperature, PackageMonitor, UserMonitor, RebootRequired, AptPreferences, NetworkActivity, NetworkDevice, UpdateManager, CPUUsage, ComputerTags, SnapServicesMonitor, CloudInit"

PING_URL_HTTPS="https://landscape.canonical.com/ping"

ACTION=apply
RESTART_MODE=detached
THRESHOLD=50
FORCE_RESET=0
FIX_PING=0

while [ $# -gt 0 ]; do
    case "$1" in
    apply | status | revert) ACTION=$1 ;;
    --now) RESTART_MODE=inline ;;
    --force-reset) FORCE_RESET=1 ;;
    --fix-ping-url) FIX_PING=1 ;;
    --threshold)
        THRESHOLD=${2:?--threshold needs a number}
        shift
        ;;
    -h | --help)
        sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown argument: $1" >&2
        echo "usage: $0 [apply|status|revert] [--now] [--threshold N] [--force-reset] [--fix-ping-url]" >&2
        exit 2
        ;;
    esac
    shift
done

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

if ! dpkg -s landscape-client >/dev/null 2>&1; then
    log "landscape-client not installed; nothing to do"
    exit 0
fi

if [ ! -f "$CONF" ]; then
    log "ERROR: $CONF not found — is this machine registered?" >&2
    exit 1
fi

# Count queued messages. The store nests them in numbered subdirectories
# (messages/3/19934), so recurse rather than globbing the top level.
queued() { find "$MSG_DIR" -type f 2>/dev/null | wc -l; }

# Current value of a key inside the [client] section, empty if unset.
get_conf_key() {
    awk -v key="$1" '
        /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[client\][[:space:]]*$/); next }
        insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
            print; exit
        }
    ' "$CONF"
}

# Replace (or append) a key inside the [client] section, preserving comments,
# ordering and the file's 0600 landscape:root permissions.
set_conf_key() {
    local key=$1 value=$2 tmp
    tmp=$(mktemp)
    awk -v key="$key" -v value="$value" '
        BEGIN { insec = 0; done = 0 }
        /^[[:space:]]*\[/ {
            # Appending at a section boundary: keep a blank line before the
            # next header so the file stays readable.
            if (insec && !done) { print key " = " value; print ""; done = 1 }
            insec = ($0 ~ /^[[:space:]]*\[client\][[:space:]]*$/)
            print; next
        }
        {
            if (insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
                if (!done) { print key " = " value; done = 1 }
                next
            }
            print
        }
        END { if (insec && !done) print key " = " value }
    ' "$CONF" >"$tmp"

    # cat-into-place keeps the original inode, owner and mode (0600).
    cat "$tmp" >"$CONF"
    rm -f "$tmp"
}

backup_conf() {
    cp -a "$CONF" "$CONF.bak-$STAMP"
    log "backed up $CONF -> $CONF.bak-$STAMP"
}

report() {
    local n plugins ping
    n=$(queued)
    plugins=$(get_conf_key monitor_plugins)
    ping=$(get_conf_key ping_url)
    echo "== $(hostname) =="
    echo "  landscape-client : $(systemctl is-active landscape-client 2>&1) / $(systemctl is-enabled landscape-client 2>&1)"
    echo "  queued messages  : $n"
    echo "  monitor_plugins  : ${plugins:-<unset — defaults to ALL>}"
    echo "  ping_url         : ${ping:-<unset — defaults to http://landscape.canonical.com/ping>}"
    if [ -r "$BROKER_LOG" ]; then
        echo "  last exchanges   :"
        grep -E "Pending messages remaining" "$BROKER_LOG" 2>/dev/null | tail -3 | sed 's/^/    /' || true
    fi
}

# The disruptive half, written out so it can run detached from this process.
write_reset_helper() {
    cat >"$RESET_HELPER" <<EOF
#!/bin/bash
# Generated by landscape-queue-fix.sh on $STAMP — safe to delete.
# Clears the wedged Landscape message store and bounces the client.
# broker.bpickle is deliberately left alone: it holds the computer ID and
# secure ID, so the machine stays registered.
set -euo pipefail
systemctl stop landscape-client
if [ -d "$MSG_DIR" ]; then
    mv "$MSG_DIR" "$MSG_DIR.bak-$STAMP"
    install -d -o landscape -g landscape -m 755 "$MSG_DIR"
fi
systemctl start landscape-client
EOF
    chmod 755 "$RESET_HELPER"
}

run_reset() {
    write_reset_helper
    if [ "$RESTART_MODE" = inline ]; then
        log "clearing message store and restarting landscape-client now"
        "$RESET_HELPER"
        log "landscape-client: $(systemctl is-active landscape-client 2>&1)"
    else
        # Detached so this script can exit and report to Landscape before the
        # client (and the manager running us) goes down.
        systemctl reset-failed "$RESET_UNIT.service" "$RESET_UNIT.timer" 2>/dev/null || true
        if systemd-run --collect --unit="$RESET_UNIT" --on-active=20 \
            --description="Clear wedged Landscape message store" \
            "$RESET_HELPER" >/dev/null 2>&1; then
            log "scheduled store reset + client restart in ~20s (detached)"
        else
            log "WARNING: could not schedule detached reset, running inline"
            "$RESET_HELPER"
        fi
    fi
}

restart_only() {
    if [ "$RESTART_MODE" = inline ]; then
        log "restarting landscape-client now"
        systemctl restart landscape-client
        log "landscape-client: $(systemctl is-active landscape-client 2>&1)"
    else
        systemctl restart --no-block landscape-client
        log "queued a non-blocking restart of landscape-client"
    fi
}

case "$ACTION" in
status)
    report
    ;;

revert)
    current=$(get_conf_key monitor_plugins)
    if [ -z "$current" ] || [ "$current" = "ALL" ]; then
        log "monitor_plugins already at the default; nothing to do"
        exit 0
    fi
    backup_conf
    set_conf_key monitor_plugins ALL
    log "restored monitor_plugins = ALL"
    restart_only
    ;;

apply)
    changed=0
    before=$(queued)
    log "queued messages before: $before"

    current=$(get_conf_key monitor_plugins)
    if [ "$current" = "$PLUGINS" ]; then
        log "monitor_plugins already pinned; leaving config alone"
    else
        backup_conf
        set_conf_key monitor_plugins "$PLUGINS"
        log "set monitor_plugins (dropped ActiveProcessInfo, SwiftUsage, CephUsage)"
        changed=1
    fi

    if [ "$FIX_PING" -eq 1 ]; then
        ping=$(get_conf_key ping_url)
        case "$ping" in
        https://*)
            log "ping_url already HTTPS; leaving alone"
            ;;
        *)
            [ "$changed" -eq 1 ] || backup_conf
            set_conf_key ping_url "$PING_URL_HTTPS"
            log "set ping_url = $PING_URL_HTTPS (was: ${ping:-<unset>})"
            changed=1
            ;;
        esac
    fi

    if [ "$FORCE_RESET" -eq 1 ] || [ "$before" -ge "$THRESHOLD" ]; then
        log "backlog $before >= threshold $THRESHOLD (or --force-reset): clearing store"
        run_reset
    elif [ "$changed" -eq 1 ]; then
        log "backlog $before under threshold $THRESHOLD; restarting to pick up config"
        restart_only
    else
        log "nothing to change and no backlog; done"
    fi

    echo
    report
    ;;
esac
