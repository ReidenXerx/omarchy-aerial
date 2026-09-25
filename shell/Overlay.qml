import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../app/Layout.js" as Layout

// The overview: every window, live, spread out — one surface per screen.
//
// Nothing here is a screenshot. Each thumbnail is a ScreencopyView of the real
// toplevel, so a video keeps playing and a terminal keeps scrolling while you
// look for it.
//
// This half holds what all the screens share: the snapshot of what is on the
// desktop, what you have selected, typed or picked up, and the arithmetic for
// acting on it. Surface.qml draws one screen's worth.
Scope {
  id: root

  // The shell hands these to an overlay when it loads it. The service may not
  // exist yet when the overlay does, so it is looked up again until it does.
  property var shell: null
  property var manifest: null
  property var service: null

  function findService() {
    if (root.service || !root.shell || typeof root.shell.serviceFor !== "function") return
    root.service = root.shell.serviceFor("reidenxerx.aerial")
  }

  onShellChanged: root.findService()

  Timer {
    interval: 800
    repeat: true
    running: !root.service
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  // What the shell calls when something asks for the overview by name.
  function open(payload) { if (root.service) root.service.show() }
  function close() { if (root.service) root.service.hide() }
  function toggle() { if (root.service) root.service.toggle() }

  readonly property bool opened: root.service ? root.service.showing : false
  // Where the overview is drawn: `t`, held at nothing until the overview is
  // ready to appear, then let catch up. The fingers have moved on by the
  // time every capture is in, and appearing where they now are would be a
  // jump; appearing exactly on the desktop and catching up is not.
  property real reveal: 0
  readonly property real t: root.settleIn((root.service ? root.service.t : 0) * root.reveal)

  // Within the last few percent of closed, eased the rest of the way down to
  // exactly nothing. The overview is put away once `t` is all but zero, and a
  // card even a thousandth of the way to its slot is a pixel or two off its
  // window — which, on the frame the window takes back over, is a twitch.
  // Continuous with `t` above the knee, so nothing jumps.
  readonly property real knee: 0.03
  function settleIn(v) { return v < root.knee ? v * v / root.knee : v }

  NumberAnimation {
    id: revealing
    target: root
    property: "reveal"
    to: 1
    duration: 40
    easing.type: Easing.OutCubic
  }

  /** The overview is on screen, matching the desktop exactly: start moving. */
  function revealed() { if (root.reveal < 1 && !revealing.running) revealing.restart() }
  readonly property bool active: root.service ? root.service.open : false
  // `t` is changing every frame, and cards must follow it, not ease after it.
  readonly property bool settling: root.service ? root.service.animating : false
  readonly property bool everything: root.service ? root.service.everything : false
  readonly property string leadMonitor: root.service ? root.service.monitorName : ""

  // The real windows stay mapped underneath, so the veil is what hides them. It
  // ramps faster than `t`: by the time a thumbnail has visibly moved off its
  // window, the window it came from is already gone.
  readonly property real veil: Math.pow(Math.min(1, Math.max(0, root.t)), 0.65)

  readonly property string wallpaper: root.service ? root.service.wallpaper : ""
  readonly property var deco: root.service ? root.service.deco : ({ rounding: 0, border: 0, shadow: false })
  readonly property bool frost: root.service ? root.service.frost : true

  // How far the cards have left the windows they stand in for, for crossfading
  // Hyprland's look (rounding, border, shadow) into the overview's. Done by
  // the time the spread is half out, so the windows read as cards, not as
  // shrinking desktops.
  readonly property real dress: Math.min(1, Math.max(0, root.t / 0.6))
  readonly property url wallpaperUrl: root.wallpaper ? Qt.resolvedUrl("file://" + root.wallpaper) : ""

  // Every thumbnail refreshes off this one clock rather than running live.
  // Twelve frames a second is plenty to recognise a window by, and it is what
  // keeps the overview at a few percent of a core instead of half of one.
  property int beat: 0

  Timer {
    interval: 80
    repeat: true
    running: root.opened
    onTriggered: root.beat++
  }

  // ------------------------------------------------------------- what is there

  /** Whether a window has focus: first in Hyprland's focus history. Its own
      `activated` can lag a focus change, and a card that thinks the wrong
      window is focused draws the wrong border and glow on the one frame that
      has to match exactly. */
  function isActive(top) {
    const ipc = top.lastIpcObject || {}
    if (ipc.focusHistoryID !== undefined) return ipc.focusHistoryID === 0
    return top.activated === true
  }

  /** The rectangle a window occupies, in its own monitor's logical pixels. */
  function rectOf(top) {
    const ipc = top.lastIpcObject || {}
    const at = ipc.at || [0, 0]
    const size = ipc.size || [0, 0]
    if (size[0] <= 0 || size[1] <= 0) return null
    return { x: at[0], y: at[1], w: size[0], h: size[1], appId: ipc.class || "" }
  }

  // Every window there is, in a plain form the layout can work with.
  //
  // Recomputed whenever Hyprland's model changes, which must never happen while
  // the overview is moving: a new array means the Repeater throws away every
  // delegate and builds new ones, and rebuilding a live capture halfway through
  // a swipe is a visible hitch. So the overview draws from a snapshot taken on
  // the frame the gesture arms, and `sync()` is the only thing that replaces it.
  readonly property var liveShot: {
    const out = []
    for (const top of (Hyprland.toplevels.values || [])) {
      if (!top.wayland || !top.workspace || top.workspace.id <= 0) continue
      const rect = root.rectOf(top)
      if (!rect) continue
      const mon = top.monitor
      if (!mon) continue
      out.push({
        key: top.address,
        // The capture handle, not Hyprland's wrapper: ScreencopyView wants the
        // Wayland toplevel, and paints nothing at all if given anything else.
        capture: top.wayland,
        title: top.title || "",
        appId: rect.appId,
        workspace: top.workspace.id,
        monitor: mon.name,
        active: root.isActive(top),
        floating: (top.lastIpcObject || {}).floating === true,
        // Hyprland reports global coordinates; a surface covers one monitor.
        x: rect.x - mon.x,
        y: rect.y - mon.y,
        w: rect.w,
        h: rect.h,
      })
    }
    return out
  }

  // Where every window is right now, by address, and how Hyprland is drawing
  // it. The cards take their resting place from here rather than from the
  // snapshot: this changes without rebuilding anything, so a window whose
  // geometry was stale when the swipe began snaps to the truth within a frame
  // or two, and a closing overview flies each card home to wherever its window
  // actually is by then.
  readonly property var geo: {
    const out = ({})
    for (const top of (Hyprland.toplevels.values || [])) {
      const rect = root.rectOf(top)
      const mon = top.monitor
      if (!rect || !mon) continue
      const tags = (top.lastIpcObject || {}).tags || []
      // Omarchy's default window opacity: 0.985 focused, 0.96 not, for every
      // window still wearing its tag.
      const tagged = tags.some(t => String(t).replace(/\*$/, "") === "default-opacity")
      const active = root.isActive(top)
      out[top.address] = {
        x: rect.x - mon.x,
        y: rect.y - mon.y,
        w: rect.w,
        h: rect.h,
        active: active,
        floating: (top.lastIpcObject || {}).floating === true,
        title: top.title || "",
        opacity: tagged ? (active ? 0.985 : 0.96) : 1,
      }
    }
    return out
  }

  readonly property var liveWorkspaces: {
    // Hyprland only makes a workspace once something is on it, so the ones that
    // exist are not the ones you can use. Always offer the first five — the
    // rule the bar follows too — plus any other that exists, so there is
    // somewhere to drag a window to before you have ever been there.
    const ids = [1, 2, 3, 4, 5]
    const existing = Hyprland.workspaces.values || []
    for (const space of existing) {
      if (space.id > 0 && space.id <= 10 && ids.indexOf(space.id) === -1) ids.push(space.id)
    }
    ids.sort((a, b) => a - b)

    const here = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    const out = ids.map(id => {
      const real = existing.find(w => w.id === id) || null
      return {
        id: id,
        name: real && real.name ? real.name : String(id),
        focused: id === here,
        real: real !== null,
        fresh: false,
        // Which screen it is on, if it exists yet. One that does not will be
        // made on whichever screen switches to it.
        monitor: real && real.monitor ? real.monitor.name : "",
      }
    })

    // And somewhere to put things when five desktops are not enough.
    const next = ids[ids.length - 1] + 1
    if (next <= 10) {
      out.push({ id: next, name: "+", focused: false, real: false, fresh: true })
    }
    return out
  }

  // What each workspace holds, as fractions of its monitor, so a strip tile can
  // draw the shape of a desktop you are not looking at.
  readonly property var livePlans: {
    const out = ({})
    for (const top of (Hyprland.toplevels.values || [])) {
      const space = top.workspace
      if (!space || space.id <= 0) continue
      const rect = root.rectOf(top)
      if (!rect) continue
      const mon = top.monitor
      if (!mon || mon.scale <= 0) continue
      const width = mon.width / mon.scale
      const height = mon.height / mon.scale
      if (width <= 0 || height <= 0) continue
      if (!out[space.id]) out[space.id] = []
      out[space.id].push({
        x: (rect.x - mon.x) / width,
        y: (rect.y - mon.y) / height,
        w: rect.w / width,
        h: rect.h / height,
        appId: rect.appId,
        active: root.isActive(top),
      })
    }
    return out
  }

  // What the overview is drawing: the snapshot, never the live models.
  property var shot: []
  property var workspaces: []
  property var plans: ({})

  // The cards are kept between openings, not rebuilt each time: building one
  // opens a capture of its window, and the first frame of a new capture takes
  // long enough that a short swipe was over before the overview could appear.
  // So the snapshot is only replaced when what is there has changed — a
  // window opened, closed, or moved to another desktop — and otherwise the
  // cards, their captures and their last frames are all still there. Where
  // each window is, and what it is called, come from the live model anyway.
  function sameWindows(a, b) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) {
      const x = a[i], y = b[i]
      if (x.key !== y.key || x.workspace !== y.workspace || x.monitor !== y.monitor || x.floating !== y.floating)
        return false
    }
    return true
  }

  function sync() {
    const next = root.liveShot
    if (!root.sameWindows(root.shot, next)) root.shot = next
    // And a fresh frame of each, now: the one they kept is from last time.
    root.beat++
    root.workspaces = root.liveWorkspaces
    root.plans = root.livePlans
    if (root.stageId <= 0 && Hyprland.focusedWorkspace) root.stageId = Hyprland.focusedWorkspace.id

    // Start on the window you were already using, so pressing enter straight
    // away puts you back rather than nowhere.
    if (root.selectedKey === "") {
      const active = root.shot.find(w => root.geo[w.key] && root.geo[w.key].active)
      if (active) root.selectedKey = active.key
    }
  }

  function forget() {
    // Not the snapshot: the cards stay, ready for next time.
    root.workspaces = []
    root.plans = ({})
    root.selectedKey = ""
    root.dragKey = ""
    root.dragTarget = -1
    root.dropOnKey = ""
    root.filter = ""
    root.peek = -1
    root.peekWanted = -1
    slider.stop()
    slider.value = 0
    slider.velocity = 0
    root.slide = 0
    root.slideGoal = 0
    root.sliding = false
    root.sideOwned = false
    root.stageId = -1
  }

  Connections {
    target: root.service
    function onArming() { root.sync() }
  }

  onOpenedChanged: if (!root.opened) {
    revealing.stop()
    root.reveal = 0
    root.forget()
  }

  // A window that has just been sent elsewhere or closed should leave the
  // spread, but only once the compositor has confirmed it.
  Timer {
    id: resettle
    interval: 220
    onTriggered: if (root.opened) root.sync()
  }

  // ------------------------------------------------------------- what you did

  // The window the keyboard is on. The pointer sets it too, so the ring never
  // has to be in two places at once.
  property string selectedKey: ""
  property string dragKey: ""
  property int dragTarget: -1
  property string dropOnKey: ""
  property string filter: ""
  property int peek: -1
  property int peekWanted: -1

  // The surface you are working on, which is the one that answers questions
  // about where things are.
  property var leadSurface: null

  function aimDrag(workspaceId, cardKey) {
    root.dragTarget = workspaceId
    // A workspace under the pointer wins: it is the larger, deliberate target.
    root.dropOnKey = workspaceId > 0 ? "" : cardKey
  }

  /** Hovering a workspace shows you what is on it, without going there. */
  function hoverWorkspace(id, entered) {
    const here = root.stageWorkspace
    if (entered) {
      if (id === here || root.moving) return
      root.peekWanted = id
      peeking.restart()
    } else if (root.peekWanted === id) {
      peeking.stop()
      root.peekWanted = -1
      root.peek = -1
    }
  }

  // Long enough that crossing the strip on the way somewhere does not flick
  // through every desktop you pass, and no longer. It used to be 320ms, from
  // when a peek tore down every card and rebuilt it: the wait hid the rebuild.
  // The cards survive a peek now, so the only thing left to cover is the
  // pointer passing over a tile it was never aiming at.
  Timer {
    id: peeking
    interval: 130
    onTriggered: root.peek = root.peekWanted
  }

  // ------------------------------------------------------ sliding sideways

  // Three fingers left or right with the overview open slides the whole spread
  // over to the next workspace, and the one after it comes in from the side —
  // following the fingers, so stopping half way shows half of each, and
  // letting go there goes back. The strip's ring slides with it.
  //
  // Nothing is rebuilt to do this. Every workspace's cards already exist and
  // are already laid out in the same area (that is what makes peeking a
  // cross-fade); sliding only moves each one sideways by how many workspaces
  // it is away from the middle of the screen.

  // The workspace the spread is centred on. Set when the overview opens and
  // moved by sliding, rather than read from the compositor, because the
  // compositor only hears about a switch after the slide has shown it.
  property int stageId: -1
  readonly property int stageWorkspace: root.stageId > 0 ? root.stageId
                                      : (Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1)

  // The workspaces you can slide through: the strip, less the "+" at its end.
  //
  // Only this screen's, as Hyprland's own swipe does: the ones already on it,
  // and the ones that do not exist yet (switching to one makes it here). A
  // workspace on the other screen is not the next desktop here — going to it
  // moves focus to that screen, and the slide on this one snaps back.
  readonly property var lanes: root.workspaces
    .filter(w => !w.fresh && (w.monitor === "" || w.monitor === root.leadMonitor))
    .map(w => w.id)

  /** Where the strip's ring sits for a position along `lanes`, which can fall
      between two tiles that are not next to each other in the strip. */
  function laneTile(position) {
    const count = root.lanes.length
    if (count === 0) return 0
    const tileOf = id => Math.max(0, root.workspaces.findIndex(w => w.id === id))
    if (count === 1) return tileOf(root.lanes[0])
    const i = Math.max(0, Math.min(count - 2, Math.floor(position)))
    const from = tileOf(root.lanes[i])
    const to = tileOf(root.lanes[i + 1])
    return from + (to - from) * (position - i)
  }
  readonly property int stageIndex: root.lanes.indexOf(root.stageWorkspace)

  // How far through the slide, in workspaces: 0.3 is a third of the way to the
  // next one, -1 is all the way to the previous.
  property real slide: 0
  // Fingers down on a slide.
  property bool sliding: false
  // Sliding or settling: the cards must follow `slide` exactly rather than
  // animate toward it.
  readonly property bool moving: root.sliding || slider.running
  // Whether the swipe in progress is one this overview took on.
  property bool sideOwned: false
  property real slideFrom: 0

  /** Where a workspace's spread sits, in screen widths from the middle. */
  function laneOf(workspaceId) {
    const index = root.lanes.indexOf(workspaceId)
    if (index < 0 || root.stageIndex < 0) return 99
    return index - (root.stageIndex + root.shownSlide)
  }

  // Where the slide is drawn: held at nothing until the overview can appear,
  // then let catch up, for the same reason as `t` — on the desktop the fingers
  // are already a fair way across by the time every capture is in.
  readonly property real shownSlide: root.slide * root.reveal

  // Sliding is for the one-desktop spread. Every window at once, or a search
  // across every desktop, has nothing to slide between.
  readonly property bool canSlide: (root.active || root.deskSliding) && !root.everything && root.filter === ""
                                   && root.dragKey === "" && root.stageIndex >= 0
  // Sliding on the bare desktop, the overview up at no zoom just for it.
  readonly property bool deskSliding: root.service ? root.service.deskSlide : false

  // The desktop slide is over, landed or sprung back: put the overview away,
  // which hands the screen back to the real windows exactly where the cards
  // stand.
  function endDeskSlide() {
    if (!root.service || !root.service.deskSlide) return
    // Not until the compositor is on the desktop the slide landed on, or for a
    // frame the old one shows through as the overview goes.
    const here = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    if (root.stageId > 0 && here !== root.stageId) {
      switchWait.restart()
      return
    }
    switchWait.stop()
    root.service.deskSlide = false
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() { if (switchWait.running) root.endDeskSlide() }
  }

  // However long the compositor takes, not longer than this.
  Timer {
    id: switchWait
    interval: 250
    onTriggered: if (root.service) root.service.deskSlide = false
  }

  // Past the first or last workspace, and past one workspace per swipe, it
  // gives a little and no more, the way a scroll view does at its ends.
  // The same stretch as swiping up past open: one-to-one at first, then less
  // and less, springing back when the fingers lift.
  readonly property real give: 0.3
  function stretched(over) { return root.give * (1 - 1 / (1 + over / root.give)) }
  function bounded(value) {
    const low = Math.max(-1, -root.stageIndex)
    const high = Math.min(1, root.lanes.length - 1 - root.stageIndex)
    if (value > high) return high + root.stretched(value - high)
    if (value < low) return low - root.stretched(low - value)
    return value
  }

  Connections {
    target: root.service
    function onSideSwipe(phase, value, velocity, cancelled) { root.onSide(phase, value, velocity, cancelled) }
    function onStepRequested(step) {
      if (!root.canSlide) {
        root.endDeskSlide()
        return
      }
      root.slideBy(step)
      // Nowhere to go that way: nothing moved, so nothing will land.
      if (!root.moving) root.endDeskSlide()
    }
  }

  function onSide(phase, value, velocity, cancelled) {
    switch (phase) {
    case "begin":
      root.sideOwned = root.canSlide
      if (!root.sideOwned) {
        root.endDeskSlide()
        return
      }
      // Caught mid-settle: finish that slide where it was heading first, so
      // this one starts from a whole workspace.
      if (slider.running) {
        slider.stop()
        root.finishSlide(slider.target)
      }
      peeking.stop()
      root.peek = -1
      root.peekWanted = -1
      root.slideFrom = root.slide
      root.slideGoal = root.slide
      root.slideSpeed = 0
      root.slideAt = 0
      slider.hold()
      slider.value = root.slide
      slider.velocity = 0
      root.sliding = true
      sideWatchdog.restart()
      break

    case "move":
      if (!root.sideOwned) return
      root.slideGoal = root.bounded(root.slideFrom + value)
      slider.value = root.slideGoal
      {
        const now = Date.now()
        const dt = (now - root.slideAt) / 1000
        root.slideSpeed = root.slideAt > 0 && dt > 0 && dt < 0.1
          ? root.slideSpeed * 0.6 + 0.4 * (root.slideGoal - root.slideLast) / dt : 0
        root.slideLast = root.slideGoal
        root.slideAt = now
      }
      sideWatchdog.restart()
      break

    case "end":
      if (!root.sideOwned) return
      root.sideOwned = false
      sideWatchdog.stop()
      // The speed the spread had on screen as the fingers lifted, the same
      // as swiping up: none if they had come to rest first.
      //
      // Or the gesture's own measure, if that is faster: it is taken over the
      // last 90ms, where the on-screen speed is smoothed from zero, which on a
      // swipe only a few events long reads a real flick as a slow drag.
      {
        const resting = Date.now() - root.slideAt > 80
        const seen = resting ? 0 : root.slideSpeed
        const measured = resting ? 0 : velocity
        root.releaseSlide(cancelled ? 0 : (Math.abs(measured) > Math.abs(seen) ? measured : seen), cancelled)
      }
      break
    }
  }

  // Past half way it goes on; short of it, a flick in the same direction
  // still does. A flick back the other way always wins.
  // In workspaces per second, so it scales with how far a workspace is.
  readonly property real slideFlick: 1.2
  // Where the fingers have put the slide, and how fast it was moving on
  // screen, in workspaces per second.
  property real slideGoal: 0
  property real slideSpeed: 0
  property real slideLast: 0
  property double slideAt: 0

  function releaseSlide(velocity, cancelled) {
    const at = root.slideGoal
    let to = 0
    if (!cancelled) {
      const dir = at !== 0 ? Math.sign(at) : Math.sign(velocity)
      const flung = Math.abs(velocity) > root.slideFlick
      if (flung && Math.sign(velocity) !== dir) to = 0
      else if (Math.abs(at) > 0.5 || (flung && Math.abs(at) > 0.03)) to = dir
    }
    const next = root.stageIndex + to
    if (next < 0 || next >= root.lanes.length) to = 0


    // Let go, the spring loosens and lands with a bounce, keeping the speed
    // it had — topped up by a flick faster than it had caught up to.
    root.slideGoal = to
    if (!slider.running) slider.value = root.slide
    slider.stiffness = 18
    slider.damping = 0.9
    slider.velocity = Math.max(-6, Math.min(6, velocity))
    // Running before the fingers are let go of, so the cards never see a
    // frame where neither is moving them.
    slider.follow(to)
    root.sliding = false
  }

  /** Slide one workspace over from the keyboard. */
  function slideBy(step) {
    if (!root.canSlide || root.sliding) return
    if (slider.running) {
      slider.stop()
      root.finishSlide(slider.target)
    }
    root.peek = -1
    root.slideFrom = 0
    // As if the fingers had carried it just past half way: the spring still
    // starts from where the spread is, and does the whole trip itself.
    root.slideGoal = step * 0.51
    root.releaseSlide(step * 4, false)
  }

  // Landed: the neighbour is now the middle. Moving the stage and zeroing the
  // slide leaves every card exactly where it already was.
  function finishSlide(to) {
    if (to !== 0) {
      const next = root.lanes[root.stageIndex + to]
      if (next !== undefined) {
        // Only now, with the slide landed and the overview covering all of
        // it. Told at the lift, the compositor switched at once — and on a
        // short swipe the overview was not up yet, so the desktop simply
        // vanished before the slide it was meant to be hidden behind.
        Hyprland.dispatch('hl.dsp.focus({ workspace = "' + next + '" })')
        root.stageId = next
        // The selection moves to the desktop you are looking at, so enter
        // goes somewhere on it.
        const active = root.shot.find(w => w.workspace === next && w.active)
                    || root.shot.find(w => w.workspace === next)
        root.selectedKey = active ? active.key : ""
      }
    }
    root.slide = 0
  }

  Spring {
    id: slider
    onValueChanged: root.slide = slider.value
    // Fingers resting mid-slide let the spring settle too; that is not a
    // landing.
    onSettled: if (!root.sliding) {
      root.finishSlide(slider.target)
      root.endDeskSlide()
    }
  }

  // A lift that never arrives must not leave the spread half way between two
  // desktops.
  Timer {
    id: sideWatchdog
    interval: 1400
    onTriggered: if (root.sliding) {
      root.sideOwned = false
      root.releaseSlide(0, false)
    }
  }

  function matches(win) {
    if (root.filter === "") return true
    const needle = root.filter.toLowerCase()
    return String(win.title || "").toLowerCase().indexOf(needle) >= 0
        || String(win.appId || "").toLowerCase().indexOf(needle) >= 0
  }

  /** The icon an app id resolves to, or "". */
  function iconFor(appId) {
    if (!appId) return ""
    const entry = DesktopEntries.heuristicLookup(appId)
    const name = entry && entry.icon ? entry.icon : appId
    return Quickshell.iconPath(name, true) || ""
  }

  // ------------------------------------------------------------ acting on it

  function dismiss() { if (root.service) root.service.hide() }

  function focusWindow(address) {
    if (!address) return
    Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + address + '" })')
    root.dismiss()
  }

  function goToWorkspace(id) {
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })')
    root.dismiss()
  }

  function closeWindow(address) {
    if (!address) return
    Hyprland.dispatch('hl.dsp.window.close({ window = "address:0x' + address + '" })')
    if (root.selectedKey === address) root.selectedKey = ""
    if (root.service) root.service.refreshModels()
    resettle.restart()
  }

  function drop(address) {
    const space = root.dragTarget
    const onto = root.dropOnKey
    root.dragTarget = -1
    root.dropOnKey = ""
    if (!address) return

    const here = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    if (space > 0 && space !== here) {
      Hyprland.dispatch('hl.dsp.window.move({ window = "address:0x' + address
                        + '", workspace = "' + space + '" })')
    } else if (onto && onto !== address) {
      // Dropped on another window: they trade places in the tiling layout.
      Hyprland.dispatch('hl.dsp.window.swap({ window = "address:0x' + address
                        + '", target = "address:0x' + onto + '" })')
    } else {
      return
    }
    // The overview stays open, the way it does on a Mac: you are usually
    // moving more than one thing.
    if (root.service) root.service.refreshModels()
    resettle.restart()
  }

  function moveSelection(dx, dy) {
    const surface = root.leadSurface
    if (!surface) return
    const placed = []
    for (const win of surface.shownWindows) {
      const slot = surface.slots[win.key]
      if (slot) placed.push({ key: win.key, x: slot.x, y: slot.y, w: slot.w, h: slot.h })
    }
    const next = Layout.nextIn(placed, root.selectedKey, dx, dy)
    if (next) root.selectedKey = next
  }

  /** What enter acts on: the selection, as long as the filter leaves it
      standing, and otherwise the first window that it does.

      The selection is seeded with the window you were already using, so that
      enter straight away puts you back. Typing has to move it: a selection left
      behind on a window the filter has hidden is invisible, and enter on an
      invisible selection re-focuses the window you started from -- which is
      what "type a name, press enter" used to do, silently, whenever the window
      you were looking for was on another desktop. */
  function enterTarget() {
    const surface = root.leadSurface
    if (!surface) return root.selectedKey
    const shown = surface.shownWindows
    if (!shown.length) return ""            // nothing matches: enter has nothing to act on
    if (root.selectedKey && shown.some(w => w.key === root.selectedKey)) return root.selectedKey
    return shown[0].key
  }

  // Typing moves the selection with it, so what enter will do is also what you
  // can see highlighted, rather than something decided off-screen.
  onFilterChanged: {
    const target = root.enterTarget()
    if (target) root.selectedKey = target
  }

  function onKey(event) {
    const plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))

    switch (event.key) {
    case Qt.Key_Escape:
      // Clear what you typed first; the second press puts the overview away.
      if (root.filter !== "") root.filter = ""
      else root.dismiss()
      break
    case Qt.Key_Backspace:
      root.filter = root.filter.slice(0, -1)
      break
    case Qt.Key_Left:
      if (event.modifiers & Qt.ControlModifier) root.slideBy(-1)
      else root.moveSelection(-1, 0)
      break
    case Qt.Key_Right:
      if (event.modifiers & Qt.ControlModifier) root.slideBy(1)
      else root.moveSelection(1, 0)
      break
    case Qt.Key_Up:
      root.moveSelection(0, -1)
      break
    case Qt.Key_Down:
      root.moveSelection(0, 1)
      break
    case Qt.Key_Return:
    case Qt.Key_Enter:
      // Typing until one window is left and pressing enter is the fastest way
      // through here, so that case does not need aiming first.
      root.focusWindow(root.enterTarget())
      break
    case Qt.Key_W:
      if (event.modifiers & Qt.ControlModifier) root.closeWindow(root.selectedKey)
      else if (plain && event.text) root.filter += event.text
      else return
      break
    case Qt.Key_Q:
      if (event.modifiers & Qt.ControlModifier) root.dismiss()
      else if (plain && event.text) root.filter += event.text
      else return
      break
    default:
      // Anything else you can type narrows the spread.
      if (plain && event.text && event.text.length === 1 && event.text >= " ") {
        root.filter += event.text
      } else {
        return
      }
    }
    event.accepted = true
  }

  // One overview per screen. A second monitor that merely dimmed while you look
  // for a window on it would be worse than not covering it at all.
  Variants {
    model: Quickshell.screens

    delegate: Surface {
      required property var modelData
      overlay: root
      screenInfo: modelData
      onLeadingChanged: if (leading) root.leadSurface = this
      Component.onCompleted: if (leading) root.leadSurface = this
    }
  }
}
