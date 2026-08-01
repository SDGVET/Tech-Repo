# Tech-Repo

SDGVET's IT scripts, fixes, and infrastructure notes. Fleet scripts are written
to be idempotent so they can be pushed repeatedly through Landscape.

## Fleet fix scripts

| Script | What it does |
|---|---|
| `chrome-wayland-click-fix.sh` | Fixes buttons in Chrome dialogs (print preview, PWAs like VetBadger) needing a press-and-hold click on Plasma/Wayland with fractional scaling. dpkg-diverts Chrome's launcher to add `--disable-features=WaylandPerSurfaceScale,WaylandUiScale` on Wayland sessions only. Run with `remove` to undo. |
| `landscape-queue-fix.sh` | Fixes the Landscape message backlog that stalls script/update delivery. Drops the `ActiveProcessInfo` monitor plugin (~23 KB messages that block the ordered message store) plus the unused `SwiftUsage`/`CephUsage` plugins, and clears a wedged store. Restarts the client detached so it survives being run *from* Landscape. `status` to inspect, `revert` to undo. |
| `fix-arkscan-orientation.sh` | Re-applies `LandscapeOrientation: Minus90` in the Arkscan label printer PPDs after a CUPS/package update resets it. Run as root. |
| `setup-audio-fix.sh` | Fixes built-in stereo speakers losing a channel after a USB headset is unplugged (PipeWire). Installs a udev rule + systemd user service that resets the card profile on unplug. See the script header for `--user` / `--usb-id` options. |

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
