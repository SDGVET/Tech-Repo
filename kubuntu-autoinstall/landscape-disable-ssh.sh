#!/bin/bash
# Close SSH access on a workstation — the production counterpart to the
# ENABLE_SSH_FOR_TESTING=1 state that test images ship with.
#
# Run via Landscape ("Run script" as root) against any/all workstations once
# testing is done, or by hand:  sudo bash landscape-disable-ssh.sh
# Idempotent; safe to run on machines where SSH is already closed.
#
# NOTE: this cuts off any active SSH session to the machine, including the
# admin laptop's. Future images ship closed once the post-install script's
# ENABLE_SSH_FOR_TESTING is flipped to 0 — this script is for machines
# imaged before the flip.

set -u

echo "== Disabling SSH on $(hostname) =="

# Ubuntu 26.04 ships sshd socket-activated: ssh.socket relaunches sshd on
# connection even when ssh.service is stopped, so both must be disabled.
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl disable --now ssh.service 2>/dev/null || true

# Remove the firewall allowance (added by the post-install in testing mode).
# Delete repeatedly in case the rule was ever added more than once; each ufw
# delete removes one instance (IPv4+IPv6 pair) and fails when none remain.
while ufw delete allow ssh 2>/dev/null | grep -q "Rule deleted"; do :; done

echo "== Verification =="
echo "ssh.service: $(systemctl is-enabled ssh.service 2>&1) / $(systemctl is-active ssh.service 2>&1)"
echo "ssh.socket:  $(systemctl is-enabled ssh.socket 2>&1) / $(systemctl is-active ssh.socket 2>&1)"
if ss -tln | grep -q ':22 '; then
    echo "WARNING: something is still listening on port 22"
else
    echo "port 22: nothing listening"
fi
ufw status | grep -iE "^status|22" || true
echo "== Done =="
