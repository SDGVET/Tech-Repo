# Obsidian vault sync — self-hosted plan

Syncing an Obsidian vault across Linux desktops and Android, with unraid as the
always-on node. No third-party cloud (no Obsidian Sync, no Google Drive).

**Design: Syncthing for the transport, server-side git for the history.**

Priorities that drove this: version history / undo matters as much as syncing,
and there are no iOS devices in the fleet (which is what usually forces a
CouchDB-based setup).

## Why not Nextcloud

Nextcloud is already running, but it's the wrong tool for this particular job:

- The Nextcloud Android app doesn't keep a local folder continuously two-way
  synced. Auto-upload is one-way and offline files are a manual pin, so Obsidian
  on Android has no live folder to point at.
- The usual workaround is the Remotely Save plugin over WebDAV — interval-based
  push/pull with weaker conflict handling than Syncthing.
- Nextcloud's per-file version history is awkward to navigate across a whole
  vault.
- WebDAV through the Cloudflare proxy caps request bodies at 100 MB on the free
  plan, so large attachments would fail confusingly.

Syncthing also needs nothing from NPM — it does its own TLS with device-ID
pinning on port 22000, so it stays entirely out of the HTTP path.

## Architecture

| Layer | Provides |
|---|---|
| Syncthing | Live sync between devices |
| Syncthing staggered versioning (server) | Instant undelete, last few days |
| Server-side git, hourly | Real history, diffs, restore from any point |
| Existing unraid share backup | Disaster recovery |

## Build

### 1. Server share

Create a share, e.g. `/mnt/user/obsidian/vault`. Set it to **cache: prefer** — a
vault is thousands of tiny files and shouldn't live on spinning disks.

### 2. Syncthing container

Install `syncthing` (linuxserver.io) from Community Apps.

- Network mode **host**, so LAN discovery broadcast (21027/udp) works.
- `PUID=99`, `PGID=100`.
- Map `/mnt/user/obsidian` in.
- Leave the GUI (8384) off the public internet — LAN or VPN only. It has a
  filesystem browser and shouldn't be exposed even behind basic auth.

### 3. Linux desktops

```bash
sudo pacman -S syncthing            # or apt install syncthing
systemctl --user enable --now syncthing
```

Pair with the server by device ID, then share the folder.

### 4. Android

Install **Syncthing-Fork** from F-Droid. The original Syncthing-Android was
discontinued in late 2024; Fork is the maintained one.

Two things that bite people:

- Grant it **All files access**, and put the vault in shared storage
  (`/storage/emulated/0/Documents/ObsidianVault`), *not* under `Android/data/` —
  Obsidian can't open a vault there.
- Disable battery optimisation for both Syncthing-Fork and Obsidian. In Fork's
  **Run conditions**, enable running on mobile data if sync should work off wifi.

### 5. Ignore patterns

Per folder, on each device:

```
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/cache
.trash
```

`workspace.json` rewrites itself constantly on every device and is the single
biggest source of sync conflicts. Everything else in `.obsidian/` *should* sync
so plugins and hotkeys follow you around.

Note `.stignore` is per-device and does not itself sync — set it on each one.

### 6. File versioning

On the unraid node's folder: **Advanced → File Versioning → Staggered**. Deleted
or overwritten files land in `.stversions/` on the server and thin out over time.
This is the instant-undelete layer.

## Network path

Cloudflare's proxy only handles HTTP/HTTPS on the free plan, and Syncthing's
sync protocol is raw TCP/UDP with its own TLS. Arbitrary TCP through Cloudflare
needs Spectrum (enterprise) or a Tunnel, and the Tunnel client side has no
Android story. So the existing NPM + Cloudflare path is a dead end here — and
isn't needed.

Syncthing picks the best available path automatically, per connection:

- **On LAN** → direct, fast.
- **VPN up** → direct over the VPN, fast.
- **Neither** → public relay fallback.

**Recommended: forward nothing.** Leave relaying and global discovery on. Relay
operators shuttle an encrypted stream between two devices that have already
authenticated by device ID — they can't decrypt it or inject into it. The cost is
shared bandwidth, which is irrelevant for a text vault.

### If relay speed becomes annoying

Port-forward 22000 TCP+UDP and add a **DNS-only (grey cloud)** record. Tradeoff:
the port itself is fairly safe to expose (no login to brute force — mutual TLS
with pinned device IDs, unknown devices are rejected at handshake), but a
grey-clouded record publishes the home IP for that hostname, which is what the
orange cloud is otherwise buying.

### If nothing external should be contacted

Turn **off** global discovery and relaying, then set the server's address
statically on each device to `tcp://<vpn-ip>:22000`. Sync then only happens on
LAN or with the VPN connected. Cost: phone edits sit locally until the VPN is
next up.

Both of these are config changes later, not a rebuild. Start with relays on.

## Version history layer

Git runs on the server only, so the phone never touches it. Keep `.git` *outside*
the vault so Syncthing never sees it:

```bash
mkdir -p /mnt/user/appdata/obsidian-git
git init --bare /mnt/user/appdata/obsidian-git/vault.git
git --git-dir=/mnt/user/appdata/obsidian-git/vault.git config core.bare false
```

Exclusions go in `vault.git/info/exclude`, so nothing is added to the vault
itself:

```
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/cache
.trash/
.stfolder/
.stversions/
*.sync-conflict-*
```

Then a **User Scripts** job on an hourly cron:

```bash
#!/bin/bash
export GIT_DIR=/mnt/user/appdata/obsidian-git/vault.git
export GIT_WORK_TREE=/mnt/user/obsidian/vault
git add -A
git diff --cached --quiet || git commit -q -m "auto: $(date -Iseconds)"
```

The `git diff --cached --quiet` guard prevents empty commits on quiet hours. Add
a monthly `git gc --auto` to stay tidy.

## Restoring

Fix it on the server and Syncthing pushes the fix everywhere:

```bash
export GIT_DIR=/mnt/user/appdata/obsidian-git/vault.git
export GIT_WORK_TREE=/mnt/user/obsidian/vault

git log --oneline -- "Notes/thing.md"     # find the commit
git show <sha>:"Notes/thing.md" | less    # peek at it first
git checkout <sha> -- "Notes/thing.md"    # restore in place
```

For "I deleted this ten minutes ago," `.stversions/` is faster. For "what did
this look like in March," git.

## Gotchas

- Syncthing conflicts appear as `note.sync-conflict-20260801-....md` next to the
  original. Add `sync-conflict` to Obsidian's **Settings → Files & Links →
  Excluded files** so they stop polluting search results.
- Obsidian on Android sometimes doesn't notice files that changed underneath it.
  Switching away and back to the app refreshes it.
- Global discovery pings Syncthing's public discovery servers for IP lookup. No
  file data touches them, but see the lockdown option above to avoid it entirely.
- Don't also add the vault to a Nextcloud sync folder. Two sync engines writing
  the same tree will corrupt each other eventually.
