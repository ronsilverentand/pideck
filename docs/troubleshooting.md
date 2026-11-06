# Troubleshooting

## Quick table

| Symptom | Check / fix |
| --- | --- |
| Black screen, no Chromium | `journalctl -u pideck-kiosk -b`. Usually the user isn't in `video`/`render`/`input`, or `getty@tty1` is still enabled. |
| Stuck before Chromium starts | The launcher waits for Companion. Run `curl -I $(cat /etc/pideck/url)` on the Pi to test the network path / VLAN firewall. |
| Touch offset or mirrored after rotating | Rotate with `wlr-randr` inside `pideck-browser` (not `config.txt`), so cage maps touch to the rotated output. |
| Lightning-bolt icon / random reboots | Undervoltage: use the official 5V 2.5A PSU. Check with `vcgencmd get_throttled` (`0x0` = fine). |
| Sluggish after days of uptime | Chromium memory on a 1 GB Pi. Add a nightly `systemctl restart pideck-kiosk` timer. |
| Buttons go grey | Companion pod restarting or the LB IP changed: `kubectl -n companion get pods,svc`. |
| Mac buttons do nothing | Hammerspoon Console: `401` = token header missing or wrong; nothing logged = Companion can't reach `MAC-IP:8765`. |
| Display dark / `failed to enable backlight: -5` with the PoE+ HAT fitted | Firmware fan control steals the shared I2C controller. Add `dtoverlay=rpi-poe-plus,i2c` to `config.txt`. See [below](#display-dark-with-the-poe-hat-fitted-pi-3b). |

## Display dark with the PoE+ HAT fitted (Pi 3B+)

**Solved 2026-11-04.** This was the root cause of the I2C errors in the next section.

**Symptom:** with the official PoE+ HAT fitted, the display stays dark. `dmesg` shows `failed to enable backlight: -5` and writing to `/sys/class/backlight/10-0045/brightness` gives `Input/output error`. Without the HAT, everything works. It had worked with the same HAT on an earlier OS install.

**Not the cause:**
- Power: the display board measures 5.1 V when powered from the HAT's header. The HAT supplies 5 V at up to 4 A, and the display needs about 0.5 A.
- `disable_poe_fan=1` alone doesn't fix it.

**Cause:** on the Pi 3B+ there is one I2C controller (BSC0), shared between two sets of pins:
- GPIO 0/1 (HAT ID pins): bus 0, used for the PoE+ HAT. The HAT's microcontroller sits at `0x51`, which is the "unexpected device at 51" in the next section.
- GPIO 44/45: bus 10, used for the display (backlight chip `0x45`, touch `0x38`).

The firmware loads `rpi-poe-plus` automatically from the HAT's ID chip (`vclog -m` shows `Loaded overlay 'rpi-poe-plus'`). By default the *firmware* controls the fan over BSC0 and switches the pins to GPIO 0/1 without Linux knowing. Linux thinks the pins are still on 44/45 and doesn't switch them back, so all display I2C traffic goes to the HAT instead.

You can see it with `pinctrl get 0-1,44-45`:

```
# HAT fitted, broken:
 0: a0    -- | hi // ID_SDA/GPIO0 = SDA0
 1: a0    -- | hi // ID_SCL/GPIO1 = SCL0
44: ip    -- | hi // SDA0/GPIO44 = input
45: ip    -- | hi // SCL0/GPIO45 = input
```

Without the HAT, GPIO 0/1 are `ip` and GPIO 44/45 are `a1` (SDA0/SCL0).

**Fix:** let Linux drive the HAT over I2C instead of the firmware, so a single driver (the kernel's I2C mux) switches the pins correctly. In `/boot/firmware/config.txt`:

```
dtoverlay=vc4-kms-v3d
dtoverlay=rpi-poe-plus,i2c
```

Remove any `disable_poe_fan=1`, then reboot. Check the `i2c` parameter exists with `dtoverlay -h rpi-poe-plus`.

**Check after reboot:**
- `dmesg | grep -i backlight`: no `-5` errors.
- `cat /sys/class/thermal/cooling_device*/type`: the PoE fan is listed, so fan control still works. Keep an eye on `vcgencmd measure_temp` for a few days.

**Reinstalling the OS:** a fresh image won't have this line. Add it again, or the display goes dark as soon as the HAT is on.

**Quick manual test without rebooting** (lost at reboot): `sudo pinctrl set 0,1 ip && sudo pinctrl set 44,45 a1`. After that, writing to the backlight works again. The panel only comes on once the display pipeline is set up again, so restart `pideck-kiosk`.

## Touch and backlight both fail (official 7" display v1.1)

> **2026-11-04:** with the PoE+ HAT fitted, the cause of these errors was the I2C conflict above, not a weak physical link. Apply that fix first. Only work through the physical steps below if errors remain after it.

Touch and backlight share the display's I2C link (bus 10 on the Pi). When both fail, look there first.

**Symptoms seen on this build (2026-11-03/04):**

```
edt_ft5x06 10-0038: touchscreen probe failed
edt_ft5x06 10-0038: probe with driver edt_ft5x06 failed with error -5
panel-simple 1.panel_disp: [drm:drm_panel_enable [drm]] failed to enable backlight: -5
```

`echo 128 | sudo tee /sys/class/backlight/10-0045/brightness` → `Input/output error`.

**What was ruled out:**

- Driver/config: `display_auto_detect=1` loads the right overlay. `card0-DSI-1` and `/sys/class/backlight/10-0045` exist.
- Power: `vcgencmd get_throttled` → `0x0`.
- Boot timing: reloading `edt_ft5x06` after boot fails the same way.

**What `sudo modprobe i2c-dev && sudo i2cdetect -y 10` showed:** `UU` at 45 (claimed by the kernel), **nothing at 38** (touch controller not answering), and an unexpected device at `51`. The controller answers at boot, then I/O errors follow. That points to a weak physical link, not software.

**Next steps, in order:**

1. With the Pi unplugged for 30 s: reseat the DSI ribbon at both ends (Pi end in **DISPLAY**, not CAMERA; straight, fully in, latch closed). Reseat the two thin ribbons from the glass to the adapter board; the narrow one is touch.
2. On the adapter board connect only **5V and GND** to the Pi. No SDA/SCL jumpers on a Pi 3.
3. Unplug any camera module (it shares bus 10).
4. Slow the bus down: add `dtparam=i2c_vc_baudrate=50000` to `/boot/firmware/config.txt` (try `10000` if it partly helps).
5. Swap the DSI ribbon (15-pin, same as a camera cable).
6. Still no `38` in `i2cdetect`: the adapter board or the touch flex is likely faulty, so it's a warranty case.

**Display completely gone after reseating** (`card0-DSI-1` missing, nothing in `dmesg`): auto-detect got no answer at boot. Check the 5V/GND jumpers (no backlight glow at all) or the ribbon seating (glow but no image).

Screen control (`pi/screen`) needs this fixed: until then it starts, but can't change brightness, and wake on touch stays inactive.
