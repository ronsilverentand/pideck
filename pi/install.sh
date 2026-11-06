#!/usr/bin/env bash
# Install PiDeck on a Raspberry Pi running Raspberry Pi OS Lite (64-bit).
#
#   sudo ./pi/install.sh kiosk    # cage + Chromium kiosk on the Companion emulator page
#   sudo ./pi/install.sh screen   # Home Assistant screen control (MQTT) + wake on touch
#   sudo ./pi/install.sh all
#
# Safe to run again: existing /etc/pideck/url and /etc/pideck/screen.env are kept.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIOSK_USER="${KIOSK_USER:-pideck}"
WHAT="${1:-all}"

die() { echo "error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
if command -v raspi-config >/dev/null && [[ "$(raspi-config nonint get_overlay_now)" == "0" ]]; then
  die "the read-only overlay is active; disable it (sudo raspi-config nonint do_overlayfs 1), reboot, then run this again"
fi
mkdir -p /etc/pideck

install_kiosk() {
  echo "==> kiosk"
  id "$KIOSK_USER" >/dev/null 2>&1 || die "user '$KIOSK_USER' does not exist (set KIOSK_USER=...)"
  apt-get update
  if apt-cache show chromium >/dev/null 2>&1; then BROWSER_PKG=chromium; else BROWSER_PKG=chromium-browser; fi
  apt-get install -y --no-install-recommends cage "$BROWSER_PKG" wlr-randr curl
  usermod -aG video,render,input "$KIOSK_USER"

  install -m 755 "$HERE/kiosk/pideck-browser" /usr/local/bin/pideck-browser
  install -m 644 "$HERE/kiosk/pideck-kiosk.service" /etc/systemd/system/pideck-kiosk.service
  sed -i "s/^User=.*/User=$KIOSK_USER/" /etc/systemd/system/pideck-kiosk.service
  [[ -f /etc/pideck/url ]] || install -m 644 "$HERE/kiosk/url.example" /etc/pideck/url

  # Keep the text console from blanking
  CMDLINE=/boot/firmware/cmdline.txt
  if [[ -f $CMDLINE ]] && ! grep -q 'consoleblank=0' "$CMDLINE"; then
    sed -i '1 s/$/ consoleblank=0/' "$CMDLINE"
  fi

  systemctl disable getty@tty1 || true
  systemctl set-default graphical.target
  systemctl daemon-reload
  systemctl enable --now pideck-kiosk
  echo "    kiosk URL: $(cat /etc/pideck/url)  (edit /etc/pideck/url, then: systemctl restart pideck-kiosk)"
}

install_screen() {
  echo "==> screen control"
  apt-get install -y python3-paho-mqtt python3-evdev
  install -m 755 "$HERE/screen/pideck-screen" /usr/local/bin/pideck-screen
  install -m 644 "$HERE/screen/pideck-screen.service" /etc/systemd/system/pideck-screen.service
  if [[ ! -f /etc/pideck/screen.env ]]; then
    install -m 600 "$HERE/screen/screen.env.example" /etc/pideck/screen.env
    echo "    created /etc/pideck/screen.env - set MQTT_PASSWORD, then: systemctl restart pideck-screen"
  fi
  systemctl daemon-reload
  systemctl enable --now pideck-screen
}

case "$WHAT" in
  kiosk) install_kiosk ;;
  screen) install_screen ;;
  all) install_kiosk; install_screen ;;
  *) die "usage: $0 [kiosk|screen|all]" ;;
esac

echo "Done. When everything works, make the SD card read-only:"
echo "  sudo raspi-config nonint do_overlayfs 0 && sudo reboot"
