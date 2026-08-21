# Tech-Repo

SDGVET's IT scripts, fixes, and infrastructure notes. Fleet scripts are written
to be idempotent so they can be pushed repeatedly through Landscape.

## Running these from Landscape

`run-from-repo.sh` is the one script you paste into Landscape by hand. It
fetches a named script from this repo and runs it, so everything else is edited
in your code editor and pushed to GitHub instead of being retyped into the
Landscape UI. Set `SCRIPT=` at the top (or pass the name as an argument), use
interpreter `/bin/bash` and run as root. It busts the raw.githubusercontent CDN
cache (otherwise a just-pushed fix can come back stale for a few minutes),
refuses to execute an empty or non-shebang file, logs the sha256 of what it
ran, and exits with the fetched script's exit code so failures show up as
failed activities. `DRY_RUN=1` fetches and verifies without executing.

## Fleet fix scripts

| Script | What it does |
|---|---|
| `chrome-wayland-click-fix.sh` | Fixes buttons in Chrome dialogs (print preview, PWAs like VetBadger) needing a press-and-hold click on Plasma/Wayland with fractional scaling. dpkg-diverts Chrome's launcher to add `--disable-features=WaylandPerSurfaceScale,WaylandUiScale` on Wayland sessions only. Run with `remove` to undo. |
| `landscape-queue-fix.sh` | Fixes the Landscape message backlog that stalls script/update delivery. Drops the `ActiveProcessInfo` monitor plugin (~23 KB messages that block the ordered message store) plus the unused `SwiftUsage`/`CephUsage` plugins, and clears a wedged store. Restarts the client detached so it survives being run *from* Landscape. `status` to inspect, `revert` to undo. |
| `install-dymo-printer.sh` | Installs the DYMO LabelWriter 450 Turbo queue (`printer-driver-dymo` + `lw450t.ppd`) and — the part plain `lpadmin` misses — sets the default label size to `w154h198` (2-1/8" x 2-3/4"), not the PPD's stock 30256 shipping label. **The printer does not need to be attached**: the queue is created up front and waits for the hardware, which is what our truck-based unit needs. Clears CUPS auto-created duplicate queues (they carry the wrong label size) and installs a udev hook that re-binds the queue on plug-in. `--test` prints a test label, `--no-hook` skips the hook. Run as root. |
| `fix-arkscan-orientation.sh` | Re-applies `LandscapeOrientation: Minus90` in the Arkscan label printer PPDs after a CUPS/package update resets it. Run as root. |
| `setup-audio-fix.sh` | Fixes built-in stereo speakers losing a channel after a USB headset is unplugged (PipeWire). Installs a udev rule + systemd user service that resets the card profile on unplug. See the script header for `--user` / `--usb-id` options. |
| `flatpak-update-landscape.sh` | Weekly Flatpak update for the fleet, meant to be pasted into Landscape as a stored script (interpreter `/bin/bash`, run as root, time limit 3300 — the 300s default kills a real update mid-download). Prints pending updates, runs `flatpak update -y --noninteractive` so the ref/version table lands in the Landscape activity output, then prunes unused runtimes. Exits non-zero if the update failed, so failures are filterable in Landscape. |

## Personal app installers

| Script | What it does |
|---|---|
| `install-planify.sh` | Installs [Planify](https://github.com/alainm23/planify) (to-do/task manager) on CachyOS/Arch. Prefers AUR via paru/yay, falls back to Flatpak (Flathub) if no AUR helper is present. Run with `--aur` or `--flatpak` to force a method. |

## Projects

- **[kubuntu-autoinstall](kubuntu-autoinstall/)** — automated install for new
  employee workstations: lean KDE Plasma desktop, office printers
  pre-configured, LWVC wifi, plus Landscape post-install scripts.
- **[nextcloud-tasks-mcp](nextcloud-tasks-mcp/)** — MCP server that lets
  Claude Code read and manage Nextcloud tasks.
- **[voice-task-api](voice-task-api/)** — dockerized API for adding Nextcloud
  tasks hands-free via Tasker and Google Assistant.

## Printer files

- `Arkscan-Zebra.ppd` — PPD for the Arkscan/Zebra label printers.

## Notes

- `kwin-dolphin-touchpad-notes.md` — KWin crash-looping and Dolphin crashes
  traced to a faulty PIXA3854 touchpad (2026-06-18).
