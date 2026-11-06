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
| 1/0 | `Bright −` | `/brightness/down` | |
| 1/1 | `Bright\n$(custom:mac_brightness)%` | `/brightness/up` | |
| 1/2 | `Prev` | `/media/previous` | |
| 1/3 | `Next` | `/media/next` | |
| 1/4 | `Dark mode` | `/darkmode` | |
| 2/0 | `Left half` | `/window/left` | |
| 2/1 | `Right half` | `/window/right` | |
| 2/2 | `Max` | `/window/max` | |
| 2/3 | your tool's name | `/app/Your%20Tool` | highlight when `mac_app` = your tool |
| 2/4 | `Lock` | `/lock` | |

On every Mac button, add the feedback *Internal → Check variable value* (`mac_online` = 0) with a dark grey background, so the page visibly goes dead when the MacBook is asleep or away.

Back up the configuration regularly with Companion's **Import/Export**.
