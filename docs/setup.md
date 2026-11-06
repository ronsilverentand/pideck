# Setup

Order: Companion first (Part 2), so the Pi has something to show, then the Pi, then the extras. Each part links to the files in this repo.

## Part 1 — Companion on the cluster

On silverswarm/Ingber, Companion is deployed through the Kustodian template `templates/06-home/06.14-companion` in `silverswarm/clusters` (issue [#1182](https://github.com/silverswarm/clusters/issues/1182)): Longhorn volume on the critical backup tier, MetalLB IP **192.168.10.112** for the Pi, Headscale ingress `companion.si.silverswarm.online` for the admin UI.

For a plain cluster without Kustodian, `k8s/companion.yaml` has an equivalent standalone manifest.

After deploy, in the Companion UI:

1. **Settings → Admin UI password**: set one. The LB IP exposes the admin UI on the LAN.
2. **Connections → Home Assistant Server**: `http://home-assistant.home-assistant.svc.cluster.local:8123` + a long-lived token named `companion`.
3. **Surfaces → add emulator** with ID `pideck`, grid **5 × 3**.
4. Check `http://192.168.10.112:8000/emulator/pideck` in a browser.

## Part 2 — The Pi

Hardware: Raspberry Pi 3B+, official 7" Touch Display (v1.1 adapter board), official 5V 2.5A PSU, Ethernet.

1. Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)**. Customisation: hostname `pideck`, user `pideck`, your SSH key, locale Europe/Amsterdam.
2. Connect the display: DSI ribbon in the **DISPLAY** connector, jumpers **5V and GND only**.
3. Give `pideck` a DHCP reservation on a VLAN that can reach `192.168.10.112:8000` (and `192.168.10.120:1883` for screen control).
4. On the Pi:

```bash
sudo apt update && sudo apt full-upgrade -y && sudo apt install -y git
git clone https://github.com/ronsilverentand/pideck.git && cd pideck
sudo ./pi/install.sh kiosk
```

`install.sh kiosk` installs cage, Chromium, `pideck-browser` and `pideck-kiosk.service`, sets `/etc/pideck/url` to the emulator page, stops console blanking and boots straight into the kiosk. To change the URL: edit `/etc/pideck/url`, then `sudo systemctl restart pideck-kiosk`.

**Check:** after a reboot the screen goes straight to the button grid, `systemctl status pideck-kiosk` is active, and touch registers where you tap. If touch or brightness don't work, see [troubleshooting](troubleshooting.md).

**Last step, once everything works:** make the SD card read-only so a power cut can't corrupt it.

```bash
sudo raspi-config nonint do_overlayfs 0 && sudo reboot
```

Turn it off again (`do_overlayfs 1` + reboot) before updates or config changes. `install.sh` refuses to run while it's active.

## Part 3 — MacBook control

See [`mac/hammerspoon/README.md`](../mac/hammerspoon/README.md) for Hammerspoon, and [`companion/README.md`](../companion/README.md) for the Mac page and its buttons.

## Part 4 — Screen control from Home Assistant

`pi/screen/pideck-screen` publishes the display as `light.pideck_screen` through MQTT discovery and wakes the screen on touch. The waking tap is swallowed, so it doesn't press a button.

| Need | How |
| --- | --- |
| Dim the screen | `light.turn_on` with `brightness_pct` |
| Switch it off | `light.turn_off` (brightness is remembered) |
| Auto dim at night | automation in `homeassistant/automations.yaml` |
| Wake on presence | automation on an occupancy sensor; touch also wakes it |

1. Create a Mosquitto user `pideck`, the same way as the other MQTT users in the `06.5-mosquitto` template.
2. On the Pi: `sudo ./pi/install.sh screen`, put the password in `/etc/pideck/screen.env`, then `sudo systemctl restart pideck-screen`.
3. `journalctl -u pideck-screen -f` should show the backlight device, `MQTT connected` and the touch device. A **PiDeck** device with a **Screen** light appears in HA.
4. Add `homeassistant/automations.yaml` to HA and replace `binary_sensor.ROOM_OCCUPANCY`.

Without HA: `WAKE_ON_TOUCH=1` works on its own, and `IDLE_DIM_AFTER=300` dims after 5 minutes without touch.

The service runs as root (it writes to `/sys/class/backlight` and grabs the touchscreen while the screen is off). When it stops, it always restores the screen to its last brightness.
