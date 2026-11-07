# MacBook control with Hammerspoon

`init.lua` runs a small HTTP API in Hammerspoon that Companion buttons call. It also pushes the Mac's volume, mute, brightness and frontmost app to Companion custom variables, so buttons can show live state. Every request must carry `Authorization: Bearer <token>`.

## Install

```bash
brew install --cask hammerspoon
```

1. Open Hammerspoon, grant **Accessibility** (System Settings → Privacy & Security → Accessibility), and tick **Launch Hammerspoon at login**.
2. Copy `init.lua` to `~/.hammerspoon/init.lua`. If you already have one, save it as `~/.hammerspoon/pideck.lua` and add `require("pideck")` to your own `init.lua`.
3. Copy `pideck-secret.lua.example` to `~/.hammerspoon/pideck-secret.lua` and set a token (`openssl rand -hex 24`).
4. Hammerspoon menu-bar icon → **Reload Config**. The Console should show `PiDeck API listening on port 8765`.
5. Test:

```bash
TOKEN=...
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8765/status
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:8765/volume/set/30
```

## Network

- Give the MacBook a DHCP reservation in UniFi, and set **Private Wi-Fi address** to **Fixed** for the home network (Wi-Fi → Details). Otherwise the MAC address, and with it the reservation, changes.
- If the macOS firewall is on, allow incoming connections for Hammerspoon.
- The Companion pod must reach `MAC-IP:8765`.

## API routes

Every route accepts GET or POST and returns JSON.

| Route | Does |
| --- | --- |
| `/status` | Volume, mute, built-in brightness, frontmost app, and `screens`: every display with its number, name, brightness and usable size |
| `/volume/up` · `/volume/down` · `/volume/mute` · `/volume/set/30` | Output volume (steps of 6.25 = one macOS step) |
| `/brightness/up` · `/brightness/down` · `/brightness/set/60` | Brightness of **all** displays (up/down in steps of 10, each from its own level) |
| `/brightness/up/DELL` · `/brightness/set/60/2` · `/brightness/down/builtin` | Brightness of one display: number (left to right), `builtin`, `main` or part of its name |
| `/app/Visual%20Studio%20Code` · `/quit/Slack` | Launch or focus an app, or quit it |
| `/window/left` · `right` · `top` · `bottom` · `max` · `center` | Move the focused window |
| `/window/top-left` (and the other quarters) · `left-third` · `center-third` · `right-third` | Quarters and thirds |
| `POST /window/set` + JSON body | Exact position and size, see below |
| `/window/frame/0/0/1200/800` · `/window/frame/0/0/1200/800/DELL` | Same in the URL: x, y, width, height in points, optional screen at the end |
| `/screens` | Just the `screens` part of `/status` |
| `/window/next-screen` · `/window/fullscreen` | Move to the next display, toggle full screen |
| `/media/play` · `/media/next` · `/media/previous` | Media keys |
| `/darkmode` · `/lock` · `/displaysleep` | Toggle dark mode, lock screen, display off |
| `/icons` | Lists the Dock apps (pinned + running), by the name `/app/<name>` expects |
| `/icons/export` · `/icons/export/72` | Saves every Dock app's icon as a PNG (default 144 px) to `~/Desktop/PiDeck icons` and opens the folder |
| `/shortcut/Name%20of%20Shortcut` | Run a macOS Shortcuts shortcut |

### Move and resize a window: `POST /window/set`

Send a JSON body (content type `application/json`). Every field is optional; a missing field keeps the window's current value.

| Field | Meaning |
| --- | --- |
| `x`, `y` | Position of the top-left corner, relative to the screen's usable area (below the menu bar, beside the Dock) |
| `w`, `h` | Width and height |
| `unit` | `true`: x/y/w/h are fractions 0–1 of the usable area. Default: points |
| `screen` | `1`, `2`, … (displays left to right), `"main"`, `"next"`, or part of the display's name (`"DELL"`, `"Built-in"`). Default: the window's current screen |
| `app` | Move this app's main window instead of the focused window, e.g. `"Slack"` |

```json
{"x": 0, "y": 0, "w": 1200, "h": 800}
{"x": 0.25, "y": 0, "w": 0.5, "h": 1, "unit": true}
{"screen": "DELL", "x": 0, "y": 0, "w": 0.5, "h": 1, "unit": true}
{"app": "Slack", "screen": 2, "x": 0.66, "y": 0, "w": 0.34, "h": 1, "unit": true}
{"w": 1000}
```

The response returns the frame the window actually got (apps can enforce a minimum size): `{"ok":true,"screen":"…","frame":{"x":…,"y":…,"w":…,"h":…}}`.

In Companion, the body field can use variables, so the sizing lives in Companion: `{"x": $(custom:win_x), "y": $(custom:win_y), "w": $(custom:win_w), "h": $(custom:win_h)}`.

### Brightness of external monitors

The built-in display works out of the box. External monitors are controlled over DDC with [m1ddc](https://github.com/waydabber/m1ddc):

```bash
brew install m1ddc
m1ddc display list      # your monitor should be listed
m1ddc display 1 set luminance 50
```

- Enable DDC/CI in the monitor's own on-screen menu if nothing happens.
- USB-C/DisplayPort is the safest connection. DDC over the Mac's own HDMI port doesn't work on every Mac.
- Hammerspoon matches each display to m1ddc by UUID, then by name. A different install path goes in `pideck-secret.lua` as `m1ddc = "/path/to/m1ddc"`.
- Reading a monitor's brightness over DDC is slow, so it's read once and then remembered. If you change it with the monitor's own buttons, `/status` shows the old value until the displays change or Hammerspoon reloads.
- A display without control (no DDC, or m1ddc missing) has no `brightness` in `/status`, and brightness calls report `"ok": false` for it.

## State pushed to Companion

| Variable | Value |
| --- | --- |
| `mac_volume`, `mac_muted` | Output volume 0–100, 1 when muted |
| `mac_brightness` | Built-in display brightness 0–100 |
| `mac_app`, `mac_online` | Frontmost app; 0 when the Mac sleeps |
| `mac_screen_count` | Number of connected displays |
| `mac_screen_1_name`, `mac_screen_2_name`, … | Display name, numbered left to right |
| `mac_brightness_1`, `mac_brightness_2`, … | Brightness per display (empty if it can't be controlled) |
| `mac_screens` | The whole display list as JSON, the same as `/screens` |

Values are sent on every change, brightness is polled every 5 s, and everything is resent every 60 s. When a display is plugged in, unplugged or rearranged, the display variables update within about 2 seconds, and those of a removed display are cleared. Create the custom variables in Companion first (see `companion/README.md`): Companion ignores values for variables that don't exist.

Display numbers follow the left-to-right order, so they shift when you unplug a monitor. For buttons that should always hit the same monitor, use its name in the route (`/brightness/up/DELL`) rather than its number.
