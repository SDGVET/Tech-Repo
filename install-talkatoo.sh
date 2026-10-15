#!/usr/bin/env bash
# install-talkatoo.sh — install the Talkatoo desktop app (Windows/Electron) under GE-Proton.
#
# Pushed via Landscape (runs as root, non-interactive). Idempotent: safe to re-run.
# Route follows "Talkatoo on Wine" (Obsidian vault), "Simplified route":
#   - no plain Wine, no .NET; the app is extracted straight out of TalkatooSetup.exe
#   - TalkatooSetup.exe must NOT be run under Proton (65535x65535 window froze Plasma)
#
# Layout (system-wide, root-owned, read-only for users):
#   /opt/talkatoo/proton/GE-Proton11-7-x86_64/   Proton runtime
#   /opt/talkatoo/app-<version>/                 app files (nupkg lib/net45/)
#   /opt/talkatoo/app -> app-<version>           current version
#   /opt/talkatoo/talkatoo-typer                 dictation typing bridge (uinput keyboard), see step 3c
#   /usr/local/bin/talkatoo                      launcher; builds a per-user prefix on first run
#   /etc/udev/rules.d/70-talkatoo-uinput.rules   lets the logged-in seat user open /dev/uinput
#   /usr/share/applications/talkatoo.desktop     menu entry
#
# Per-user prefix: ~/.local/share/talkatoo-proton (created by the launcher, not by this script,
# because DPI must be read from the user's live Plasma session).
#
# Env overrides: TALKATOO_UPDATE=1 re-downloads the installer and installs a newer version if found.

set -euo pipefail

LOG=/var/log/lwvc-install-talkatoo.log
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) install-talkatoo.sh on $(hostname) ==="

PROTON_VER="GE-Proton11-7"
PROTON_NAME="${PROTON_VER}-x86_64"
PROTON_BASE="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_VER}"
INSTALLER_URL="https://storage.googleapis.com/assets.talkatoo.ai/releases/x64/latest/TalkatooSetup.exe"

ROOT=/opt/talkatoo
PROTON_DIR="$ROOT/proton/$PROTON_NAME"
LAUNCHER=/usr/local/bin/talkatoo
DESKTOP=/usr/share/applications/talkatoo.desktop

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 0. Preconditions — skip cleanly (exit 0) on hosts this doesn't apply to (mixed fleet).
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root." >&2
    exit 1
fi
if [[ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ]]; then
    echo "SKIP: not an amd64 Debian/Ubuntu host."
    exit 0
fi

# 1. i386 multiarch + packages.
#    Only libc6:i386 (/lib/ld-linux.so.2) was proven necessary; the rest follow the note's suggestion.
#    p7zip-full provides 7z (to unpack the installer), unzip unpacks the nupkg, python3 is used for DPI
#    and the typing bridge, wl-clipboard lets the bridge paste characters a US keyboard can't type.
if ! dpkg --print-foreign-architectures | grep -qx i386; then
    echo "[1] Enabling i386 architecture"
    dpkg --add-architecture i386
    NEED_UPDATE=1
fi
PKGS=(libc6:i386 libstdc++6:i386 libgl1:i386 libvulkan1:i386 p7zip-full unzip curl python3 wl-clipboard)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || MISSING+=("$p")
done
if (( ${#MISSING[@]} )) || [[ ${NEED_UPDATE:-0} == 1 ]]; then
    echo "[1] Installing: ${MISSING[*]:-(none, apt update only)}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    if (( ${#MISSING[@]} )); then
        apt-get install -y -q --no-install-recommends "${MISSING[@]}"
    fi
else
    echo "[1] i386 arch and packages already present"
fi
SEVENZ=$(command -v 7z || command -v 7zz || true)
[[ -n $SEVENZ ]] || { echo "ERROR: no 7z binary after installing p7zip-full." >&2; exit 1; }

# 2. GE-Proton — download, verify sha512, extract to /opt (Steam not needed).
if [[ -x "$PROTON_DIR/proton" ]]; then
    echo "[2] $PROTON_NAME already installed"
else
    echo "[2] Downloading $PROTON_NAME"
    curl -fsSL --retry 3 -o "$WORK/$PROTON_NAME.tar.gz" "$PROTON_BASE/$PROTON_NAME.tar.gz"
    curl -fsSL --retry 3 -o "$WORK/$PROTON_NAME.sha512sum" "$PROTON_BASE/$PROTON_NAME.sha512sum"
    want=$(awk '{print $1; exit}' "$WORK/$PROTON_NAME.sha512sum")
    have=$(sha512sum "$WORK/$PROTON_NAME.tar.gz" | awk '{print $1}')
    if [[ -z $want || $want != "$have" ]]; then
        echo "ERROR: GE-Proton sha512 mismatch (want $want, got $have)." >&2
        exit 1
    fi
    mkdir -p "$ROOT/proton"
    tar -xzf "$WORK/$PROTON_NAME.tar.gz" -C "$ROOT/proton"
    [[ -x "$PROTON_DIR/proton" ]] || { echo "ERROR: $PROTON_DIR/proton missing after extract." >&2; exit 1; }
    echo "[2] Extracted to $PROTON_DIR"
fi
# Proton takes a lock file in its own directory; pre-create it so non-root users can open it.
touch "$PROTON_DIR/dist.lock"
chmod 0666 "$PROTON_DIR/dist.lock"

# 3. Talkatoo app — pull the nupkg out of the installer (no Wine), verify against RELEASES, unpack.
if [[ -e "$ROOT/app/Talkatoo.exe" && ${TALKATOO_UPDATE:-0} != 1 ]]; then
    echo "[3] Talkatoo already installed ($(readlink "$ROOT/app")); set TALKATOO_UPDATE=1 to check for a newer one"
else
    echo "[3] Downloading TalkatooSetup.exe"
    curl -fsSL --retry 3 -o "$WORK/TalkatooSetup.exe" "$INSTALLER_URL"
    "$SEVENZ" x -y -o"$WORK/setup" "$WORK/TalkatooSetup.exe" '*nupkg' RELEASES >/dev/null
    NUPKG=$(find "$WORK/setup" -name 'talkatoo-*-full.nupkg' | head -n1)
    [[ -n $NUPKG && -f "$WORK/setup/RELEASES" ]] || { echo "ERROR: nupkg/RELEASES not found in installer." >&2; exit 1; }

    # RELEASES lines are: <SHA1> <filename> <size>
    nupkg_file=$(basename "$NUPKG")
    want=$(awk -v f="$nupkg_file" '$2==f {print tolower($1)}' "$WORK/setup/RELEASES" | tr -d '\r\357\273\277')
    have=$(sha1sum "$NUPKG" | awk '{print $1}')
    if [[ -z $want || $want != "$have" ]]; then
        echo "ERROR: $nupkg_file SHA1 mismatch against RELEASES (want $want, got $have)." >&2
        exit 1
    fi

    VER=${nupkg_file#talkatoo-}; VER=${VER%-full.nupkg}
    if [[ -e "$ROOT/app-$VER/Talkatoo.exe" ]]; then
        echo "[3] Talkatoo $VER already installed"
    else
        echo "[3] Installing Talkatoo $VER"
        unzip -q "$NUPKG" 'lib/net45/*' -d "$WORK/nupkg"
        [[ -f "$WORK/nupkg/lib/net45/Talkatoo.exe" ]] || { echo "ERROR: Talkatoo.exe missing from nupkg." >&2; exit 1; }
        rm -rf "$ROOT/app-$VER.tmp"
        mv "$WORK/nupkg/lib/net45" "$ROOT/app-$VER.tmp"
        mv "$ROOT/app-$VER.tmp" "$ROOT/app-$VER"
    fi
    ln -sfn "app-$VER" "$ROOT/app"
fi
chown -R root:root "$ROOT"
chmod -R u=rwX,go=rX "$ROOT"
chmod 0666 "$PROTON_DIR/dist.lock"

# 3b. Icon — the 256px PNG embedded in Talkatoo.exe (resource ICON/4), so the menu and taskbar
#     show the Talkatoo logo instead of a generic one. Runs every time, so existing hosts get it.
ICON=/usr/share/icons/hicolor/256x256/apps/talkatoo.png
rm -rf "$WORK/icon"
"$SEVENZ" e -y -o"$WORK/icon" "$ROOT/app/Talkatoo.exe" '.rsrc/*/ICON/*' >/dev/null 2>&1 || true
ICON_SRC=$(for f in "$WORK"/icon/*; do file -b "$f" | grep -q '^PNG image data, 256 x 256' && { echo "$f"; break; }; done || true)
if [[ -n $ICON_SRC ]]; then
    install -D -m 0644 "$ICON_SRC" "$ICON"
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
    ICON_NAME=talkatoo
    echo "[3b] Installed $ICON"
else
    ICON_NAME=audio-input-microphone
    echo "[3b] WARNING: no 256px icon found in Talkatoo.exe; using a generic icon."
fi

# 3c. Dictation typing bridge. Talkatoo types with Win32 SendInput, which under Wine only reaches other
#     Wine windows, so dictation never landed in native apps (notes worked; they don't type). Fix:
#       - patch the libtkey JS wrapper inside app.asar to append its commands to a spool file when the
#         launcher sets TALKATOO_TYPE_SPOOL (asar integrity validation is fused off in Talkatoo.exe)
#       - talkatoo-typer (started by the launcher) replays that spool through a uinput keyboard
#       - a udev rule gives the logged-in seat user access to /dev/uinput
#     Runs every time and always patches from the pristine app.asar.orig, so existing hosts get it.
echo "[3c] Installing dictation typing bridge"
TYPER=$ROOT/talkatoo-typer
UDEV_RULE=/etc/udev/rules.d/70-talkatoo-uinput.rules
ASAR=$(readlink -f "$ROOT/app")/resources/app.asar

cat > "$TYPER" <<'TYPER_EOF'
#!/usr/bin/env python3
"""Talkatoo typing bridge (installed by install-talkatoo.sh).

Talkatoo types with Win32 SendInput, which under Wine only reaches other Wine windows. The patched
libtkey wrapper in app.asar appends one JSON command per line to a spool file instead; this helper
tails that file and replays the text through a uinput virtual keyboard, so it lands in whatever
native window has focus. Assumes a US keyboard layout.

Usage: talkatoo-typer SPOOL        (TALKATOO_TYPER_DRYRUN=1 prints keys instead of sending them)
"""
import ctypes, fcntl, json, os, shutil, signal, struct, subprocess, sys, time

KEY_DELAY = float(os.environ.get("TALKATOO_KEY_DELAY_MS", "4")) / 1000
DRYRUN = os.environ.get("TALKATOO_TYPER_DRYRUN") == "1"

EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE = 0x405C5503, 0x5501
KEY_BACKSPACE, KEY_TAB, KEY_ENTER, KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_SPACE, KEY_V = 14, 15, 28, 29, 42, 57, 47

# char -> (keycode, shift) for a US layout
KEYMAP = {"\n": (KEY_ENTER, False), "\t": (KEY_TAB, False), " ": (KEY_SPACE, False), "\b": (KEY_BACKSPACE, False)}
for row, base in (("1234567890-=", 2), ("qwertyuiop[]", 16), ("asdfghjkl;'`", 30), ("\\zxcvbnm,./", 43)):
    for i, ch in enumerate(row):
        KEYMAP[ch] = (base + i, False)
for plain, shifted in zip("1234567890-=[];'`\\,./", "!@#$%^&*()_+{}:\"~|<>?"):
    KEYMAP[shifted] = (KEYMAP[plain][0], True)
for ch in "abcdefghijklmnopqrstuvwxyz":
    KEYMAP[ch.upper()] = (KEYMAP[ch][0], True)

# Typographic characters the speech service may emit that have a plain-ASCII equivalent.
ASCII = str.maketrans({"\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"', "\u2013": "-", "\u2014": "-",
                       "\u2026": "...", "\u00a0": " ", "\r": ""})


class Keyboard:
    def __init__(self):
        if DRYRUN:
            return
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in {k for k, _ in KEYMAP.values()} | {KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_V}:
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        # struct uinput_setup { struct input_id {bustype, vendor, product, version}; char name[80]; u32 ff_effects_max; }
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x06, 0x1209, 0x7A1C, 1, b"Talkatoo virtual keyboard", 0))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(1)  # let the compositor pick the device up before the first key

    def _emit(self, code, value):
        if DRYRUN:
            return
        os.write(self.fd, struct.pack("llHHi", 0, 0, EV_KEY, code, value) + struct.pack("llHHi", 0, 0, EV_SYN, 0, 0))
        time.sleep(KEY_DELAY)

    def tap(self, code, shift=False, ctrl=False):
        if DRYRUN:
            print(f"key {code}{' +shift' if shift else ''}{' +ctrl' if ctrl else ''}", flush=True)
        mods = [m for m, on in ((KEY_LEFTCTRL, ctrl), (KEY_LEFTSHIFT, shift)) if on]
        for m in mods:
            self._emit(m, 1)
        self._emit(code, 1)
        self._emit(code, 0)
        for m in reversed(mods):
            self._emit(m, 0)


class Typer:
    def __init__(self, kbd):
        self.kbd = kbd
        self.interim = ""  # text currently on screen for the utterance still being recognised
        self.wl_copy = shutil.which("wl-copy")

    def _put(self, text):
        """Type text; returns what actually reached the screen."""
        done, i = "", 0
        while i < len(text):
            if text[i] in KEYMAP:
                self.kbd.tap(*KEYMAP[text[i]])
                done += text[i]
                i += 1
                continue
            # Run of characters the US layout can't produce: paste it through the clipboard if we can.
            j = i
            while j < len(text) and text[j] not in KEYMAP:
                j += 1
            if self.wl_copy and subprocess.run([self.wl_copy, "--", text[i:j]], timeout=5).returncode == 0:
                time.sleep(0.05)
                self.kbd.tap(KEY_V, ctrl=True)
                time.sleep(0.05)
                done += text[i:j]
            else:
                print(f"talkatoo-typer: cannot type {text[i:j]!r}, skipped", file=sys.stderr, flush=True)
            i = j
        return done

    def handle(self, cmd):
        op, text = cmd.get("op"), str(cmd.get("text") or "").translate(ASCII)
        if op == "type":
            # Each interim result restates the whole utterance: keep the common prefix, retype the rest.
            keep = 0
            while keep < min(len(self.interim), len(text)) and self.interim[keep] == text[keep]:
                keep += 1
            for _ in range(len(self.interim) - keep):
                self.kbd.tap(KEY_BACKSPACE)
            shown = self.interim[:keep] + self._put(text[keep:])
            self.interim = "" if cmd.get("final") else shown
        elif op == "paste":
            self.interim = ""
            self._put(text)
        elif op == "backspace":
            self.kbd.tap(KEY_BACKSPACE)
        elif op == "clear":
            self.interim = ""


def main():
    spool = sys.argv[1]
    lock = os.open(spool + ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0  # another typer already serves this spool
    ctypes.CDLL(None).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG: exit with the launcher
    os.close(os.open(spool, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
    try:
        kbd = Keyboard()
    except OSError as e:
        print(f"talkatoo-typer: cannot open /dev/uinput ({e}); dictation will not type.", file=sys.stderr)
        return 1
    typer = Typer(kbd)
    with open(spool, "r", encoding="utf-8") as f:
        buf = ""
        while True:
            chunk = f.readline()
            if not chunk:
                time.sleep(0.03)
                continue
            buf += chunk
            if not buf.endswith("\n"):
                continue  # line still being written
            line, buf = buf, ""
            try:
                typer.handle(json.loads(line))
            except Exception as e:  # never let one bad line stop dictation
                print(f"talkatoo-typer: {e!r} on {line!r}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main())
TYPER_EOF
chmod 0755 "$TYPER"

cat > "$WORK/libtkey-index.js" <<'SHIM_EOF'
// Patched by install-talkatoo.sh. The stock wrapper types with Win32 SendInput, which under Wine only
// reaches other Wine windows. When the launcher sets TALKATOO_TYPE_SPOOL, hand the text to the Linux
// side instead (talkatoo-typer replays it through a uinput keyboard); otherwise behave as shipped.
const spool = process.env.TALKATOO_TYPE_SPOOL;

if (spool) {
  const fs = require('fs');
  const send = (cmd) => {
    try {
      fs.appendFileSync(spool, JSON.stringify(cmd) + '\n');
    } catch (e) {
      console.error('talkatoo-typer spool write failed', e);
    }
  };
  module.exports = {
    initializeQueue: () => send({ op: 'clear' }),
    clearQueue: () => send({ op: 'clear' }),
    generateKeystroke: (text, final) => send({ op: 'type', text, final: !!final }),
    paste: (text) => send({ op: 'paste', text }),
    backspace: () => send({ op: 'backspace' })
  };
} else {
  const tkey = require('node-gyp-build')(__dirname);
  module.exports = {
    initializeQueue: tkey.tkey_queue_init,
    clearQueue: tkey.tkey_queue_clear,
    generateKeystroke: tkey.tkey_generate_keystroke,
    paste: tkey.tkey_paste,
    backspace: tkey.tkey_backspace
  };
}
SHIM_EOF
[[ -f "$ASAR.orig" ]] || cp -p "$ASAR" "$ASAR.orig"
python3 - "$ASAR.orig" node_modules/@talkatoo/libtkey/index.js "$WORK/libtkey-index.js" "$ASAR.new" <<'PATCH_EOF'
# Replace one file inside an Electron asar archive: ARCHIVE PATH/IN/ARCHIVE NEWFILE OUT
import hashlib, json, struct, sys

archive, inner, newfile, out = sys.argv[1:5]
new = open(newfile, "rb").read()
with open(archive, "rb") as f:
    four, hsize, psize, jlen = struct.unpack("<IIII", f.read(16))
    raw = f.read(jlen)
    header = json.loads(raw)
    base = 8 + hsize
    f.seek(0, 2)
    datalen = f.tell() - base

    node = header
    for part in inner.strip("/").split("/"):
        node = node["files"][part]
    if node.get("unpacked"):
        sys.exit(f"{inner} is unpacked, not stored in the archive")

    digest = hashlib.sha256(new).hexdigest()
    node["size"], node["offset"] = len(new), str(datalen)  # new copy goes after the existing data
    if "integrity" in node:
        node["integrity"] = {"algorithm": "SHA256", "hash": digest, "blockSize": 4194304, "blocks": [digest]}

    js = json.dumps(header, separators=(",", ":")).encode()
    pad = -len(js) % 4
    with open(out, "wb") as o:
        o.write(struct.pack("<IIII", 4, len(js) + pad + 8, len(js) + pad + 4, len(js)) + js + b"\0" * pad)
        f.seek(base)
        while chunk := f.read(1 << 20):
            o.write(chunk)
        o.write(new)
PATCH_EOF
chmod 0644 "$ASAR.new"
mv "$ASAR.new" "$ASAR"

# uaccess rules must sort before 73-seat-late.rules.
cat > "$UDEV_RULE" <<'EOF'
# Talkatoo dictation types through a uinput virtual keyboard (install-talkatoo.sh).
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
EOF
modprobe uinput 2>/dev/null || true
udevadm control --reload
udevadm trigger --action=change /dev/uinput 2>/dev/null || udevadm trigger --subsystem-match=misc || true

# 4. Launcher — per-user prefix, DPI from the Plasma session, PROTON_USE_XALIA=0 (else clicks are ignored).
echo "[4] Writing $LAUNCHER and $DESKTOP"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Talkatoo launcher (installed by install-talkatoo.sh). Builds a per-user Proton prefix on first run.
set -euo pipefail
PROTON_DIR="$PROTON_DIR"
EOF
cat >> "$LAUNCHER" <<'EOF'
PROTON="$PROTON_DIR/proton"
PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/talkatoo-proton"
export STEAM_COMPAT_DATA_PATH="$PREFIX"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"   # need not exist
export PROTON_USE_XALIA=0
export WINEPREFIX="$PREFIX/pfx"

if [[ ${1:-} == --stop ]]; then
    exec "$PROTON_DIR/files/bin/wineserver" -k
fi

mkdir -p "$PREFIX"
if [[ ! -f "$PREFIX/.lwvc-initialised" ]]; then
    # First proton run creates the prefix.
    "$PROTON" run wineboot -u >/dev/null 2>&1 || true

    # Wine defaults to 96 DPI; match the Plasma scale (170% -> 163). TALKATOO_DPI overrides.
    dpi=${TALKATOO_DPI:-}
    if [[ -z $dpi ]] && command -v kscreen-doctor >/dev/null; then
        dpi=$(kscreen-doctor -j 2>/dev/null | python3 -c '
import json, sys
outs = [o for o in json.load(sys.stdin).get("outputs", []) if o.get("enabled")]
print(round(96 * max((o.get("scale") or 1) for o in outs)) if outs else 96)' 2>/dev/null || true)
    fi
    dpi=${dpi:-96}
    "$PROTON" run reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1
    "$PROTON" run reg add 'HKLM\System\CurrentControlSet\Hardware Profiles\Current\Software\Fonts' \
        /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1

    touch "$PREFIX/.lwvc-initialised"
fi

# App lives read-only in /opt; expose it as C:\talkatoo-app (re-pointed each launch so updates apply).
ln -sfn /opt/talkatoo/app "$WINEPREFIX/drive_c/talkatoo-app"

# Dictation typing bridge (see install-talkatoo.sh step 3c). The typer exits when this launcher does.
if [[ -n ${XDG_RUNTIME_DIR:-} && -w /dev/uinput ]]; then
    SPOOL="$XDG_RUNTIME_DIR/talkatoo-type.spool"
    /opt/talkatoo/talkatoo-typer "$SPOOL" &
    export TALKATOO_TYPE_SPOOL="Z:${SPOOL//\//\\}"
fi

exec "$PROTON" run 'C:\talkatoo-app\Talkatoo.exe' "$@"
EOF
chmod 0755 "$LAUNCHER"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Talkatoo
Comment=Talkatoo dictation (runs under Proton)
Exec=$LAUNCHER
Icon=$ICON_NAME
Terminal=false
Categories=Office;AudioVideo;
StartupWMClass=talkatoo.exe
EOF
chmod 0644 "$DESKTOP"
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true

# 5. Verification
echo "[5] Verification"
fail=0
check() { if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fail=1; fi; }
check "i386 arch enabled"          'dpkg --print-foreign-architectures | grep -qx i386'
check "/lib/ld-linux.so.2 present"  '[[ -e /lib/ld-linux.so.2 ]]'
check "Proton executable"          '[[ -x "$PROTON_DIR/proton" ]]'
check "Proton wineserver"          '[[ -x "$PROTON_DIR/files/bin/wineserver" ]]'
check "Talkatoo.exe installed"     '[[ -f "$ROOT/app/Talkatoo.exe" ]]'
check "launcher installed"         '[[ -x "$LAUNCHER" ]]'
check "typing bridge installed"    '[[ -x "$TYPER" ]] && grep -qa TALKATOO_TYPE_SPOOL "$ASAR"'
check "uinput udev rule installed" '[[ -f "$UDEV_RULE" ]]'
check "desktop entry installed"    '[[ -f "$DESKTOP" ]]'
echo "  Installed version: $(readlink "$ROOT/app" 2>/dev/null || echo none)"

if (( fail )); then
    echo "=== FAILED ==="
    exit 1
fi
echo "=== Done. Users launch 'Talkatoo' from the menu; first launch builds their prefix. ==="
