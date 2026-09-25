.pragma library

// Aerial's keyboard shortcuts, kept in a section of their own in the user's
// Omarchy bindings file (~/.config/hypr/bindings.lua):
//
//   -- >>> aerial ...
//   o.bind("SUPER + A", "Aerial: Overview", "omarchy-shell shell toggle reidenxerx.aerial")
//   -- <<< aerial
//
// Everything outside the markers is the user's and is left exactly as it is.
// The settings panel reads the section back, lets it be edited, and writes it
// again; Hyprland reloads the file on its own when it changes.

var BEGIN = "-- >>> aerial"
var END = "-- <<< aerial"

// What a shortcut can do. `dispatcher` is Lua, spliced into the binding.
var ACTIONS = [
  {
    id: "overview",
    label: "Open overview",
    description: "Aerial: Overview",
    dispatcher: '"omarchy-shell shell toggle reidenxerx.aerial"',
  },
  {
    id: "prev",
    label: "Previous desktop",
    description: "Aerial: Previous desktop",
    dispatcher: 'hl.dsp.event("aerial,go:prev")',
  },
  {
    id: "next",
    label: "Next desktop",
    description: "Aerial: Next desktop",
    dispatcher: 'hl.dsp.event("aerial,go:next")',
  },
]

// Modifiers as Hyprland numbers them in `hyprctl binds -j`, and in the order
// Omarchy writes them.
var MODS = [
  { name: "SUPER", mask: 64 },
  { name: "CTRL", mask: 4 },
  { name: "ALT", mask: 8 },
  { name: "SHIFT", mask: 1 },
]

// Qt key codes that are not their own printable character, as the key names
// Hyprland (xkb) knows them by.
var NAMED = {
  0x01000000: "Escape", 0x01000001: "TAB", 0x01000002: "TAB", 0x01000003: "BackSpace",
  0x01000004: "Return", 0x01000005: "KP_Enter", 0x01000006: "Insert", 0x01000007: "Delete",
  0x01000010: "Home", 0x01000011: "End", 0x01000012: "Left", 0x01000013: "Up",
  0x01000014: "Right", 0x01000015: "Down", 0x01000016: "Prior", 0x01000017: "Next",
  0x01000061: "Print", 0x20: "SPACE",
  0x2c: "COMMA", 0x2e: "PERIOD", 0x2d: "MINUS", 0x3d: "EQUAL", 0x2f: "SLASH",
  0x5c: "BACKSLASH", 0x3b: "SEMICOLON", 0x27: "APOSTROPHE", 0x60: "GRAVE",
  0x5b: "BRACKETLEFT", 0x5d: "BRACKETRIGHT",
}

// Keys that are modifiers themselves: pressed alone they are not a shortcut
// yet, only the start of one.
var MODIFIER_KEYS = [0x01000020, 0x01000021, 0x01000022, 0x01000023, 0x01000053, 0x01000054, 0x01000055, 0x01001103]

function isModifierKey(key) { return MODIFIER_KEYS.indexOf(key) >= 0 }

/** The Hyprland name of a Qt key, or "" for one that cannot be bound. */
function keyName(key) {
  if (NAMED[key] !== undefined) return NAMED[key]
  if (key >= 0x01000030 && key <= 0x01000047) return "F" + (key - 0x01000030 + 1)   // F1..F24
  if (key >= 0x30 && key <= 0x39) return String.fromCharCode(key)                    // 0..9
  if (key >= 0x41 && key <= 0x5a) return String.fromCharCode(key)                    // A..Z
  return ""
}

/** Qt modifier flags to Hyprland's mask. */
function maskOf(qtModifiers) {
  var mask = 0
  if (qtModifiers & 0x10000000) mask |= 64   // Meta = SUPER
  if (qtModifiers & 0x04000000) mask |= 4    // Control
  if (qtModifiers & 0x08000000) mask |= 8    // Alt
  if (qtModifiers & 0x02000000) mask |= 1    // Shift
  return mask
}

/** "SUPER + CTRL + Right", the way Omarchy's bindings are written. */
function format(mask, key) {
  var parts = []
  for (var i = 0; i < MODS.length; i++) if (mask & MODS[i].mask) parts.push(MODS[i].name)
  parts.push(key)
  return parts.join(" + ")
}

/** The other way: "SUPER + CTRL + Right" to { mask, key }, or null. */
function parse(combo) {
  if (!combo) return null
  var parts = String(combo).split("+").map(function (p) { return p.trim() }).filter(function (p) { return p !== "" })
  if (parts.length === 0) return null
  var mask = 0
  var key = ""
  for (var i = 0; i < parts.length; i++) {
    var upper = parts[i].toUpperCase()
    var mod = null
    for (var j = 0; j < MODS.length; j++) {
      if (MODS[j].name === upper || (upper === "CONTROL" && MODS[j].name === "CTRL")
          || (upper === "MOD4" && MODS[j].name === "SUPER") || (upper === "WIN" && MODS[j].name === "SUPER"))
        mod = MODS[j]
    }
    if (mod) mask |= mod.mask
    else key = parts[i]
  }
  return key === "" ? null : { mask: mask, key: key }
}

function sameKey(a, b) { return String(a).toLowerCase() === String(b).toLowerCase() }

/** What else is on this combination: [{ description, dispatcher }], from
    `hyprctl binds -j`, not counting Aerial's own bindings. */
function conflicts(binds, combo) {
  var want = parse(combo)
  if (!want) return []
  var out = []
  for (var i = 0; i < binds.length; i++) {
    var b = binds[i]
    if (b.mouse || b.submap) continue
    // Hyprland also reports locks (Caps, Num) in the mask; they do not count.
    if ((b.modmask & ~(2 | 16)) !== want.mask) continue
    if (!sameKey(b.key, want.key)) continue
    var what = b.description || (b.dispatcher === "__lua" ? "" : (b.dispatcher + " " + b.arg).trim())
    if (String(what).indexOf("Aerial:") === 0) continue
    out.push({ description: what || "an unnamed binding" })
  }
  return out
}

/** The Aerial section of a bindings file: { actionId: combo }. */
function read(text) {
  var out = {}
  var start = text.indexOf(BEGIN)
  var end = text.indexOf(END)
  if (start < 0 || end < start) return out
  var body = text.slice(start, end).split("\n")
  for (var i = 0; i < body.length; i++) {
    var m = body[i].match(/^\s*o\.bind\(\s*"([^"]+)"\s*,\s*"([^"]+)"/)
    if (!m) continue
    for (var a = 0; a < ACTIONS.length; a++) {
      if (ACTIONS[a].description === m[2]) out[ACTIONS[a].id] = m[1]
    }
  }
  return out
}

/** The section for these shortcuts. A combination something else already
    has is unbound first — Omarchy's own advice for replacing a binding —
    or both would fire. */
function section(shortcuts, takeOver) {
  var lines = [
    BEGIN + " — written by the Aerial settings panel; changes here are overwritten there.",
  ]
  for (var a = 0; a < ACTIONS.length; a++) {
    var act = ACTIONS[a]
    var combo = shortcuts[act.id]
    if (!combo) continue
    if (takeOver && takeOver[act.id]) lines.push('hl.unbind("' + combo + '")')
    lines.push('o.bind("' + combo + '", "' + act.description + '", ' + act.dispatcher + ')')
  }
  lines.push(END)
  return lines.join("\n")
}

/** The whole file with the section replaced — or added at the end, or
    removed when there is nothing left in it. */
function write(text, shortcuts, takeOver) {
  var any = false
  for (var a = 0; a < ACTIONS.length; a++) if (shortcuts[ACTIONS[a].id]) any = true
  var block = any ? section(shortcuts, takeOver) : ""
  var start = text.indexOf(BEGIN)
  var end = text.indexOf(END)
  if (start >= 0 && end > start) {
    var after = text.slice(end + END.length)
    if (after.charAt(0) === "\n") after = after.slice(1)
    var before = text.slice(0, start)
    if (!any) return before.replace(/\n+$/, "\n") + after
    return before + block + "\n" + after
  }
  if (!any) return text
  var head = text.replace(/\n*$/, "\n")
  return head + "\n" + block + "\n"
}
