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

## Touch and backlight both fail (official 7" display v1.1)

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
