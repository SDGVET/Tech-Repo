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
| `disable-plasma-zoom.sh` | Turns off the KWin desktop zoom/magnifier fleet-wide — `Meta++`/`Meta+-`/`Meta+0`, `Meta+scroll` and the touchpad pinch all stop, because they are registered by the Zoom effect itself. Sets `zoomEnabled=false` in `/etc/xdg/kwinrc` and applies it to live sessions without a logout: `reconfigure` only re-reads settings, so it also calls `unloadEffect` the way the Desktop Effects KCM does. System-wide default only, so a user can still re-enable it (the run reports anyone who has); `--lock` makes it immutable, `--enable` reverts, `--status` reports. |
| `landscape-queue-fix.sh` | Fixes the Landscape message backlog that stalls script/update delivery. Drops the `ActiveProcessInfo` monitor plugin (~23 KB messages that block the ordered message store) plus the unused `SwiftUsage`/`CephUsage` plugins, and clears a wedged store. Restarts the client detached so it survives being run *from* Landscape. `status` to inspect, `revert` to undo. |
| `install-dymo-printer.sh` | Installs the DYMO LabelWriter 450 Turbo queue (`printer-driver-dymo` + `lw450t.ppd`) and — the part plain `lpadmin` misses — sets the default label size to `w154h198` (2-1/8" x 2-3/4"), not the PPD's stock 30256 shipping label. **The printer does not need to be attached**: the queue is created up front and waits for the hardware, which is what our truck-based unit needs. Clears CUPS auto-created duplicate queues (they carry the wrong label size) and installs a udev hook that re-binds the queue on plug-in. `--test` prints a test label, `--no-hook` skips the hook. Run as root. |
| `fix-arkscan-orientation.sh` | Re-applies `LandscapeOrientation: Minus90` in the Arkscan label printer PPDs after a CUPS/package update resets it. Run as root. |
| `setup-audio-fix.sh` | Fixes built-in stereo speakers losing a channel after a USB headset is unplugged (PipeWire). Installs a udev rule + systemd user service that resets the card profile on unplug. See the script header for `--user` / `--usb-id` options. |
| `flatpak-update-landscape.sh` | Weekly Flatpak update for the fleet, meant to be pasted into Landscape as a stored script (interpreter `/bin/bash`, run as root, time limit 3300 — the 300s default kills a real update mid-download). Prints pending updates, runs `flatpak update -y --noninteractive` so the ref/version table lands in the Landscape activity output, then prunes unused runtimes. Exits non-zero if the update failed, so failures are filterable in Landscape. |
| `install-talkatoo.sh` | Installs the Talkatoo dictation desktop app (Windows/Electron) system-wide under GE-Proton — no plain Wine, no .NET. Pulls the app out of `TalkatooSetup.exe` without running it (running the installer under Proton froze Plasma), verifies GE-Proton and the app package checksums, and installs to `/opt/talkatoo` with a `talkatoo` launcher and menu entry. Each user gets their own Proton prefix on first launch, with DPI matched to their Plasma scale. Idempotent; `TALKATOO_UPDATE=1` checks for a newer version. Takes ~30 min on first run, so raise the Landscape time limit. Run as root. |
| `syncthing-sharefolder.sh` | Moves the shared LWVC folder from the Nextcloud client to Syncthing at `~/Documents/ShareFolder` on every PC, with unraid as the hub. Finds each PC's old Nextcloud copy from the client's own config, since every client was pointed at a different folder. `seed` (base PC, as yourself) copies the folder and offers it to the NAS; `setup` (root, Landscape) installs Syncthing for the PC's user and prints the device ID to add on the NAS; `verify` compares the old copy against the synced folder and rescues anything that would be lost; `status` (default) only reports. Never deletes the old copy. Needs `NAS_ID=` — not stored in this public repo. Mode via `SHARE_MODE=` when run through `run-from-repo.sh`. See `sharefolder-syncthing-plan.md`. |

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

- `sharefolder-syncthing-plan.md` — cutover plan for moving the shared LWVC
  folder from Nextcloud to Syncthing (`syncthing-sharefolder.sh`).
- `kwin-dolphin-touchpad-notes.md` — KWin crash-looping and Dolphin crashes
  traced to a faulty PIXA3854 touchpad (2026-06-18).
