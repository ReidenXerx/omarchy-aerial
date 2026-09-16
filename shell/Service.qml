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
  readonly property bool showing: t > 0.001
  // True once the user has committed: clicks land, keys are grabbed.
  readonly property bool open: t > 0.999

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

  function toggle() { service.t > 0.5 ? service.hide() : service.show() }

  // Animate the rest of the way, carrying whatever speed the fingers had. A
  // swipe let go at the halfway mark takes its time; one thrown is already
  // moving, so finishing it slowly would feel like the desktop caught it.
  function glideTo(wantOpen, speed) {
    const target = wantOpen ? 1 : 0
    const remaining = Math.abs(target - service.t)
    const haste = 1 + Math.min(3, Math.max(0, speed || 0))
    opener.to = target
    opener.duration = Math.max(90, Math.round(260 * remaining / haste))
    opener.restart()
  }

  NumberAnimation {
    id: opener
    target: service
    property: "t"
    duration: 240
    easing.type: Easing.OutCubic
  }

  // ---------------------------------------------------------------- the swipe

  readonly property string gestureFile: {
    const url = Qt.resolvedUrl("../app/gesture.lua").toString()
    return url.startsWith("file://") ? url.slice(7) : url
  }

  Process { id: lua }

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

  function registerGesture() {
    const path = service.gestureFile.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    lua.command = ["/usr/bin/hyprctl", "eval", 'dofile("' + path + '")']
    lua.running = true
  }

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
    const value = Math.max(0, Math.min(1, parseFloat(parts[0]) || 0))
    const speed = parseFloat(parts[1]) || 0
    const cancelled = parts[2] === "1"

    if (what === "shape") {
      // Only ever sent when the Lua half could not find the movement in what
      // Hyprland gave it, which means this plugin needs updating.
      console.warn("aerial: cannot read the swipe — Hyprland's gesture payload is now " + rest)
      return
    }

    // "allup-move" is the four-finger version of "up-move", and so on.
    const dash = what.lastIndexOf("-")
    if (dash < 0) return
    const who = what.slice(0, dash)
    const phase = what.slice(dash + 1)
    const opening = who === "up" || who === "allup"
    const wantsEverything = who === "allup" || who === "alldown"

    switch (phase) {
    case "begin":
      if (opening) {
        if (service.t > 0.999) return
        service.everything = wantsEverything
        service.aim()
        service.arming()
      } else {
        // Swiping down puts the overview away from anywhere it is visible,
        // including halfway through opening. On the bare desktop the gesture
        // belongs to whoever else wants it.
        if (service.t < 0.05) return
      }
      settle.stop()
      opener.stop()
      service.scrubFrom = service.t
      service.scrub = who
      break

    case "move":
      if (service.scrub !== who) return
      service.t = opening
        ? service.scrubFrom + (1 - service.scrubFrom) * value
        : service.scrubFrom * (1 - value)
      break

    case "end":
      if (service.scrub !== who) return
      service.scrub = ""
      // Judged on where it ended up, not on the swipe alone, so a gesture that
      // carried on from a half-open overview is measured from what you saw.
      if (cancelled) service.glideTo(service.t > 0.5, 0)
      else if (opening) service.glideTo(service.t > 0.5 || service.flicked(value, speed), speed)
      else service.glideTo(!(service.t < 0.5 || service.flicked(value, speed)), speed)
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
      const wasMostlyOpen = service.t > 0.5
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

      if (name === "configreloaded") {
        // A reload drops runtime gestures the same way it drops runtime binds.
        rearm.restart()
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
  }
}
