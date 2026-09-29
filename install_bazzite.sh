#!/usr/bin/env bash
set -euo pipefail

# Bazzite installer for the Razer PWM PC Fan Controller hwmon driver
# USB ID: 1532:0f3c

DRIVER="razer_pwm_pc_fan_controller"
INSTALL_DIR="/usr/local/lib/razer-pwm-pc-fan"
SERVICE="/etc/systemd/system/razer-pwm-pc-fan.service"
COOLER_DROPIN="/etc/systemd/system/coolercontrold.service.d/razer-pwm.conf"

if [[ $EUID -eq 0 ]]; then
    echo "Please run this script as your normal user, not with sudo."
    echo "It will ask for sudo when required."
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "Razer PWM PC Fan Controller - Bazzite installer"
echo

# Make sure the source files are present.
if [[ ! -f "$SCRIPT_DIR/razer_pwm_pc_fan_controller.c" ||
      ! -f "$SCRIPT_DIR/Makefile" ]]; then
    echo "ERROR: Driver source or Makefile not found."
    echo "Run this installer from the driver repository."
    exit 1
fi

# Make sure the running kernel has a build tree.
if [[ ! -e "/lib/modules/$(uname -r)/build" ]]; then
    echo "ERROR: Kernel build files are not available for:"
    echo "  $(uname -r)"
    exit 1
fi

echo "Installing persistent driver files..."
sudo mkdir -p "$INSTALL_DIR"

sudo install -m 0644 \
    "$SCRIPT_DIR/razer_pwm_pc_fan_controller.c" \
    "$INSTALL_DIR/razer_pwm_pc_fan_controller.c"

sudo install -m 0644 \
    "$SCRIPT_DIR/Makefile" \
    "$INSTALL_DIR/Makefile"

# Create the boot helper. It rebuilds when the running kernel changes,
# loads the module, then makes sure only HID interface 0 is claimed.
sudo tee "$INSTALL_DIR/load-driver.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DRIVER="razer_pwm_pc_fan_controller"
INSTALL_DIR="/usr/local/lib/razer-pwm-pc-fan"
KERNEL="$(uname -r)"
STAMP="$INSTALL_DIR/.built-for-kernel"

cd "$INSTALL_DIR"

if [[ ! -e "/lib/modules/$KERNEL/build" ]]; then
    echo "Kernel build tree missing for $KERNEL" >&2
    exit 1
fi

# Rebuild if there is no module or it was built for another kernel.
if [[ ! -f "$DRIVER.ko" ||
      ! -f "$STAMP" ||
      "$(cat "$STAMP" 2>/dev/null || true)" != "$KERNEL" ]]; then
    echo "Building Razer PWM driver for $KERNEL..."
    make clean || true
    make -C "/lib/modules/$KERNEL/build" M="$INSTALL_DIR" modules
    printf '%s\n' "$KERNEL" > "$STAMP"
fi

# Bazzite/Fedora SELinux requires kernel modules to have the
# modules_object_t type before they can be loaded.
chcon -t modules_object_t "$INSTALL_DIR/$DRIVER.ko"

# Load the module if it isn't already loaded.
if ! grep -q "^${DRIVER} " /proc/modules; then
    insmod "$INSTALL_DIR/$DRIVER.ko"
fi

# Give the USB/HID device time to appear during boot.
for i in {1..20}; do
    compgen -G '/sys/bus/hid/devices/0003:1532:0F3C.*' >/dev/null && break
    sleep 0.5
done

# Find the Razer HID interface whose USB interface number is 0.
# The HID instance suffix (.000D, etc.) can change between boots.
for dev in /sys/bus/hid/devices/0003:1532:0F3C.*; do
    [[ -e "$dev" ]] || continue

    real_dev="$(readlink -f "$dev")"
    intf="$(dirname "$real_dev")"

    [[ -r "$intf/bInterfaceNumber" ]] || continue

    if [[ "$(cat "$intf/bInterfaceNumber")" != "00" ]]; then
        continue
    fi

    hid_id="$(basename "$dev")"

    # If another HID driver owns interface 0, release it first.
    if [[ -L "$dev/driver" ]]; then
        current_driver="$(basename "$(readlink "$dev/driver")")"

        if [[ "$current_driver" != "$DRIVER" ]]; then
            printf '%s' "$hid_id" > "$dev/driver/unbind"
        fi
    fi

# The module should automatically claim interface 0.
# Verify that it did so successfully.
if [[ ! -L "$dev/driver" ]]; then
    echo "Razer fan-control interface $hid_id has no driver." >&2
    exit 1
fi

current_driver="$(basename "$(readlink "$dev/driver")")"

if [[ "$current_driver" != "$DRIVER" ]]; then
    echo "Razer fan-control interface $hid_id is bound to $current_driver, not $DRIVER." >&2
    exit 1
fi

echo "Razer fan-control interface $hid_id successfully bound to $DRIVER."

    exit 0
done

echo "Razer PWM fan-control HID interface was not found." >&2
exit 1
EOF

sudo chmod 0755 "$INSTALL_DIR/load-driver.sh"

echo "Creating systemd service..."

sudo tee "$SERVICE" >/dev/null <<'EOF'
[Unit]
Description=Razer PWM PC Fan Controller hwmon driver
After=systemd-udevd.service
Before=coolercontrold.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/razer-pwm-pc-fan/load-driver.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Also explicitly make CoolerControl wait for our setup when both are enabled.
sudo mkdir -p "$(dirname "$COOLER_DROPIN")"

sudo tee "$COOLER_DROPIN" >/dev/null <<'EOF'
[Unit]
After=razer-pwm-pc-fan.service
Wants=razer-pwm-pc-fan.service
EOF

echo "Enabling driver service..."
sudo systemctl daemon-reload
sudo systemctl enable razer-pwm-pc-fan.service

echo
echo "Installation complete."
echo
echo "The driver source is stored persistently in:"
echo "  $INSTALL_DIR"
echo
echo "On boot, the service will:"
echo "  - rebuild the module if the running kernel changed"
echo "  - load the driver"
echo "  - verify the Razer fan-control HID interface is using the driver"
echo "  - leave the other Razer HID interface alone"
echo "  - start before CoolerControl"
echo
echo "A reboot is recommended to test the complete boot-time setup."
