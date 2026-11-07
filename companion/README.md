# Companion setup

PiDeck shows a Companion **emulator** surface with ID `pideck`, grid **5 columns × 3 rows**. On the 800 × 480 display that gives 160 px square buttons.

## Connections

| Connection | Settings |
| --- | --- |
| Home Assistant Server | URL `http://home-assistant.home-assistant.svc.cluster.local:8123`, long-lived token named `companion` |
| Generic HTTP Requests (MacBook) | Base URL `http://MAC-IP:8765` only. The token goes on each action (below). |

## Custom variables

| Variable | Filled by | Meaning |
| --- | --- | --- |
| `mac_token` | you | Hammerspoon API token, used in the action headers |
| `mac_volume` | Hammerspoon | Output volume 0–100 |
| `mac_muted` | Hammerspoon | 1 when muted |
| `mac_brightness` | Hammerspoon | Built-in display brightness 0–100 |
| `mac_screen_count` | Hammerspoon | Number of connected displays |
| `mac_screen_1_name`, `mac_screen_2_name`, … | Hammerspoon | Display name, numbered left to right |
| `mac_brightness_1`, `mac_brightness_2`, … | Hammerspoon | Brightness per display, numbered left to right (see `GET /screens`) |
| `mac_screens` | Hammerspoon | All displays as JSON (number, name, built-in, brightness, usable size) |
| `mac_app` | Hammerspoon | Name of the frontmost app |
| `mac_online` | Hammerspoon | 0 when the Mac goes to sleep |

Hammerspoon writes these through Companion's HTTP API, so that must be enabled (Settings → Protocols).

## Mac page

Every Mac action is an HTTP POST. Put this in the action's **Header input (JSON)** field:

```json
{"Authorization": "Bearer $(custom:mac_token)"}
```

If your Companion version doesn't substitute variables in that field (you'll get 401s in the Hammerspoon Console), paste the literal token. Build one button, then copy it and change only the path and text.

| Row/col | Button text | POST path | Feedback |
| --- | --- | --- | --- |
| 0/0 | `Home` | none: internal action "Set surface to page" → Home | |
| 0/1 | `Vol −` | `/volume/down` | |
| 0/2 | `Vol\n$(custom:mac_volume)%` | `/volume/mute` | red background when `mac_muted` = 1 |
| 0/3 | `Vol +` | `/volume/up` | |
| 0/4 | `Play / Pause` | `/media/play` | |
| 1/0 | `Bright −` | `/brightness/down` (all displays; add `/DELL` or `/2` for one) | |
| 1/1 | `Bright\n$(custom:mac_brightness)%` | `/brightness/up` | |
| 1/2 | `Prev` | `/media/previous` | |
| 1/3 | `Next` | `/media/next` | |
| 1/4 | `Dark mode` | `/darkmode` | |
| 2/0 | `Left half` | `/window/left` | |
| 2/1 | `Right half` | `/window/right` | |
| 2/2 | `Max` | `/window/max` | |
| 2/3 | your tool's name | `/app/Your%20Tool` | highlight when `mac_app` = your tool |
| 2/4 | `Lock` | `/lock` | |

## App launcher buttons with real icons

1. Export the icons of every Dock app (pinned and running) on the Mac:
   ```bash
   curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:8765/icons/export
   ```
   Or in the Hammerspoon Console: `pideckExportDockIcons(144)`. The PNGs land in `~/Desktop/PiDeck icons`, named after the app. An app that isn't in the Dock yet: open it once, then export again.
2. In Companion, per button: **Button style → PNG → upload** the app's PNG, with alignment centre. Leave the text empty, or put a short label at the bottom.
3. Action: HTTP POST `/app/<App%20Name>` (spaces as `%20`). `GET /icons` lists the exact names.
4. Optional feedback: highlight the button when `mac_app` equals the app's name, so you can see which app is in front.

If icons look blurry on the 160 px buttons, export at a larger size (`/icons/export/256`). If they're too big for the button, export at 72.

On every Mac button, add the feedback *Internal → Check variable value* (`mac_online` = 0) with a dark grey background, so the page visibly goes dead when the MacBook is asleep or away.

Back up the configuration regularly with Companion's **Import/Export**.
