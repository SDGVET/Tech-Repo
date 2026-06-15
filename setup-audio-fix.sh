#!/bin/bash
set -e

# Fixes stereo speakers losing a channel after USB audio headset is unplugged.
# Creates a udev rule + systemd user service that resets the built-in card profile on unplug.
#
# Usage:
#   sudo ./setup-audio-fix.sh [--user USERNAME] [--usb-id VENDOR:PRODUCT]
#
#   --user     Username to configure (auto-detected from session if omitted)
#   --usb-id   Specific headset USB ID to match, e.g. 047f:c055
#              (omit to match ANY USB audio device — recommended for mixed fleets)
#
# Landscape example (any USB audio device):
#   sudo bash setup-audio-fix.sh
#
# Landscape example (specific headset):
#   sudo bash setup-audio-fix.sh --usb-id 047f:c055

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run with sudo: sudo $0${NC}"
    exit 1
fi

USB_ID=""
USER_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)   USER_NAME="$2"; shift 2 ;;
        --usb-id) USB_ID="$2";    shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# Auto-detect user from sudo context or active graphical session
if [[ -z "$USER_NAME" ]]; then
    USER_NAME="${SUDO_USER:-$(logname 2>/dev/null)}"
fi
if [[ -z "$USER_NAME" || "$USER_NAME" == "root" ]]; then
    USER_NAME=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v root | head -1)
fi
if [[ -z "$USER_NAME" ]]; then
    echo -e "${RED}Could not detect user. Pass --user USERNAME.${NC}"
    exit 1
fi

USER_UID=$(id -u "$USER_NAME")
echo -e "${GREEN}Configuring audio fix for: $USER_NAME (UID: $USER_UID)${NC}"

# Build udev match — specific device or any USB audio device
if [[ -n "$USB_ID" ]]; then
    VENDOR_ID=$(echo "$USB_ID" | cut -d: -f1)
    PRODUCT_ID=$(echo "$USB_ID" | cut -d: -f2)
    if [[ ! "$VENDOR_ID" =~ ^[0-9a-fA-F]{4}$ ]] || [[ ! "$PRODUCT_ID" =~ ^[0-9a-fA-F]{4}$ ]]; then
        echo -e "${RED}Invalid USB ID. Expected xxxx:xxxx hex format.${NC}"
        exit 1
    fi
    UDEV_MATCH="SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"$VENDOR_ID\", ATTRS{idProduct}==\"$PRODUCT_ID\""
    echo "Trigger: USB device $VENDOR_ID:$PRODUCT_ID removal"
else
    UDEV_MATCH="SUBSYSTEM==\"usb\", ENV{ID_USB_DRIVER}==\"snd-usb-audio\""
    echo "Trigger: any USB audio device removal"
fi

# Auto-detect built-in PCI audio card
echo -e "\n${YELLOW}Detecting built-in audio card...${NC}"
CARD_NAME=$(sudo -u "$USER_NAME" XDG_RUNTIME_DIR=/run/user/${USER_UID} pactl list cards short 2>/dev/null \
    | grep "alsa_card.pci" | awk '{print $2}' | head -1)

if [[ -z "$CARD_NAME" ]]; then
    echo -e "${RED}Could not detect built-in audio card. Is PipeWire running for $USER_NAME?${NC}"
    echo "Available cards:"
    sudo -u "$USER_NAME" XDG_RUNTIME_DIR=/run/user/${USER_UID} pactl list cards short 2>/dev/null || true
    exit 1
fi
echo "Audio card: $CARD_NAME"

# Create systemd user service
SERVICE_DIR="/home/${USER_NAME}/.config/systemd/user"
mkdir -p "$SERVICE_DIR"

cat > "${SERVICE_DIR}/audio-fix.service" << EOF
[Unit]
Description=Reset audio card profile after USB headset unplug

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 1
ExecStart=/usr/bin/pactl set-card-profile ${CARD_NAME} off
ExecStart=/usr/bin/pactl set-card-profile ${CARD_NAME} output:analog-stereo
EOF

chown -R "$USER_NAME:$USER_NAME" "$SERVICE_DIR"
sudo -u "$USER_NAME" XDG_RUNTIME_DIR=/run/user/${USER_UID} systemctl --user daemon-reload

# Create udev rule
cat > /etc/udev/rules.d/99-headset-audio-fix.rules << EOF
ACTION=="remove", ${UDEV_MATCH}, RUN+="/usr/bin/systemctl --machine=${USER_NAME}@.host --user start audio-fix.service"
EOF

udevadm control --reload-rules

echo -e "\n${GREEN}Done!${NC}"
echo "  Udev rule : /etc/udev/rules.d/99-headset-audio-fix.rules"
echo "  Service   : ${SERVICE_DIR}/audio-fix.service"
echo ""
echo "Check logs after unplugging headset:"
echo "  journalctl --user -u audio-fix.service -n 20"
