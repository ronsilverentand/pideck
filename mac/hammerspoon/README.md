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
| `/status` | Current volume, mute, brightness, frontmost app |
| `/volume/up` · `/volume/down` · `/volume/mute` · `/volume/set/30` | Output volume (steps of 6.25 = one macOS step) |
| `/brightness/up` · `/brightness/down` · `/brightness/set/60` | Built-in display brightness |
| `/app/Visual%20Studio%20Code` · `/quit/Slack` | Launch or focus an app, or quit it |
| `/window/left` · `right` · `top` · `bottom` · `max` · `center` | Move the focused window |
| `/window/top-left` (and the other quarters) · `left-third` · `center-third` · `right-third` | Quarters and thirds |
| `/window/frame/0/25/1200/800` | Exact x, y, width, height in points |
| `/window/next-screen` · `/window/fullscreen` | Move to the next display, toggle full screen |
| `/media/play` · `/media/next` · `/media/previous` | Media keys |
| `/darkmode` · `/lock` · `/displaysleep` | Toggle dark mode, lock screen, display off |
| `/shortcut/Name%20of%20Shortcut` | Run a macOS Shortcuts shortcut |

Brightness only controls the built-in display. External monitors would need BetterDisplay or Lunar as an extra route.

## State pushed to Companion

`mac_volume`, `mac_muted`, `mac_brightness`, `mac_app` and `mac_online` are sent on every change, brightness is polled every 5 s, and everything is resent every 60 s. `mac_online` goes to 0 when the Mac sleeps. Create these custom variables in Companion first (see `companion/README.md`).
