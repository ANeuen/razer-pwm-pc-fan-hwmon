#!/usr/bin/env bash
set -euo pipefail

# Fedora (DNF-based, non-Atomic) installer for Razer PWM PC Fan Controller.
PKG=razer-pwm-pc-fan
VER=2.12
MOD=razer_pwm_pc_fan_controller
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DST="/usr/src/${PKG}-${VER}"
SERVICE=/etc/systemd/system/razer-pwm-pc-fan.service
HELPER=/usr/local/sbin/razer-pwm-pc-fan-bind
DROPIN=/etc/systemd/system/coolercontrold.service.d/razer-pwm.conf

if [[ ${EUID} -ne 0 ]]; then
  echo "Run: sudo ./install_fedora.sh" >&2
  exit 1
fi
if [[ ! -f /etc/fedora-release ]] || command -v rpm-ostree >/dev/null 2>&1; then
  echo "This installer is for regular Fedora, not Fedora Atomic/Bazzite." >&2
  exit 1
fi
for file in Makefile dkms.conf razer_pwm_pc_fan_controller.c; do
  [[ -f "$SRC/$file" ]] || { echo "Missing $SRC/$file" >&2; exit 1; }
done
echo "[1/5] Installing build dependencies..."
dnf install -y dkms gcc make "kernel-devel-$(uname -r)" elfutils-libelf-devel lm_sensors
[[ -e "/lib/modules/$(uname -r)/build" ]] || { echo "Missing matching kernel-devel. Update/reboot, then retry." >&2; exit 1; }

echo "[2/5] Registering module with DKMS..."
install -d "$DST"
install -m 0644 "$SRC/Makefile" "$SRC/dkms.conf" "$SRC/razer_pwm_pc_fan_controller.c" "$DST/"
if ! dkms status -m "$PKG" -v "$VER" 2>/dev/null | grep -q .; then
  dkms add -m "$PKG" -v "$VER"
fi
dkms install -m "$PKG" -v "$VER" -k "$(uname -r)" --force
depmod -a
modprobe "$MOD"

echo "[3/5] Installing safe HID interface-00 binding helper..."
cat >"$HELPER" <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
MOD=razer_pwm_pc_fan_controller
modprobe "$MOD"
found=0
for dev in /sys/bus/hid/devices/0003:1532:0F3C.*; do
  [[ -e "$dev" ]] || continue
  usbintf="$(dirname "$(readlink -f "$dev")")"
  [[ -r "$usbintf/bInterfaceNumber" ]] || continue
  [[ "$(cat "$usbintf/bInterfaceNumber")" == "00" ]] || continue
  found=1
  id="$(basename "$dev")"
  if [[ -L "$dev/driver" ]]; then
    bound="$(basename "$(readlink -f "$dev/driver")")"
    [[ "$bound" == "$MOD" ]] && { echo "$id already bound"; exit 0; }
    printf '%s' "$id" > "$dev/driver/unbind"
  fi
  # Probe only this interface; do not blacklist hid-generic globally.
  printf '%s' "$MOD" > "$dev/driver_override"
  printf '%s' "$id" > /sys/bus/hid/drivers_probe
  [[ -L "$dev/driver" ]] && [[ "$(basename "$(readlink -f "$dev/driver")")" == "$MOD" ]] && {
    echo "$id bound to $MOD"
    exit 0
  }
  echo "Unable to bind $id to $MOD" >&2
  exit 1
done
if (( ! found )); then
  echo "Razer USB HID interface 00 not found; connect controller and restart service." >&2
  exit 1
fi
HELPER_EOF
chmod 0755 "$HELPER"

echo "[4/5] Enabling boot service and CoolerControl ordering..."
cat >"$SERVICE" <<'SERVICE_EOF'
[Unit]
Description=Bind Razer PWM PC Fan Controller HID interface
After=systemd-udevd.service
Before=coolercontrold.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/razer-pwm-pc-fan-bind
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF
install -d "$(dirname "$DROPIN")"
cat >"$DROPIN" <<'DROPIN_EOF'
[Unit]
Wants=razer-pwm-pc-fan.service
After=razer-pwm-pc-fan.service
DROPIN_EOF
systemctl daemon-reload
systemctl enable razer-pwm-pc-fan.service

echo "[5/5] Testing..."
if systemctl restart razer-pwm-pc-fan.service; then
  echo "Razer controller bound successfully."
else
  echo "Driver installed; binding needs attention (or controller is unplugged)." >&2
  systemctl status razer-pwm-pc-fan.service --no-pager -l || true
fi
echo "DKMS: $(dkms status -m "$PKG" -v "$VER" || true)"
echo "Secure Boot: unsigned modules may be blocked; enroll a DKMS signing key if enabled."
echo "Reboot to verify persistence. CoolerControl itself is installed separately."
