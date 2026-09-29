#!/usr/bin/env bash
set -euo pipefail

DRIVER="razer_pwm_pc_fan_controller"
INSTALL_DIR="/usr/local/lib/razer-pwm-pc-fan"
SERVICE="/etc/systemd/system/razer-pwm-pc-fan.service"
COOLER_DROPIN="/etc/systemd/system/coolercontrold.service.d/razer-pwm.conf"

if [[ $EUID -eq 0 ]]; then
    echo "Please run this script as your normal user, not with sudo."
    echo "It will ask for sudo when required."
    exit 1
fi

echo "Razer PWM PC Fan Controller - Bazzite uninstaller"
echo

echo "Stopping and disabling driver service..."
sudo systemctl disable --now razer-pwm-pc-fan.service 2>/dev/null || true

echo "Removing systemd configuration..."
sudo rm -f "$SERVICE"
sudo rm -f "$COOLER_DROPIN"

# Remove the CoolerControl drop-in directory if it is now empty.
if [[ -d "$(dirname "$COOLER_DROPIN")" ]]; then
    sudo rmdir "$(dirname "$COOLER_DROPIN")" 2>/dev/null || true
fi

sudo systemctl daemon-reload

# Unload the driver if it is currently loaded.
if grep -q "^${DRIVER} " /proc/modules; then
    echo "Unloading driver..."
    sudo rmmod "$DRIVER" || {
        echo
        echo "WARNING: The driver could not be unloaded."
        echo "The installed files will still be removed."
        echo "A reboot will completely remove the active driver."
    }
fi

echo "Removing persistent driver files..."
sudo rm -rf "$INSTALL_DIR"

echo
echo "Uninstallation complete."
echo
echo "The Bazzite service, CoolerControl dependency and persistent"
echo "driver files have been removed."
echo
echo "A reboot is recommended."
