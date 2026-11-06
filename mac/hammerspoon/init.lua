-- PiDeck: HTTP control API for Bitfocus Companion + live state push
-- Put this file at ~/.hammerspoon/init.lua (or require("pideck") from your own init.lua)
-- and create ~/.hammerspoon/pideck-secret.lua (see bottom of this file / the runbook).

local cfg = dofile(hs.configdir .. "/pideck-secret.lua")
-- cfg.token        : shared secret Companion sends as "Authorization: Bearer <token>"
-- cfg.port         : port to listen on (e.g. 8765)
-- cfg.companion    : base URL of Companion, e.g. "http://192.168.10.112:8000" (nil = no state push)

local log = hs.logger.new("pideck", "info")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function urldecode(s)
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end

local function out() return hs.audiodevice.defaultOutputDevice() end

local function json(tbl, code)
  return hs.json.encode(tbl), code or 200, { ["Content-Type"] = "application/json" }
end

local function mediaKey(key) -- PLAY, NEXT, PREVIOUS, SOUND_UP, ...
  hs.eventtap.event.newSystemKeyEvent(key, true):post()
  hs.eventtap.event.newSystemKeyEvent(key, false):post()
end

---------------------------------------------------------------------------
-- State push to Companion custom variables
-- Create these in Companion first (Variables -> Custom variables):
--   mac_volume, mac_muted, mac_brightness, mac_app, mac_online
---------------------------------------------------------------------------
local lastSent = {}

local function pushVar(name, value)
  if not cfg.companion then return end
  value = tostring(value)
  if lastSent[name] == value then return end
  lastSent[name] = value
  local url = cfg.companion .. "/api/custom-variable/" .. name .. "/value?value=" .. hs.http.encodeForQuery(value)
  hs.http.asyncPost(url, "", nil, function(code)
    if code ~= 200 then
      lastSent[name] = nil -- retry on next change/heartbeat
      log.d("push " .. name .. " failed: " .. tostring(code))
    end
  end)
end

local function state()
  local dev = out()
  local front = hs.application.frontmostApplication()
  return {
    volume = dev and math.floor((dev:outputVolume() or 0) + 0.5) or nil,
    muted = dev and dev:outputMuted() or nil,
    brightness = hs.brightness.get(),
    app = front and front:name() or "",
  }
end

local function pushAll(force)
  if force then lastSent = {} end
  local s = state()
  if s.volume then pushVar("mac_volume", s.volume) end
  if s.muted ~= nil then pushVar("mac_muted", s.muted and 1 or 0) end
  if s.brightness then pushVar("mac_brightness", s.brightness) end
  pushVar("mac_app", s.app)
  pushVar("mac_online", 1)
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
local layouts = {
  left        = { 0,   0,   0.5, 1 },
  right       = { 0.5, 0,   0.5, 1 },
  top         = { 0,   0,   1,   0.5 },
  bottom      = { 0,   0.5, 1,   0.5 },
  ["top-left"]     = { 0,   0,   0.5, 0.5 },
  ["top-right"]    = { 0.5, 0,   0.5, 0.5 },
  ["bottom-left"]  = { 0,   0.5, 0.5, 0.5 },
  ["bottom-right"] = { 0.5, 0.5, 0.5, 0.5 },
  ["left-third"]   = { 0,     0, 1/3, 1 },
  ["center-third"] = { 1/3,   0, 1/3, 1 },
  ["right-third"]  = { 2/3,   0, 1/3, 1 },
  max         = { 0,   0,   1,   1 },
}

hs.window.animationDuration = 0 -- move instantly, no slide animation

-- Screens sorted left to right (then top to bottom), so "screen": 1 is the leftmost display
local function screensLeftToRight()
  local list = hs.screen.allScreens()
  table.sort(list, function(s1, s2)
    local f1, f2 = s1:fullFrame(), s2:fullFrame()
    if f1.x ~= f2.x then return f1.x < f2.x end
    return f1.y < f2.y
  end)
  return list
end

-- spec: nil (window's current screen), number (1-based, left to right), "main", "next",
-- or part of the screen's name (e.g. "Built-in", "DELL")
local function pickScreen(spec, win)
  if spec == nil or spec == "" or spec == "current" then return win:screen() end
  if spec == "main" then return hs.screen.mainScreen() end
  if spec == "next" then return win:screen():next() end
  local list = screensLeftToRight()
  local n = tonumber(spec)
  if n then return list[math.floor(n)] end
  for _, s in ipairs(list) do
    if (s:name() or ""):lower():find(tostring(spec):lower(), 1, true) then return s end
  end
  return nil
end

-- Place a window on a screen. x/y are relative to the screen's usable area
-- (below the menu bar, beside the Dock). With unit = true, x/y/w/h are fractions 0-1
-- of that area; otherwise they are points. Missing values keep the window's current value.
local function placeWindow(win, spec)
  local screen = pickScreen(spec.screen, win)
  if not screen then return json({ error = "screen not found: " .. tostring(spec.screen) }, 404) end
  local area = screen:frame()
  local cur = win:frame()
  local onSame = win:screen():id() == screen:id()
  -- current position relative to the target area (only meaningful on the same screen)
  local rel = {
    x = onSame and (cur.x - area.x) or 0,
    y = onSame and (cur.y - area.y) or 0,
    w = cur.w,
    h = cur.h,
  }
  local unit = spec.unit == true or spec.unit == "true" or spec.unit == 1
  local function val(key, scale)
    local v = tonumber(spec[key])
    if v == nil then return rel[key] end
    return unit and v * scale or v
  end
  local f = {
    x = area.x + val("x", area.w),
    y = area.y + val("y", area.h),
    w = val("w", area.w),
    h = val("h", area.h),
  }
  win:setFrame(f)
  local got = win:frame()
  return json({
    ok = true,
    screen = screen:name(),
    frame = { x = got.x - area.x, y = got.y - area.y, w = got.w, h = got.h },
  })
end

local function targetWindow(appName)
  if appName and appName ~= "" then
    local app = hs.application.get(appName) or hs.application.find(appName)
    if not app then return nil, "app not running: " .. appName end
    local win = app:mainWindow() or app:focusedWindow()
    if not win then return nil, "app has no window: " .. appName end
    return win
  end
  local win = hs.window.focusedWindow()
  if not win then return nil, "no focused window" end
  return win
end

local function windowAction(arg, rest, body)
  if arg == "set" then -- POST /window/set with a JSON body
    local ok, spec = pcall(hs.json.decode, body or "")
    if not ok or type(spec) ~= "table" then
      return json({ error = 'POST a JSON body, e.g. {"x":0,"y":0,"w":1200,"h":800}' }, 400)
    end
    local win, err = targetWindow(spec.app)
    if not win then return json({ error = err }, 409) end
    return placeWindow(win, spec)
  end

  local win = hs.window.focusedWindow()
  if not win then return json({ error = "no focused window" }, 409) end
  if layouts[arg] then
    win:moveToUnit(layouts[arg])
  elseif arg == "center" then
    win:centerOnScreen()
  elseif arg == "frame" then -- /window/frame/<x>/<y>/<w>/<h> in points, relative to the usable area
    local x, y, w, h = rest:match("^(%-?%d+)/(%-?%d+)/(%d+)/(%d+)$")
    if not x then return json({ error = "use /window/frame/x/y/w/h" }, 400) end
    return placeWindow(win, { x = x, y = y, w = w, h = h })
  elseif arg == "next-screen" then
    win:moveToScreen(win:screen():next())
  elseif arg == "fullscreen" then
    win:toggleFullScreen()
  else
    return json({ error = "unknown layout " .. tostring(arg) }, 404)
  end
  return json({ ok = true })
end

local function handle(path, body)
  -- split "/a/b/rest..." into a, b, rest
  local a, b, rest = path:match("^/([^/]+)/?([^/]*)/?(.*)$")
  a = a and urldecode(a) or ""
  b = b and urldecode(b) or ""
  rest = rest and urldecode(rest) or ""
  local dev = out()

  if a == "status" or a == "" then
    return json(state())

  elseif a == "volume" then
    if not dev then return json({ error = "no output device" }, 500) end
    local v = dev:outputVolume() or 0
    if b == "up" then dev:setOutputVolume(clamp(v + 6.25, 0, 100))
    elseif b == "down" then dev:setOutputVolume(clamp(v - 6.25, 0, 100))
    elseif b == "mute" then dev:setOutputMuted(not dev:outputMuted())
    elseif b == "set" and tonumber(rest) then dev:setOutputVolume(clamp(tonumber(rest), 0, 100))
    else return json({ error = "use up|down|mute|set/<0-100>" }, 400) end

  elseif a == "brightness" then -- built-in display only
    local v = hs.brightness.get() or 50
    if b == "up" then hs.brightness.set(clamp(v + 10, 0, 100))
    elseif b == "down" then hs.brightness.set(clamp(v - 10, 0, 100))
    elseif b == "set" and tonumber(rest) then hs.brightness.set(clamp(tonumber(rest), 0, 100))
    else return json({ error = "use up|down|set/<0-100>" }, 400) end

  elseif a == "app" and b ~= "" then -- /app/Visual%20Studio%20Code
    if not hs.application.launchOrFocus(b) then return json({ error = "app not found: " .. b }, 404) end

  elseif a == "quit" and b ~= "" then
    local app = hs.application.get(b)
    if app then app:kill() end

  elseif a == "window" then
    return windowAction(b, rest, body)

  elseif a == "media" then
    local keys = { play = "PLAY", next = "NEXT", previous = "PREVIOUS" }
    if not keys[b] then return json({ error = "use play|next|previous" }, 400) end
    mediaKey(keys[b])

  elseif a == "darkmode" then
    hs.osascript.applescript(
      'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode')

  elseif a == "shortcut" and b ~= "" then -- runs a macOS Shortcuts shortcut by name
    hs.task.new("/usr/bin/shortcuts", nil, { "run", b }):start()

  elseif a == "lock" then
    hs.caffeinate.lockScreen()

  elseif a == "displaysleep" then
    hs.task.new("/usr/bin/pmset", nil, { "displaysleepnow" }):start()

  else
    return json({ error = "unknown route " .. path }, 404)
  end

  hs.timer.doAfter(0.3, function() pushAll(false) end)
  return json({ ok = true })
end

---------------------------------------------------------------------------
-- HTTP server
---------------------------------------------------------------------------
local function authorized(headers)
  for k, v in pairs(headers or {}) do
    if k:lower() == "authorization" and v == "Bearer " .. cfg.token then return true end
  end
  return false
end

pideckServer = hs.httpserver.new(false, false) -- global so it isn't garbage-collected
pideckServer:setPort(cfg.port or 8765)
pideckServer:setCallback(function(method, path, headers, body)
  if not authorized(headers) then return json({ error = "unauthorized" }, 401) end
  path = path:gsub("%?.*$", "")
  local ok, resBody, code, resHeaders = pcall(handle, path, body)
  if not ok then
    log.e(resBody)
    return json({ error = "internal error" }, 500)
  end
  log.i(method .. " " .. path .. " -> " .. tostring(code))
  return resBody, code, resHeaders
end)
pideckServer:start()
log.i("PiDeck API listening on port " .. tostring(cfg.port or 8765))

---------------------------------------------------------------------------
-- Watchers: push changes to Companion as they happen
---------------------------------------------------------------------------
local watchedDev

local function watchOutput()
  if watchedDev then pcall(function() watchedDev:watcherStop() end) end
  watchedDev = out()
  if not watchedDev then return end
  watchedDev:watcherCallback(function(_, event)
    if event == "vmvo" or event == "mute" then pushAll(false) end
  end)
  watchedDev:watcherStart()
end

hs.audiodevice.watcher.setCallback(function(event)
  if event == "dOut" then watchOutput(); pushAll(false) end
end)
hs.audiodevice.watcher.start()
watchOutput()

pideckAppWatcher = hs.application.watcher.new(function(_, event)
  if event == hs.application.watcher.activated then pushAll(false) end
end)
pideckAppWatcher:start()

-- Brightness has no watcher; poll it, and resend everything every 60 s as a heartbeat
pideckPoll = hs.timer.doEvery(5, function() pushAll(false) end)
pideckHeartbeat = hs.timer.doEvery(60, function() pushAll(true) end)

-- Tell Companion the Mac is going away / back
pideckSleep = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.systemWillSleep then
    pushVar("mac_online", 0)
  elseif event == w.systemDidWake then
    hs.timer.doAfter(5, function() pushAll(true) end)
  end
end)
pideckSleep:start()

pushAll(true)

--[[ ~/.hammerspoon/pideck-secret.lua
return {
  token = "paste-output-of: openssl rand -hex 24",
  port = 8765,
  companion = "http://192.168.10.112:8000",
}
]]
