#!/bin/bash
# One-off TEST of the SDDM + VetBadger fixes on a RUNNING workstation (no reimage).
# Run:  sudo bash test-fixes.sh
# Safe and reversible; contains no secrets. Delete from the repo once validated.
set -u

echo "=== SDDM: purge Budgie theme, force Breeze login ==="
apt-get purge -y budgie-sddm-theme
mkdir -p /etc/sddm.conf.d
rm -f /etc/sddm.conf.d/50-sdgvet-theme.conf
printf '[Theme]\nCurrent=breeze\n' > /etc/sddm.conf.d/90-sdgvet-theme.conf
echo "   -> budgie-sddm-theme removed; /etc/sddm.conf.d/90-sdgvet-theme.conf set to breeze"

echo "=== VetBadger: point the force-install policy at the login URL ==="
mkdir -p /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/sdgvet-web-apps.json <<'JSON'
{
  "WebAppInstallForceList": [
    {
      "url": "https://login.vetbadger.com/login?originator=%2Fhome",
      "create_desktop_shortcut": true,
      "default_launch_container": "window",
      "custom_name": "VetBadger"
    }
  ]
}
JSON
chmod 644 /etc/opt/chrome/policies/managed/sdgvet-web-apps.json

# remove the old hand-written placeholder launcher from the employee account
U=$(getent passwd 1000 | cut -d: -f1); H=$(getent passwd 1000 | cut -d: -f6)
[ -n "$H" ] && rm -f "$H/.local/share/applications/chrome-ojdepafgebajpbdahdokdolkoekmbooa-Default.desktop"
echo "   -> policy updated; old placeholder launcher removed"

echo
echo "=== NEXT STEPS ==="
echo "SDDM  : log out and back in (or, from a TTY, 'sudo systemctl restart sddm' --"
echo "        that ENDS your session, so save work first). Expect the Breeze login."
echo "VetBdg: fully quit Chrome (all windows), reopen, wait ~30s, then check"
echo "        chrome://apps and your app menu for VetBadger + its icon."
