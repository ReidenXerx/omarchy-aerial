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
-- What we send out is progress: 0 is where the fingers landed, 1 is a full
-- swipe. It is deliberately not clamped — the shell rubber-bands past the end
-- rather than having the overview hit a wall under your fingers — and it is
-- signed along the swipe, so a swipe that comes back past where it started
-- reads as 0 rather than as a second swipe the other way.

-- How far the fingers travel for a full open. The units run about ten to the
-- millimetre, so this is two and a half centimetres. Short enough that an
-- ordinary swipe gets there, long enough that the overview visibly tracks the
-- hand instead of arriving before it has finished moving.
local DISTANCE = 250

-- How far the fingers travel to slide one whole workspace across. About half
-- a touchpad: the width of an easy three-finger swipe. (Hyprland's own
-- default is 300, which moves a whole screen for three centimetres of finger
-- and reads as the desktop running away from the hand.) A quick flick still
-- goes a whole workspace from much less.
local SIDE_DISTANCE = 550

-- How far back to look when measuring speed.
local WINDOW_MS = 90

local state = { total = 0, sign = 0, marks = {} }

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

-- Movement along one axis, in the payload's own units.
local function travel(ev, axis)
  if type(ev) ~= "table" then
    puzzled(ev)
    return 0
  end
  local delta = ev.delta
  if type(delta) == "number" then return delta end
  if type(delta) == "table" then
    local v = delta[axis] or delta[axis == "x" and 1 or 2]
    if type(v) == "number" then return v end
  end
  puzzled(ev)
  return 0
end

local function mark(ev)
  local at = type(ev) == "table" and tonumber(ev.time_ms) or 0
  local marks = state.marks
  marks[#marks + 1] = { at = at, total = state.total }
  while #marks > 24 do table.remove(marks, 1) end
end

-- Signed travel per millisecond over the last WINDOW_MS, so a flick is judged
-- on how the swipe ended rather than averaged over a slow start.
local function rate()
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
  return (last.total - first.total) / elapsed
end

local function reset()
  state.total = 0
  state.sign = 0
  state.marks = {}
end

-- ------------------------------------------------------------- up and down

-- Hyprland has already decided which way the swipe went before `start`, so
-- whichever way the numbers first move *is* the direction this gesture is
-- about. Learning the sign from that, instead of assuming one, keeps it right
-- whatever the touchpad's natural-scrolling setting does to the deltas.
local function progress()
  if state.sign == 0 then return 0 end
  local value = state.total * state.sign / DISTANCE
  if value < 0 then return 0 end
  return value
end

local function vertical(name)
  return {
    start = function(ev)
      reset()
      mark(ev)
      say(name .. "-begin")
    end,
    update = function(ev)
      state.total = state.total + travel(ev, "y")
      if state.sign == 0 and math.abs(state.total) > 0.5 then
        state.sign = state.total > 0 and 1 or -1
      end
      mark(ev)
      say(string.format("%s-move:%.4f", name, progress()))
    end,
    finish = function(ev)
      local cancelled = type(ev) == "table" and ev.cancelled == true
      local r = rate() * (state.sign == 0 and 1 or state.sign)
      -- progress : |speed| (for the flick test) : cancelled : velocity in
      -- progress per second, positive along the swipe.
      say(string.format("%s-end:%.4f:%.4f:%d:%.4f", name, progress(), math.abs(r),
                        cancelled and 1 or 0, r * 1000 / DISTANCE))
      reset()
    end,
  }
end

-- ---------------------------------------------------------- left and right

-- Positive is toward the next workspace: fingers moving left pull the desktop
-- on the right into view, the way content follows your fingers everywhere
-- else on a touchpad.
local function side()
  return {
    start = function(ev)
      reset()
      mark(ev)
      say("side-begin")
    end,
    update = function(ev)
      state.total = state.total - travel(ev, "x")
      mark(ev)
      say(string.format("side-move:%.4f", state.total / SIDE_DISTANCE))
    end,
    finish = function(ev)
      local cancelled = type(ev) == "table" and ev.cancelled == true
      local r = rate()
      say(string.format("side-end:%.4f:%.4f:%d:%.4f", state.total / SIDE_DISTANCE,
                        math.abs(r), cancelled and 1 or 0, r * 1000 / SIDE_DISTANCE))
      reset()
    end,
  }
end

-- Both are defined so a Hyprland that renames `finish` to `end` still reports
-- the lift; the shell ignores a second one.
local function both(t)
  t["end"] = t.finish
  return t
end

-- Three fingers sideways slide from one workspace to the next under your
-- fingers, overview open or not; the shell draws it either way (see
-- `deskSwipe` in shell/Service.qml for why not Hyprland's own swipe). The
-- shell says what to register through this: "slide" for ours, "workspace"
-- for Hyprland's, anything else for none.
--
-- Hyprland raises both of the errors that matter here past pcall: removing a
-- gesture that is not there, and adding one a previous gesture shadows. So
-- what is registered is remembered rather than asked about, and the shell calls
-- this in an eval of its own — if the user already has a horizontal swipe, it
-- is theirs, this fails, and nothing else is disturbed.
function __aerial_horizontal(mode)
  if _G.__aerial_h == mode then return end
  if _G.__aerial_h then
    hl.gesture({ fingers = 3, direction = "horizontal", action = "unset" })
    _G.__aerial_h = nil
  end
  if mode == "slide" then
    hl.gesture({ fingers = 3, direction = "horizontal", action = both(side()) })
  elseif mode == "workspace" then
    hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
  else
    return
  end
  _G.__aerial_h = mode
end

-- The overview animates itself, frame by frame, from the fingers. Omarchy
-- fades every layer surface in and out on top of whatever it draws, the way
-- it does for menus — which on this surface is a second, fixed-speed fade
-- fighting the one following your hand: the overview arrives washed out,
-- catches up, and flickers on the way out. The same rule Omarchy gives its own
-- bar turns that off. Once per Lua state; a config reload drops it and this
-- file runs again.
if not _G.__aerial_layer then
  hl.layer_rule({ match = { namespace = "^omarchy-aerial$" }, no_anim = true, animation = "none" })
  _G.__aerial_layer = true
end

-- Registering over an existing gesture is refused rather than replaced, so ours
-- has to come off first. The config's Lua state outlives an eval, and a config
-- reload drops both the flag and the gestures.
if _G.__aerial_registered then
  for _, fingers in ipairs({ 3, 4 }) do
    for _, direction in ipairs({ "up", "down" }) do
      hl.gesture({ fingers = fingers, direction = direction, action = "unset" })
    end
  end
end

-- Three fingers is this workspace; four is every window you have open, the
-- same split macOS makes between Mission Control and All Windows.
hl.gesture({ fingers = 3, direction = "up",   action = both(vertical("up")) })
hl.gesture({ fingers = 3, direction = "down", action = both(vertical("down")) })
hl.gesture({ fingers = 4, direction = "up",   action = both(vertical("allup")) })
hl.gesture({ fingers = 4, direction = "down", action = both(vertical("alldown")) })
_G.__aerial_registered = true
