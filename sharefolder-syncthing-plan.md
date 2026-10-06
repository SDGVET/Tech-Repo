# Shared folder: Nextcloud → Syncthing

Moving the LWVC team folder off the Nextcloud desktop client and onto
Syncthing, so every PC has it at the same path: `~/Documents/ShareFolder`.

**Design: Syncthing for the shared folder, unraid as the hub, Nextcloud kept
for everything else.**

## Why

- Each Nextcloud client was pointed at a hand-picked local folder, so the
  shared folder sits at a different path on every PC.
- Every new PC needs a Nextcloud login and share setup done by hand.
- Syncthing is already running for the Obsidian vault with `unraid-tower` as
  the hub (see `obsidian-sync-plan.md`), so this is one more folder on the same
  setup, not a new system.

What we give up for this folder: browser/phone access, share links, and
per-user permissions. Access is per device and all-or-nothing.

## Architecture

| Layer | Provides |
|---|---|
| Syncthing, folder ID `lwvc-share` | Live two-way sync between PCs |
| NAS marked as introducer on each PC | PCs learn about each other and sync directly, so the office keeps syncing when the NAS (currently off-site) is unreachable |
| Syncthing staggered versioning (NAS only) | Undelete and older versions |
| Existing unraid share backup | Disaster recovery |
| Nextcloud desktop client | Unchanged for personal files; just no longer carries LWVC |

Syncthing is sync, not backup: a deletion on one PC is a deletion everywhere,
and versioning on the NAS is the only undo. Two people saving the same file at
once produces a `*.sync-conflict-*` copy next to it, not an overwrite.
LibreOffice lock files sync too, so a second person usually gets the
"document in use" warning.

## Cutover

`syncthing-sharefolder.sh` does the PC side. `NAS_ID` is the unraid Syncthing
device ID (Actions → Show ID on the NAS); it is passed in, never committed —
this repo is public.

### 1. Freeze the Nextcloud copy

Check every PC's Nextcloud client shows a green tick. Then in Nextcloud admin →
Team folders → LWVC, set the group to read-only. From here nobody can add
changes to the old copy, so it cannot drift from the new one.

### 2. Seed from the base PC

On the PC whose copy is the base (lwvc1), as yourself:

```bash
NAS_ID=XXXXXXX-... bash syncthing-sharefolder.sh seed
```

Copies the Nextcloud LWVC folder to `~/Documents/ShareFolder`, checks the copy
file by file, and offers the folder to the NAS.

### 3. Accept on the NAS

In the NAS Syncthing GUI, accept the `ShareFolder` folder offered by lwvc1.

- Path: inside a share the Syncthing container already has mapped.
- File Versioning: **Staggered**, max age 365 days.

Wait for it to reach "Up to Date".

### 4. Set up the PCs

In the Landscape paste of `run-from-repo.sh`, above the `SCRIPT=` line:

```bash
export NAS_ID=XXXXXXX-... SHARE_MODE=setup
SCRIPT="${1:-syncthing-sharefolder.sh}"
```

Installs and starts Syncthing for the PC's user, adds the NAS and an empty
`~/Documents/ShareFolder`. The activity output ends with an `ADD ON NAS:` line
carrying that PC's device ID.

### 5. Add each PC on the NAS

Each PC shows up in the NAS GUI as a new device asking to connect. Add it and
tick `ShareFolder` on its Sharing tab. The folder then downloads to the PC.

### 6. Verify

Same Landscape script with `SHARE_MODE=verify`. It compares the PC's old
Nextcloud copy against the new folder.

| Exit | Meaning |
|---|---|
| 0 | Nothing would be lost with the old copy |
| 1 | Files that exist only in the old copy, or are newer there, were copied to `~/Documents/ShareFolder-rescued-from-nextcloud` — move the ones that matter into `ShareFolder` |
| 2 | Not synced yet (or the NAS has not shared the folder with this PC) |

### 7. Remove LWVC from Nextcloud

Once a PC verifies clean, remove that user (or the whole group) from the LWVC
team folder in Nextcloud admin. The desktop client then deletes its local LWVC
copy by itself and carries on syncing everything else.

**Do not delete the old local folder by hand** while the client is running: the
client would treat that as a deletion to sync to the server.

If LWVC was the only thing in someone's Nextcloud folder, the client asks
"Remove all files?" first — the answer is yes.

### 8. Clean up

After a week or two with no surprises: delete the LWVC team folder on the
Nextcloud server and any leftover `ShareFolder-rescued-from-nextcloud` folders.

## Rolling back

Until step 7 nothing has been removed. Set the team folder back to read-write
and the Nextcloud copy is live again; `ShareFolder` can simply be unshared in
Syncthing and deleted.

## Adding a PC later

Run `setup` on it, add the printed device ID on the NAS, share `ShareFolder`.
`SHARE_MODE=status` reports the current state of any PC without changing it.
