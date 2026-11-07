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
-- Displays
---------------------------------------------------------------------------
-- Screens sorted left to right (then top to bottom), so screen 1 is the leftmost display
local function screensLeftToRight()
  local list = hs.screen.allScreens()
  table.sort(list, function(s1, s2)
    local f1, f2 = s1:fullFrame(), s2:fullFrame()
    if f1.x ~= f2.x then return f1.x < f2.x end
    return f1.y < f2.y
  end)
  return list
end

local function isBuiltin(s) return (s:name() or ""):lower():find("built-in", 1, true) ~= nil end

-- spec: number (1-based, left to right), "main", "builtin", or part of the screen's name
local function screenBySpec(spec)
  if spec == "main" then return hs.screen.mainScreen() end
  local list = screensLeftToRight()
  local n = tonumber(spec)
  if n then return list[math.floor(n)] end
  for _, s in ipairs(list) do
    if spec == "builtin" and isBuiltin(s) then return s end
    if (s:name() or ""):lower():find(tostring(spec):lower(), 1, true) then return s end
  end
  return nil
end

-- Brightness: the built-in display via hs.brightness, external displays via DDC with m1ddc
-- (brew install m1ddc). External values are cached: reading DDC is slow.
local M1DDC = cfg.m1ddc or "/opt/homebrew/bin/m1ddc"
local haveDdc = hs.fs.attributes(M1DDC) ~= nil
local ddcList = nil        -- parsed `m1ddc display list`, reset when displays change
local extBrightness = {}   -- screen UUID -> last known 0-100 (false = not controllable)

local function ddcDisplays()
  if ddcList then return ddcList end
  ddcList = {}
  if not haveDdc then return ddcList end
  -- lines look like: [1] DELL U2723QE (F0DB7A7E-6804-4F3B-8687-200C7CBCE0C8)
  local listing = hs.execute('"' .. M1DDC .. '" display list') or ""
  for idx, name, uuid in listing:gmatch("%[(%d+)%]%s+([^\n]-)%s+%(([%x%-]+)%)") do
    ddcList[#ddcList + 1] = { index = idx, name = name, uuid = uuid:upper() }
  end
  return ddcList
end

-- The m1ddc selector (UUID or index) for a screen, matched by UUID first, then by name
local function ddcTarget(s)
  local uuid = (s:getUUID() or ""):upper()
  local sname = (s:name() or ""):lower()
  for _, d in ipairs(ddcDisplays()) do
    if d.uuid == uuid then return d.uuid end
  end
  for _, d in ipairs(ddcDisplays()) do
    local dname = d.name:lower()
    if dname == sname or sname:find(dname, 1, true) or dname:find(sname, 1, true) then return d.index end
  end
  return nil
end

local function getScreenBrightness(s)
  if isBuiltin(s) then return hs.brightness.get() end
  local key = s:getUUID()
  if extBrightness[key] == nil then
    local t = ddcTarget(s)
    local value = false
    if t then
      local res = hs.execute('"' .. M1DDC .. '" display ' .. t .. " get luminance") or ""
      value = tonumber(res:match("(%d+)")) or false
    end
    extBrightness[key] = value
  end
  return extBrightness[key] or nil
end

local function setScreenBrightness(s, v)
  v = math.floor(clamp(v, 0, 100) + 0.5)
  if isBuiltin(s) then
    hs.brightness.set(v)
    return true
  end
  local t = ddcTarget(s)
  if not t then return false end
  extBrightness[s:getUUID()] = v
  hs.task.new(M1DDC, nil, { "display", tostring(t), "set", "luminance", tostring(v) }):start()
  return true
end

local function screensInfo()
  local list = {}
  for i, s in ipairs(screensLeftToRight()) do
    local f = s:frame()
    list[#list + 1] = {
      index = i,
      name = s:name(),
      main = s:id() == hs.screen.mainScreen():id(),
      builtin = isBuiltin(s),
      brightness = getScreenBrightness(s), -- absent when the display can't be controlled
      usable = { w = f.w, h = f.h },
    }
  end
  return list
end

pideckScreenWatcher = hs.screen.watcher.new(function()
  ddcList, extBrightness = nil, {}
end)
pideckScreenWatcher:start()

---------------------------------------------------------------------------
-- State push to Companion custom variables
-- Create these in Companion first (Variables -> Custom variables):
--   mac_volume, mac_muted, mac_brightness, mac_app, mac_online,
--   mac_brightness_1, mac_brightness_2, ... (per display, numbered left to right)
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
    muted = dev and dev:outputMuted(), -- keep false (not muted); nil only without a device
    brightness = hs.brightness.get(), -- built-in display
    app = front and front:name() or "",
    screens = screensInfo(),
  }
end

local function pushAll(force)
  if force then lastSent = {} end
  local s = state()
  if s.volume then pushVar("mac_volume", s.volume) end
  if s.muted ~= nil then pushVar("mac_muted", s.muted and 1 or 0) end
  if s.brightness then pushVar("mac_brightness", s.brightness) end
  for _, scr in ipairs(s.screens) do
    if scr.brightness then pushVar("mac_brightness_" .. scr.index, scr.brightness) end
  end
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

-- spec: nil/"current" (window's current screen), "next", or anything screenBySpec accepts
local function pickScreen(spec, win)
  if spec == nil or spec == "" or spec == "current" then return win:screen() end
  if spec == "next" then return win:screen():next() end
  return screenBySpec(spec)
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
  elseif arg == "frame" then
    -- /window/frame/<x>/<y>/<w>/<h>[/<screen>] in points, relative to the screen's usable area.
    -- Without <screen> the window stays on the screen it is on.
    local x, y, w, h, scr = rest:match("^(%-?%d+)/(%-?%d+)/(%d+)/(%d+)/?(.*)$")
    if not x then return json({ error = "use /window/frame/x/y/w/h[/screen]" }, 400) end
    return placeWindow(win, { x = x, y = y, w = w, h = h, screen = scr })
  elseif arg == "next-screen" then
    win:moveToScreen(win:screen():next())
  elseif arg == "fullscreen" then
    win:toggleFullScreen()
  else
    return json({ error = "unknown layout " .. tostring(arg) }, 404)
  end
  return json({ ok = true })
end

---------------------------------------------------------------------------
-- Dock app icons -> PNG files, for Companion button images
---------------------------------------------------------------------------
local function fileUrlToPath(url)
  local p = url:gsub("^file://", ""):gsub("/$", "")
  return (p:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Apps pinned in the Dock plus apps currently running with a Dock icon
local function dockApps()
  local apps, seen = {}, {}
  local function add(name, path)
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      apps[#apps + 1] = { name = name or path:match("([^/]+)%.app$") or path, path = path }
    end
  end
  local plist = hs.plist.read(os.getenv("HOME") .. "/Library/Preferences/com.apple.dock.plist") or {}
  for _, tile in ipairs(plist["persistent-apps"] or {}) do
    local td = tile["tile-data"] or {}
    local url = td["file-data"] and td["file-data"]["_CFURLString"]
    if url then add(td["file-label"], fileUrlToPath(url)) end
  end
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:kind() == 1 then add(app:name(), app:path()) end -- 1 = regular app with a Dock icon
  end
  return apps
end

-- Saves every Dock app's icon as "<App name>.png" (size x size pixels).
-- Also callable from the Hammerspoon Console: pideckExportDockIcons(144)
function pideckExportDockIcons(size, dir)
  size = tonumber(size) or 144
  dir = dir or (os.getenv("HOME") .. "/Desktop/PiDeck icons")
  hs.fs.mkdir(dir)
  local saved = {}
  for _, a in ipairs(dockApps()) do
    local img = hs.image.iconForFile(a.path)
    if img then
      local file = dir .. "/" .. (a.name:gsub("[/:]", "-")) .. ".png"
      if img:setSize({ w = size, h = size }):saveToFile(file) then saved[#saved + 1] = a.name end
    end
  end
  log.i("Exported " .. #saved .. " icons to " .. dir)
  return dir, saved
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

  elseif a == "screens" then -- numbering used by "screen": 1, 2, ... (left to right)
    return json(screensInfo())

  elseif a == "volume" then
    if not dev then return json({ error = "no output device" }, 500) end
    local v = dev:outputVolume() or 0
    if b == "up" then dev:setOutputVolume(clamp(v + 6.25, 0, 100))
    elseif b == "down" then dev:setOutputVolume(clamp(v - 6.25, 0, 100))
    elseif b == "mute" then dev:setOutputMuted(not dev:outputMuted())
    elseif b == "set" and tonumber(rest) then dev:setOutputVolume(clamp(tonumber(rest), 0, 100))
    else return json({ error = "use up|down|mute|set/<0-100>" }, 400) end

  elseif a == "brightness" then
    -- /brightness/up[/<screen>] · /brightness/down[/<screen>] · /brightness/set/<0-100>[/<screen>]
    -- No screen = every display. <screen> as in screenBySpec: 1, 2, "builtin", "main", part of a name
    local value, scr
    if b == "set" then
      value, scr = rest:match("^(%d+)/?(.*)$")
      if not value then return json({ error = "use /brightness/set/<0-100>[/<screen>]" }, 400) end
    elseif b == "up" or b == "down" then
      scr = rest
    else
      return json({ error = "use up|down|set/<0-100>, optionally followed by /<screen>" }, 400)
    end
    local targets
    if scr == nil or scr == "" or scr == "all" then
      targets = screensLeftToRight()
    else
      local s = screenBySpec(scr)
      if not s then return json({ error = "screen not found: " .. scr }, 404) end
      targets = { s }
    end
    local results = {}
    for _, s in ipairs(targets) do
      local cur = getScreenBrightness(s)
      local v
      if b == "set" then v = tonumber(value)
      elseif cur then v = cur + (b == "up" and 10 or -10) end
      local ok = v ~= nil and setScreenBrightness(s, v)
      results[#results + 1] = {
        name = s:name(),
        ok = ok,
        brightness = ok and math.floor(clamp(v, 0, 100) + 0.5) or nil,
        error = (not ok) and "no brightness control for this display (external displays need m1ddc)" or nil,
      }
    end
    hs.timer.doAfter(0.3, function() pushAll(false) end)
    return json({ ok = true, displays = results })

  elseif a == "icons" then
    if b == "export" then -- /icons/export[/<size>]: write PNGs and open the folder in Finder
      local dir, saved = pideckExportDockIcons(tonumber(rest) or 144)
      hs.task.new("/usr/bin/open", nil, { dir }):start()
      return json({ ok = true, folder = dir, apps = saved })
    end
    local list = {} -- /icons: list Dock apps (the names work with /app/<name>)
    for _, app in ipairs(dockApps()) do list[#list + 1] = app.name end
    return json(list)

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
