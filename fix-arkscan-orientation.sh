#!/bin/bash
# Run as root. Corrects LandscapeOrientation to Minus90 in the installed
# Arkscan PPD files after a CUPS/package update resets the value.

set -euo pipefail

for PRINTER in "Arkscan-Reception" "Arkscan1"; do
    PPD="/etc/cups/ppd/${PRINTER}.ppd"
    if [ -f "$PPD" ]; then
        CURRENT=$(grep '^\*LandscapeOrientation:' "$PPD" | awk '{print $2}')
        echo "[$PRINTER] Current orientation: ${CURRENT:-not set}"
        sed -i 's/^\*LandscapeOrientation:.*/*LandscapeOrientation: Minus90/' "$PPD"
        echo "[$PRINTER] Orientation set to Minus90."
    else
        echo "[$PRINTER] PPD not found, skipping."
    fi
done

systemctl restart cups
echo "CUPS restarted. Done."
