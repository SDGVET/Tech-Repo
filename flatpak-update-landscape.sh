#!/bin/bash
# Weekly Flatpak update, run from Landscape as a stored script.
#   Interpreter: /bin/bash   Run as: root   Time limit: 3300
# Everything printed here is what Landscape stores as the activity output.

echo "Flatpak update on $(hostname) -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo

echo "== Pending =="
flatpak remote-ls --updates

echo
echo "== Updating =="
flatpak update -y --noninteractive
rc=$?

echo
echo "== Removing unused runtimes =="
flatpak uninstall --unused -y --noninteractive

echo
echo "Finished $(date '+%H:%M:%S') (exit $rc)"
exit $rc
