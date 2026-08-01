#!/bin/bash
#
# landscape-migrate-to-selfhosted.sh
#
# Moves a workstation from Landscape SaaS (landscape.canonical.com) to our
# self-hosted Landscape Server, without touching anything else on the machine.
#
# Run via the OLD Landscape dashboard ("Run script" as root) against one pilot
# machine first, then the rest of the fleet in batches. Also works by hand:
#
#   sudo bash landscape-migrate-to-selfhosted.sh --key 'REGKEY' --now
#
# The registration key is a SECRET and is deliberately NOT in this file —
# Tech-Repo is public. Pass it with --key every time.
#
# What it does, in order:
#   1. refuses to start unless the new server answers /ping over HTTPS, so a
#      typo or a down tunnel can't strand the machine with no manager at all;
#   2. moves aside /var/lib/landscape/client, which holds the computer ID and
#      secure ID issued by the OLD server plus any queued messages addressed
#      to it — both are meaningless to the new server and confuse re-registration;
#   3. re-runs landscape-config against the new URL;
#   4. pins monitor_plugins the same way landscape-queue-fix.sh does, so the
#      ActiveProcessInfo backlog does not follow the machine to the new server;
#   5. restarts landscape-client.
#
# Both URLs are HTTPS on purpose. The client's default ping_url is plain HTTP
# on port 80, which our firewall blocks outbound — that silently costs a machine
# the fast-dispatch path and drops it to the 15-minute exchange interval. See
# the --fix-ping-url notes in landscape-queue-fix.sh.
#
# IMPORTANT when run from Landscape: steps 2-5 kill the landscape-client that is
# running this very script, so the result would never reach the old dashboard.
# The default path hands that work to a detached systemd transient unit firing
# ~20s after this script exits, letting the result report first. Use --now only
# over SSH or at the console.
#
# Rollback is the same script pointed the other way, e.g.
#   ... --server landscape.canonical.com --account qftnvcf3 --key 'OLDKEY' --now
#
# Usage:
#   landscape-migrate-to-selfhosted.sh --key KEY        # migrate; detached restart
#   landscape-migrate-to-selfhosted.sh --key KEY --now  # migrate; inline restart
#   landscape-migrate-to-selfhosted.sh status           # report only, change nothing
#
# Options:
#   --key KEY         registration key (required unless action is "status")
#   --server FQDN     Landscape server (default landscape.sdgvet.com)
#   --account NAME    account name (default standalone — the self-hosted default)
#   --title NAME      computer title (default: this machine's hostname)
#   --now             do the disruptive work inline instead of detached
#   --keep-plugins    skip the monitor_plugins pin
#
# Idempotent: safe to run repeatedly. Re-running against a server the machine is
# already registered with just re-registers it under the same title.

set -euo pipefail

CONF=/etc/landscape/client.conf
CLIENT_DIR=/var/lib/landscape/client
BROKER_LOG=/var/log/landscape/broker.log
MIGRATE_HELPER=/usr/local/sbin/landscape-migrate-helper.sh
MIGRATE_UNIT=landscape-migrate
STAMP=$(date +%F-%H%M%S)

# Same list as landscape-queue-fix.sh: every ALL_PLUGINS entry except
# ActiveProcessInfo (the 23 KB process table that wedges the queue), SwiftUsage
# and CephUsage (OpenStack plugins that do nothing on a workstation).
PLUGINS="ComputerInfo, LoadAverage, MemoryInfo, MountInfo, ProcessorInfo, Temperature, PackageMonitor, UserMonitor, RebootRequired, AptPreferences, NetworkActivity, NetworkDevice, UpdateManager, CPUUsage, ComputerTags, SnapServicesMonitor, CloudInit"

ACTION=migrate
RESTART_MODE=detached
SERVER=landscape.sdgvet.com
ACCOUNT=standalone
TITLE=$(hostname)
KEY=""
PIN_PLUGINS=1

while [ $# -gt 0 ]; do
    case "$1" in
    migrate | status) ACTION=$1 ;;
    --now) RESTART_MODE=inline ;;
    --keep-plugins) PIN_PLUGINS=0 ;;
    --key)
        KEY=${2:?--key needs a value}
        shift
        ;;
    --server)
        SERVER=${2:?--server needs a value}
        shift
        ;;
    --account)
        ACCOUNT=${2:?--account needs a value}
        shift
        ;;
    --title)
        TITLE=${2:?--title needs a value}
        shift
        ;;
    -h | --help)
        sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown argument: $1" >&2
        echo "usage: $0 [migrate|status] --key KEY [--server FQDN] [--account NAME] [--title NAME] [--now] [--keep-plugins]" >&2
        exit 2
        ;;
    esac
    shift
done

URL="https://$SERVER/message-system"
PING_URL="https://$SERVER/ping"

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

if ! dpkg -s landscape-client >/dev/null 2>&1; then
    log "landscape-client not installed; nothing to migrate"
    exit 0
fi

# Current value of a key inside the [client] section, empty if unset.
get_conf_key() {
    [ -f "$CONF" ] || return 0
    awk -v key="$1" '
        /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[client\][[:space:]]*$/); next }
        insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
            print; exit
        }
    ' "$CONF"
}

queued() { find "$CLIENT_DIR/messages" -type f 2>/dev/null | wc -l; }

report() {
    echo "== $(hostname) =="
    echo "  landscape-client : $(systemctl is-active landscape-client 2>&1) / $(systemctl is-enabled landscape-client 2>&1)"
    echo "  url              : $(get_conf_key url)"
    echo "  ping_url         : $(get_conf_key ping_url)"
    echo "  account_name     : $(get_conf_key account_name)"
    echo "  computer_title   : $(get_conf_key computer_title)"
    echo "  monitor_plugins  : $(get_conf_key monitor_plugins || true)"
    echo "  queued messages  : $(queued)"
    if [ -r "$BROKER_LOG" ]; then
        echo "  last exchanges   :"
        grep -E "Pending messages remaining" "$BROKER_LOG" 2>/dev/null | tail -3 | sed 's/^/    /' || true
    fi
}

if [ "$ACTION" = status ]; then
    report
    exit 0
fi

if [ -z "$KEY" ]; then
    echo "ERROR: --key is required (the new server's registration key)" >&2
    exit 2
fi

# --- Preflight: never cut a machine loose from a server that isn't there -----
log "checking $PING_URL is reachable before changing anything"
if ! curl -fsS --max-time 20 --retry 3 --retry-delay 5 "$PING_URL" >/dev/null 2>&1; then
    echo "ERROR: $PING_URL did not respond. Not migrating — this machine stays" >&2
    echo "       registered where it is. Check the tunnel, the VM, and the FQDN." >&2
    exit 1
fi
log "new server answered; proceeding"

if [ -f "$CONF" ]; then
    cp -a "$CONF" "$CONF.bak-$STAMP"
    log "backed up $CONF -> $CONF.bak-$STAMP"
fi

log "current server: $(get_conf_key url || echo '<unset>')"
log "new server    : $URL"

# --- The disruptive half, written out so it can run detached ----------------
write_helper() {
    cat >"$MIGRATE_HELPER" <<EOF
#!/bin/bash
# Generated by landscape-migrate-to-selfhosted.sh on $STAMP — safe to delete.
# Re-registers this machine against $SERVER.
set -euo pipefail

# If anything below fails, still bring the client back up: client.conf will
# already point at the new server, and landscape-client retries registration on
# its own. Leaving the service stopped would leave the machine unmanaged.
trap 'systemctl start landscape-client || true' ERR

systemctl stop landscape-client || true

# The old server's computer ID, secure ID and queued messages live here. They
# are worthless to the new server and make re-registration ambiguous, so move
# the whole directory aside rather than deleting it — recovery stays possible.
if [ -d "$CLIENT_DIR" ]; then
    mv "$CLIENT_DIR" "$CLIENT_DIR.bak-$STAMP"
fi
install -d -o landscape -g landscape -m 755 "$CLIENT_DIR"

landscape-config --silent \\
    --url "$URL" \\
    --ping-url "$PING_URL" \\
    --account-name "$ACCOUNT" \\
    --registration-key "$KEY" \\
    --computer-title "$TITLE" \\
    --include-manager-plugins=ScriptExecution \\
    --script-users=root,landscape

EOF

    if [ "$PIN_PLUGINS" -eq 1 ]; then
        cat >>"$MIGRATE_HELPER" <<EOF
# Pin monitor_plugins so the ActiveProcessInfo backlog does not follow the
# machine to the new server. landscape-config rewrites client.conf, so this has
# to happen after registration, not before. sed -i replaces the file, hence the
# explicit chown/chmod back to the 0600 landscape:root the client expects.
if grep -q '^[[:space:]]*monitor_plugins' "$CONF"; then
    sed -i "s|^[[:space:]]*monitor_plugins.*|monitor_plugins = $PLUGINS|" "$CONF"
else
    sed -i "/^\[client\]/a monitor_plugins = $PLUGINS" "$CONF"
fi
chown landscape:root "$CONF"
chmod 0600 "$CONF"

EOF
    fi

    cat >>"$MIGRATE_HELPER" <<EOF
systemctl restart landscape-client

# The registration key is embedded above, so don't leave this lying around.
rm -f "\$0"
EOF
    # 0700, not 0755: this file contains the registration key until it deletes
    # itself, and workstations have non-root users on them.
    chmod 700 "$MIGRATE_HELPER"
}

write_helper

if [ "$RESTART_MODE" = inline ]; then
    log "re-registering against $SERVER now"
    "$MIGRATE_HELPER"
    log "landscape-client: $(systemctl is-active landscape-client 2>&1)"
    echo
    report
else
    # Detached so this script can exit and report to the OLD dashboard before
    # the client running it goes down.
    systemctl reset-failed "$MIGRATE_UNIT.service" "$MIGRATE_UNIT.timer" 2>/dev/null || true
    if systemd-run --collect --unit="$MIGRATE_UNIT" --on-active=20 \
        --description="Re-register Landscape client against $SERVER" \
        "$MIGRATE_HELPER" >/dev/null 2>&1; then
        log "scheduled re-registration in ~20s (detached)"
        log "this machine should appear in the $SERVER dashboard within ~15 min"
    else
        log "WARNING: could not schedule detached migration, running inline"
        "$MIGRATE_HELPER"
    fi
fi
