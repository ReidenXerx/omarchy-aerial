-- Three fingers, and the overview follows them.
--
-- Hyprland 0.56 hands a Lua gesture a table of callbacks. `start` fires when
-- the fingers land, `update` for every frame they move — about 125 times a
-- second — and `finish` when they lift. That middle one is the whole point: a
-- gesture that only fired at the end would be a keybinding with extra steps,
-- and what makes Mission Control feel alive is that it is attached to your hand
-- the entire way.
--
-- The payload, which is not written down anywhere, looks like this:
--
--   delta{x=0.0,y=-7.9} direction=UP fingers=3 phase=update time_ms=… type=swipe
--   cancelled=false direction=UP phase=end time_ms=… type=swipe
--
-- Note `finish`, not `end`: naming the callback `end` gets you a gesture that
-- never reports the lift at all.
--
-- What we send out is a fraction: 0 is the desktop, 1 is the overview. The
-- shell reads it off the event socket and draws that frame.

-- How far the fingers travel for a full open. The units run about ten to the
-- millimetre, so this is a centimetre and a half.
--
-- Measured rather than guessed: real swipes on this touchpad last 30–80ms and
-- cover 40–130 units. At the 260 this started out as, an ordinary swipe only
-- ever reached a third of the way and the overview refused to open.
local DISTANCE = 150

-- Travel per millisecond that counts as a flick. Past this a short swipe still
-- opens: throwing the desktop away should not require covering the distance.
-- A deliberate slow scrub measures about 1; a real flick measures 3 to 4.
local FLICK = 2.0

-- How far back to look when measuring that speed.
local WINDOW_MS = 90

local state = { total = 0, marks = {} }

local function say(what)
  hl.dispatch(hl.dsp.event("aerial," .. what))
end

-- Said once if the payload ever stops looking like the one described above,
-- so a Hyprland that renames the field leaves a note rather than a gesture
-- that silently does nothing.
local complained = false
local function puzzled(ev)
  if complained then return end
  complained = true
  local parts = {}
  if type(ev) == "table" then
    for k, v in pairs(ev) do parts[#parts + 1] = tostring(k) .. "=" .. type(v) end
    table.sort(parts)
  else
    parts[1] = type(ev)
  end
  say("shape:" .. table.concat(parts, " "))
end

local function travel(ev)
  if type(ev) ~= "table" then
    puzzled(ev)
    return 0
  end
  local delta = ev.delta
  if type(delta) == "number" then return delta end
  if type(delta) == "table" then
    local y = delta.y or delta[2]
    if type(y) == "number" then return y end
  end
  puzzled(ev)
  return 0
end

local function fraction()
  local value = math.abs(state.total) / DISTANCE
  if value > 1 then return 1 end
  return value
end

-- Speed over the last WINDOW_MS, so a flick is judged on how the swipe ended
-- rather than averaged over a slow start.
local function speed()
  local marks = state.marks
  if #marks < 2 then return 0 end
  local last = marks[#marks]
  local first = marks[1]
  for i = #marks, 1, -1 do
    first = marks[i]
    if last.at - marks[i].at >= WINDOW_MS then break end
  end
  local elapsed = last.at - first.at
  if elapsed <= 0 then return 0 end
  return math.abs(last.total - first.total) / elapsed
end

local function mark(ev)
  local at = type(ev) == "table" and tonumber(ev.time_ms) or 0
  local marks = state.marks
  marks[#marks + 1] = { at = at, total = state.total }
  while #marks > 24 do table.remove(marks, 1) end
end

local function begin(name)
  return function(ev)
    state.total = 0
    state.marks = {}
    mark(ev)
    say(name .. "-begin")
  end
end

local function move(name)
  return function(ev)
    state.total = state.total + travel(ev)
    mark(ev)
    say(name .. "-move:" .. string.format("%.4f", fraction()))
  end
end

local function lift(name)
  return function(ev)
    local cancelled = type(ev) == "table" and ev.cancelled == true
    say(string.format("%s-end:%.4f:%.4f:%d", name, fraction(), speed(), cancelled and 1 or 0))
    state.total = 0
    state.marks = {}
  end
end

local function handlers(name)
  return {
    start = begin(name),
    update = move(name),
    -- Hyprland calls `finish`. `end` is defined too in case that changes; the
    -- shell ignores a second lift, so being told twice is harmless.
    finish = lift(name),
    ["end"] = lift(name),
  }
end

-- Registering over an existing gesture is refused rather than replaced, so ours
-- has to come off first. Removing one that was never there is an error Hyprland
-- raises past pcall, so remember instead of asking: the config's Lua state
-- outlives an eval, and a config reload drops both the flag and the gestures.
if _G.__aerial_registered then
  for _, fingers in ipairs({ 3, 4 }) do
    for _, direction in ipairs({ "up", "down" }) do
      hl.gesture({ fingers = fingers, direction = direction, action = "unset" })
    end
  end
end

-- Three fingers is this workspace; four is every window you have open, the
-- same split macOS makes between Mission Control and All Windows.
hl.gesture({ fingers = 3, direction = "up",   action = handlers("up") })
hl.gesture({ fingers = 3, direction = "down", action = handlers("down") })
hl.gesture({ fingers = 4, direction = "up",   action = handlers("allup") })
hl.gesture({ fingers = 4, direction = "down", action = handlers("alldown") })
_G.__aerial_registered = true
