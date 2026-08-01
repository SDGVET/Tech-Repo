#!/bin/bash
set -e

# Installs Planify (io.github.alainm23.planify), a GTK to-do/task manager.
# Prefers the AUR package (native pacman-managed, updates with the rest of the
# system); falls back to Flatpak (Flathub) if no AUR helper (paru/yay) is found.
#
# Distro: CachyOS / Arch-based systems.
#
# Usage:
#   ./install-planify.sh            # auto: AUR if a helper is present, else Flatpak
#   ./install-planify.sh --aur      # force AUR (fails if no helper found)
#   ./install-planify.sh --flatpak  # force Flatpak

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if ! grep -qiE "arch|cachyos" /etc/os-release 2>/dev/null; then
    echo -e "${YELLOW}Warning: this doesn't look like an Arch-based system. Continuing anyway.${NC}"
fi

MODE="auto"
case "$1" in
    --aur)     MODE="aur" ;;
    --flatpak) MODE="flatpak" ;;
    "")        ;;
    *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
esac

install_aur() {
    local helper=""
    for h in paru yay; do
        command -v "$h" &>/dev/null && helper="$h" && break
    done
    if [[ -z "$helper" ]]; then
        echo -e "${YELLOW}No AUR helper (paru/yay) found.${NC}"
        return 1
    fi
    echo -e "${GREEN}Installing planify via $helper...${NC}"
    "$helper" -S --noconfirm planify
}

install_flatpak() {
    if ! command -v flatpak &>/dev/null; then
        echo -e "${RED}flatpak not found. Install it first: sudo pacman -S flatpak${NC}"
        exit 1
    fi
    if ! flatpak remote-list | grep -q flathub; then
        echo -e "${YELLOW}Adding Flathub remote...${NC}"
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    flatpak install -y flathub io.github.alainm23.planify
    echo -e "${GREEN}Planify installed via Flatpak. Launch: flatpak run io.github.alainm23.planify${NC}"
}

case "$MODE" in
    aur)
        install_aur || { echo -e "${RED}AUR install failed/unavailable.${NC}"; exit 1; }
        ;;
    flatpak)
        install_flatpak
        ;;
    auto)
        if install_aur; then
            :
        else
            echo -e "${YELLOW}Falling back to Flatpak...${NC}"
            install_flatpak
        fi
        ;;
esac
