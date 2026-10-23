#!/usr/bin/env bash
set -euo pipefail
PKG=razer-pwm-pc-fan
VER=2.12
if [[ $EUID -ne 0 ]]; then echo "Run: sudo ./uninstall_fedora.sh" >&2; exit 1; fi
systemctl disable --now razer-pwm-pc-fan.service 2>/dev/null || true
rm -f /etc/systemd/system/razer-pwm-pc-fan.service
rm -f /etc/systemd/system/coolercontrold.service.d/razer-pwm.conf
rmdir /etc/systemd/system/coolercontrold.service.d 2>/dev/null || true
rm -f /usr/local/sbin/razer-pwm-pc-fan-bind
systemctl daemon-reload
dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
rm -rf "/usr/src/${PKG}-${VER}"
echo "Removed Fedora installation. Reboot recommended."
