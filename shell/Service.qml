import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// The state the overview is in, and the two ways it gets there.
//
// `t` is the whole animation: 0 is the desktop as it is, 1 is the overview
// fully open, and every thumbnail's position, size and opacity is a blend of
// the two at `t`. A keypress animates it; a trackpad swipe *sets* it, frame by
// frame, which is why the gesture feels attached to your fingers rather than
// like a button that plays a video.
//
// Hyprland drives the gesture end: app/gesture.lua registers a three-finger
// gesture whose update callback emits a fraction on the event socket, which
// arrives here as a custom event. No compositor plugin, no daemon, nothing to
// rebuild when Hyprland updates.
Item {
  id: service

  property var shell: null
  property var manifest: null

  // 0 = closed, 1 = open. Anything between is a swipe in progress.
  property real t: 0
  // Not "visible": Item declares that FINAL, and shadowing it stops the whole
  // plugin loading with "Cannot override FINAL property".
  readonly property bool showing: t > 0.001 || service.deskSlide

  // Three fingers sideways on the bare desktop, sliding between workspaces.
  // The overview is up for it, at no zoom at all: every card standing exactly
  // on its window, the next desktop's alongside, and the spread slides the
  // way it does when the overview is open. See `deskSwipe` below for why
  // this is the plugin's to do rather than Hyprland's.
  property bool deskSlide: false
  // True once the user has committed: clicks land, keys are grabbed.
  // With a hysteresis: the spring lands with a bounce, and an overview that
  // dipped to 0.98 on the rebound must not drop the keyboard and grab it
  // again — or swap what three fingers sideways mean — on the way.
  property bool open: false
  onTChanged: {
    if (service.t > 0.995) service.open = true
    else if (service.t < 0.9) service.open = false
  }

  // Where the fingers have put the overview, which `t` chases. Decisions —
  // open or not, when they lift — are made on this, not on the spring lagging
  // behind it.
  property real goal: 0

  // Which monitor the overview belongs to — the one the pointer was on.
  property string monitorName: ""

  // Which gesture currently owns `t`: "", "up", "down", "allup" or "alldown".
  property string scrub: ""
  // Three fingers shows this workspace; four shows every window there is.
  property bool everything: false
  // Where `t` was when the fingers landed, so a gesture continues from what is
  // on screen instead of snapping to an end first.
  property real scrubFrom: 0

  readonly property int fingers: 3

  // "Get ready" — raised before `t` leaves zero, so the overlay can take its
  // snapshot of the windows on a frame where nothing is moving yet.
  signal arming()

  // Three fingers sideways while the overview is open. The overlay owns the
  // workspaces, so it decides what a sideways swipe means; this only relays it.
  // `phase` is "begin", "move" or "end"; `value` is how many workspaces the
  // fingers have travelled, positive toward the next; `velocity` is the same
  // per second.
  signal sideSwipe(string phase, real value, real velocity, bool cancelled)

  // A shortcut asked for the next (+1) or previous (-1) desktop. The overlay
  // slides there the way a swipe would, overview open or not.
  signal stepRequested(int step)

  /** Slide one desktop over, from a key. Bound in Hyprland as
      hl.dsp.event("aerial,go:next") or "aerial,go:prev", which reaches here
      without starting a process for every keypress. */
  function go(where) {
    const step = where === "next" ? 1 : (where === "prev" ? -1 : 0)
    if (step === 0) return
    if (!service.open) {
      // Mid-swipe, or half open or closed: not now.
      if (service.showing || service.scrub !== "") return
      service.deskSlide = true
      service.aim()
      service.arming()
      service.refreshModels()
    }
    service.stepRequested(step)
  }

  // ---------------------------------------------------------------- opening

  function aim() {
    service.monitorName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  }

  // Ask the compositor what is really there. Quickshell's model is filled from
  // events, and a window that opened while nothing was watching has no
  // geometry and the wrong workspace — which is an empty overview.
  function refreshModels() {
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
  }

  function show() {
    service.aim()
    service.arming()
    service.refreshModels()
    // Let the answers arrive before the thumbnails start flying, or they fly
    // from nowhere. Short enough to be invisible, long enough for one round
    // trip; the gesture skips it because at the start of a swipe the
    // thumbnails are still sitting exactly on top of their windows.
    settle.restart()
  }

  Timer {
    id: settle
    interval: 70
    onTriggered: service.glideTo(true, 0)
  }

  function hide() {
    settle.stop()
    service.scrub = ""
    service.glideTo(false, 0)
  }

  // Past fully open the overview keeps going with the fingers — the cards go
  // on shrinking toward the strip — but gives less and less for each
  // centimetre, the way a scroll view does past its end, and springs back to
  // its proper size when they lift. Starts out one-to-one, so there is no
  // point where it visibly catches; `stretch` is how far it could ever get.
  readonly property real stretch: 0.3
  function rubber(value) {
    if (value <= 1) return value
    const over = value - 1
    return 1 + service.stretch * (1 - 1 / (1 + over / service.stretch))
  }

  function toggle() { service.goal > 0.5 ? service.hide() : service.show() }

  // How it lands once the fingers lift: back from a stretch, or the rest of
  // the way open or closed.
  readonly property real landStiffness: 20
  readonly property real landDamping: 0.9

  // Fingers down or the spring still moving: `t` is changing every frame and
  // everything drawn from it must follow it exactly, not ease toward it.
  readonly property bool animating: tSpring.running || service.scrub !== ""

  // How fast the fingers were moving `t` when last seen, in `t` per second —
  // measured on what is on screen, stretch and all, so the spring picks up at
  // exactly the speed the overview already had.
  property real handSpeed: 0
  property real lastGoal: 0
  property double lastAt: 0

  function track(goal) {
    const now = Date.now()
    const dt = (now - service.lastAt) / 1000
    if (service.lastAt > 0 && dt > 0 && dt < 0.1) {
      const v = (goal - service.lastGoal) / dt
      // Smoothed over a few events: single samples at 125 a second are noisy.
      service.handSpeed = service.handSpeed * 0.6 + v * 0.4
    } else {
      service.handSpeed = 0
    }
    service.lastGoal = goal
    service.lastAt = now
  }

  // Head for open or closed. The spring already has whatever speed the
  // fingers gave it, so letting go is only a change of target; `velocity` (in
  // `t` per second) tops that up when the fingers were faster than the spring
  // had caught up to — a flick — and only in the direction it is going.
  function glideTo(wantOpen, speed, velocity) {
    const target = wantOpen ? 1 : 0
    service.goal = target
    if (!tSpring.running) tSpring.value = service.t
    tSpring.stiffness = service.landStiffness
    tSpring.damping = service.landDamping
    // Straight on at the speed it had, whichever way that was: flung past
    // open it carries on a little and comes back, let go mid-stretch it
    // eases back from wherever it was heading. Starting from a standstill
    // instead is the stall you feel as lag.
    if (velocity !== undefined) tSpring.velocity = Math.max(-8, Math.min(8, velocity))
    tSpring.follow(target)
  }

  // Fingers down: the overview is theirs, exactly, until they lift.
  function grab() {
    tSpring.hold()
    tSpring.velocity = 0
    service.goal = service.t
    service.handSpeed = 0
    service.lastAt = 0
  }

  Spring {
    id: tSpring
    floor: 0
    onValueChanged: service.t = tSpring.value
  }

  // ---------------------------------------------------------------- the swipe

  readonly property string gestureFile: {
    const url = Qt.resolvedUrl("../app/gesture.lua").toString()
    return url.startsWith("file://") ? url.slice(7) : url
  }

  Process {
    id: lua
    // Registering the gestures resets nothing sideways, but a fresh Lua state
    // after a config reload has nothing registered at all: say it again.
    onRunningChanged: if (!running) {
      service.sidewaysSent = ""
      service.sendSideways()
    }
  }

  // The desktop's own wallpaper, which the overview sits on and every workspace
  // tile is a small picture of. Omarchy keeps it behind a symlink that moves
  // when the theme changes, so resolve it rather than remember it — but never
  // while a swipe is running: this looks it up at startup and whenever the
  // overview closes, so it is already known by the time one opens.
  property string wallpaper: ""

  // Resolved in QML rather than by a shell, and `readlink` by absolute path:
  // a plugin runs unsandboxed, so it should not be spawning shells to expand a
  // variable it can read itself.
  readonly property string backgroundLink: {
    const state = String(Quickshell.env("XDG_STATE_HOME") || "")
    const home = String(Quickshell.env("HOME") || "")
    const base = state !== "" ? state : (home !== "" ? home + "/.local/state" : "")
    return base === "" ? "" : base + "/omarchy/current/background"
  }

  Process {
    id: findWallpaper
    command: ["/usr/bin/readlink", "-f", service.backgroundLink]
    stdout: StdioCollector {
      onStreamFinished: {
        const path = text.trim()
        // Only ever a path the compositor's own theme points at, and only used
        // as an image source.
        if (path.startsWith("/")) service.wallpaper = path
      }
    }
  }

  function findTheWallpaper() {
    if (service.backgroundLink === "" || findWallpaper.running) return
    findWallpaper.running = true
  }

  onShowingChanged: {
    if (service.showing) return
    service.findTheWallpaper()
    // Reset once it is fully away, not while it is still closing, or the
    // spread rearranges itself on the way out.
    service.everything = false
  }

  // ------------------------------------------------------------ decoration

  // How Hyprland dresses a window: its rounding, border and shadow. At the
  // start of a swipe every card sits exactly on top of its window, and the
  // desktop behind has already been painted over, so a card has to look like
  // the window it stands in for — not like a square screenshot of its
  // contents — or the first frame of every swipe is a visible jump.
  property var deco: ({
    rounding: 0,
    border: 0,
    activeBorder: "transparent",
    inactiveBorder: "transparent",
    shadow: false,
    shadowRange: 0,
    shadowColor: "transparent",
    shadowColorInactive: "transparent",
    blur: false,
    blurSize: 8,
    blurPasses: 1,
    blurNoise: 0,
    blurContrast: 1,
    blurBrightness: 1,
    blurVibrancy: 0,
    blurVibrancyDarkness: 0,
    shadowPower: 1,
    roundingPower: 2,
  })

  readonly property var decoOptions: [
    "decoration:rounding", "general:border_size",
    "general:col.active_border", "general:col.inactive_border",
    "decoration:shadow:enabled", "decoration:shadow:range",
    "decoration:shadow:color", "decoration:shadow:color_inactive",
    "decoration:blur:enabled", "decoration:blur:size", "decoration:blur:passes",
    "decoration:blur:noise", "decoration:blur:contrast", "decoration:blur:brightness",
    "decoration:blur:vibrancy", "decoration:blur:vibrancy_darkness",
    "decoration:shadow:render_power", "decoration:rounding_power",
  ]

  Process {
    id: readDeco
    command: ["/usr/bin/hyprctl", "--batch",
              service.decoOptions.map(o => "j/getoption " + o).join("; ")]
    stdout: StdioCollector {
      onStreamFinished: service.takeDeco(text)
    }
  }

  // Hyprland prints colours as AARRGGBB, which is what Qt reads after a "#".
  // A gradient is a list of them and an angle; the first colour stands for it.
  function colourOf(entry) {
    const raw = entry && (entry.gradient || entry.color || entry.str)
    const hex = String(raw || "").trim().split(/\s+/)[0]
    return /^[0-9a-fA-F]{8}$/.test(hex) ? "#" + hex : "transparent"
  }

  function takeDeco(text) {
    const byName = ({})
    for (const chunk of String(text).split(/\n\s*\n/)) {
      try {
        const entry = JSON.parse(chunk)
        if (entry && entry.option) byName[entry.option] = entry
      } catch (e) {}
    }
    const num = name => {
      const e = byName[name]
      return e ? Number(e.int !== undefined ? e.int : (e.float !== undefined ? e.float : 0)) : 0
    }
    const shadowOn = byName["decoration:shadow:enabled"]
    const blurOn = byName["decoration:blur:enabled"]
    service.deco = {
      rounding: Math.max(0, num("decoration:rounding")),
      border: Math.max(0, num("general:border_size")),
      activeBorder: service.colourOf(byName["general:col.active_border"]),
      inactiveBorder: service.colourOf(byName["general:col.inactive_border"]),
      shadow: !!(shadowOn && (shadowOn.bool === true || shadowOn.int === 1)),
      shadowRange: Math.max(0, num("decoration:shadow:range")),
      shadowColor: service.colourOf(byName["decoration:shadow:color"]),
      shadowColorInactive: service.colourOf(byName["decoration:shadow:color_inactive"]
                                            || byName["decoration:shadow:color"]),
      blur: !!(blurOn && (blurOn.bool === true || blurOn.int === 1)),
      blurSize: Math.max(1, num("decoration:blur:size")),
      blurPasses: Math.max(1, num("decoration:blur:passes")),
      blurNoise: num("decoration:blur:noise"),
      blurContrast: byName["decoration:blur:contrast"] ? num("decoration:blur:contrast") : 1,
      blurBrightness: byName["decoration:blur:brightness"] ? num("decoration:blur:brightness") : 1,
      blurVibrancy: num("decoration:blur:vibrancy"),
      blurVibrancyDarkness: num("decoration:blur:vibrancy_darkness"),
      shadowPower: Math.max(1, Math.min(4, num("decoration:shadow:render_power") || 1)),
      roundingPower: byName["decoration:rounding_power"] ? num("decoration:rounding_power") : 2,
    }
  }

  function readDecoration() {
    if (!readDeco.running) readDeco.running = true
  }

  function registerGesture() {
    const path = service.gestureFile.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    lua.command = ["/usr/bin/hyprctl", "eval", 'dofile("' + path + '")']
    lua.running = true
  }

  // Three fingers sideways slide between workspaces, overview open or not.
  //
  // Hyprland has a workspace swipe of its own, and it follows the fingers
  // well enough — but Omarchy turns workspace animations off, so switching
  // with the keyboard is instant, and that leaves the swipe nothing to finish
  // with: let go and the desktop snaps, forward or back, from wherever it was.
  // Turning the animation back on would make every SUPER+number switch slide
  // too. So the swipe on the desktop is this plugin's, finished with the same
  // spring as the overview's, and the keyboard is left alone.
  //
  // Set from the settings panel; false leaves three fingers sideways alone
  // on the desktop.
  property bool deskSwipe: true

  // Frost see-through windows' cards with Hyprland's own blur, live. Set from
  // the settings panel; it costs GPU time while the overview is up.
  property bool frost: true

  // ---------------------------------------------------------- recording keys

  // The settings panel is listening for a shortcut: Hyprland's bindings are
  // parked in an empty submap meanwhile (see app/gesture.lua), so a combination
  // that is already taken reaches the panel instead of running.
  property bool recording: false

  Process { id: submapLua }

  function setRecording(on) {
    service.recording = on
    submapLua.command = ["/usr/bin/hyprctl", "eval",
                         'hl.dispatch(hl.dsp.submap("' + (on ? "aerial-record" : "reset") + '"))']
    submapLua.running = true
    if (on) recordingLimit.restart()
    else recordingLimit.stop()
  }

  // Never left in the submap: however the panel stops listening — or fails
  // to — the keyboard comes back.
  Timer {
    id: recordingLimit
    interval: 10000
    onTriggered: service.setRecording(false)
  }

  readonly property string sideways: service.open || service.deskSwipe ? "slide"
                                   : (!service.showing ? "none" : "")
  property string sidewaysSent: ""

  // In an eval of its own, after the gestures exist: if the user already has
  // a horizontal swipe, Hyprland refuses ours and that refusal must not take
  // the up and down gestures with it.
  Process {
    id: sidewaysLua
    onRunningChanged: if (!running && service.sidewaysSent !== service.sideways) service.sendSideways()
  }

  function sendSideways() {
    if (lua.running || sidewaysLua.running) return
    const mode = service.sideways
    if (mode === "") return   // in between: keep whatever is there
    service.sidewaysSent = mode
    sidewaysLua.command = ["/usr/bin/hyprctl", "eval", '__aerial_horizontal("' + mode + '")']
    sidewaysLua.running = true
  }

  onSidewaysChanged: service.sendSideways()

  // A swipe shorter than this cannot open the overview however fast it was:
  // a flick has to be deliberate, not a brush against the pad.
  readonly property real flickFloor: 0.08
  // Travel per millisecond, as the Lua half measures it.
  readonly property real flickSpeed: 2.0

  /** Was that swipe thrown rather than dragged? */
  function flicked(fraction, speed) {
    return speed >= service.flickSpeed && fraction >= service.flickFloor
  }

  // What the Lua half sends, one fraction at a time.
  function onGesture(data) {
    const cut = data.indexOf(":")
    const what = cut < 0 ? data : data.slice(0, cut)
    const rest = cut < 0 ? "" : data.slice(cut + 1)
    const parts = rest.split(":")
    const raw = parseFloat(parts[0]) || 0
    const value = Math.max(0, raw)
    const speed = parseFloat(parts[1]) || 0
    const cancelled = parts[2] === "1"
    // Along the swipe, in progress per second. Older gesture halves did not
    // send it, and then there is nothing to carry on from.
    const velocity = parts.length > 3 ? (parseFloat(parts[3]) || 0) : undefined

    if (what === "shape") {
      // Only ever sent when the Lua half could not find the movement in what
      // Hyprland gave it, which means this plugin needs updating.
      console.warn("aerial: cannot read the swipe — Hyprland's gesture payload is now " + rest)
      return
    }

    if (what === "go") {
      service.go(rest)
      return
    }

    // "allup-move" is the four-finger version of "up-move", and so on.
    const dash = what.lastIndexOf("-")
    if (dash < 0) return
    const who = what.slice(0, dash)
    const phase = what.slice(dash + 1)

    if (who === "side") {
      if (phase === "begin" && !service.open) {
        // Half open or half closed, a sideways swipe means nothing.
        if (service.showing) return
        if (!service.deskSwipe) {
          // It reached us, so Hyprland thinks it is still ours — a shell
          // restarted mid-reload can leave it that way. Hand it back.
          service.sidewaysSent = ""
          service.sendSideways()
          return
        }
        // On the desktop: put the overview up, at no zoom, to slide.
        service.deskSlide = true
        service.aim()
        service.arming()
        service.refreshModels()
      }
      service.sideSwipe(phase, raw, velocity || 0, cancelled)
      return
    }
    const opening = who === "up" || who === "allup"
    const wantsEverything = who === "allup" || who === "alldown"

    switch (phase) {
    case "begin":
      if (opening && service.open) {
        // Already open: swiping up again is only the stretch, and springs
        // back. Nothing is re-read, so nothing on screen is rebuilt.
      } else if (opening) {
        service.everything = wantsEverything
        service.aim()
        service.arming()
        // The snapshot above is what the cards are built from; where each
        // window really is right now arrives a few milliseconds later and the
        // cards follow it, so a window resized since the last event starts
        // the swipe at its true size.
        service.refreshModels()
      } else {
        // Swiping down puts the overview away from anywhere it is visible,
        // including halfway through opening. On the bare desktop the gesture
        // belongs to whoever else wants it.
        if (service.t < 0.05) return
      }
      settle.stop()
      service.grab()
      service.scrubFrom = service.t
      service.scrub = who
      break

    case "move":
      if (service.scrub !== who) return
      if (opening) {
        // The first full swipe's worth of travel covers whatever was left to
        // open; everything past it is stretch. Already open, it is all stretch.
        const from = service.scrubFrom
        const raw = from >= 0.999 ? 1 + value
                  : value <= 1 ? from + (1 - from) * value
                  : 1 + (value - 1)
        service.goal = service.rubber(raw)
      } else {
        service.goal = service.scrubFrom * (1 - Math.min(1, value))
      }
      tSpring.value = service.goal
      service.track(service.goal)
      break

    case "end":
      if (service.scrub !== who) return
      // Judged on where it ended up, not on the swipe alone, so a gesture that
      // carried on from a half-open overview is measured from what you saw.
      {
        let wantOpen
        if (cancelled) wantOpen = service.goal > 0.5
        else if (opening) wantOpen = service.goal > 0.5 || service.flicked(value, speed)
        else wantOpen = !(service.goal < 0.5 || service.flicked(value, speed))

        // The speed the overview had on screen as the fingers lifted — none,
        // if they had come to rest first.
        const resting = Date.now() - service.lastAt > 80
        const carry = cancelled || resting ? 0 : service.handSpeed
        // Spring running before the fingers are let go of, so nothing ever
        // sees a frame where neither is moving the overview.
        service.glideTo(wantOpen, speed, carry)
      }
      service.scrub = ""
      break

    default:
      return
    }

    watchdog.restart()
  }

  // A gesture that stops sending without a lift — a reload mid-swipe, a
  // compositor restart — must not strand the overview at 40%. Hyprland does
  // report the lift, so this is a net and nothing more: at 450ms it was firing
  // during ordinary pauses and snapping the animation out from under the hand.
  Timer {
    id: watchdog
    interval: 1400
    onTriggered: {
      if (service.scrub === "") return
      const wasMostlyOpen = service.goal > 0.5
      service.scrub = ""
      service.glideTo(wasMostlyOpen, 0)
    }
  }

  // ---------------------------------------------------------------- listening

  // Events that change what the overview would show. Refreshing on these keeps
  // the model warm, so opening never has to wait for the compositor to answer.
  readonly property var stirring: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "workspace", "workspacev2", "createworkspace", "createworkspacev2",
    "destroyworkspace", "destroyworkspacev2", "fullscreen",
    "changefloatingmode", "focusedmon", "monitoraddedv2", "monitorremoved",
  ]

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      const name = event.name || ""

      // Left the recording submap some other way (Escape does, in the
      // compositor): stop listening.
      if (name === "submap" && service.recording && event.data !== "aerial-record") {
        service.recording = false
        recordingLimit.stop()
        return
      }

      if (name === "configreloaded") {
        // A reload drops runtime gestures the same way it drops runtime binds.
        rearm.restart()
        service.readDecoration()
        return
      }

      // hl.dsp.event("aerial,…") arrives as custom>>aerial,…
      const data = event.data || ""
      if (name === "aerial") {
        service.onGesture(data)
        return
      }
      if (name === "custom" && data.startsWith("aerial,")) {
        service.onGesture(data.slice(7))
        return
      }

      if (service.stirring.indexOf(name) >= 0) freshen.restart()
    }
  }

  Timer {
    id: freshen
    interval: 180
    onTriggered: service.refreshModels()
  }

  Timer {
    id: rearm
    interval: 600
    onTriggered: service.registerGesture()
  }

  Component.onCompleted: {
    service.registerGesture()
    service.findTheWallpaper()
    service.readDecoration()
  }
}
