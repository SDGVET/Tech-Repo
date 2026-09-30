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
#   /usr/local/bin/talkatoo                      launcher; builds a per-user prefix on first run
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
#    p7zip-full provides 7z (to unpack the installer), unzip unpacks the nupkg, python3 is used for DPI.
if ! dpkg --print-foreign-architectures | grep -qx i386; then
    echo "[1] Enabling i386 architecture"
    dpkg --add-architecture i386
    NEED_UPDATE=1
fi
PKGS=(libc6:i386 libstdc++6:i386 libgl1:i386 libvulkan1:i386 p7zip-full unzip curl python3)
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

exec "$PROTON" run 'C:\talkatoo-app\Talkatoo.exe' "$@"
EOF
chmod 0755 "$LAUNCHER"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Talkatoo
Comment=Talkatoo dictation (runs under Proton)
Exec=$LAUNCHER
Icon=audio-input-microphone
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
check "desktop entry installed"    '[[ -f "$DESKTOP" ]]'
echo "  Installed version: $(readlink "$ROOT/app" 2>/dev/null || echo none)"

if (( fail )); then
    echo "=== FAILED ==="
    exit 1
fi
echo "=== Done. Users launch 'Talkatoo' from the menu; first launch builds their prefix. ==="
