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
  readonly property real t: root.service ? root.service.t : 0
  readonly property bool active: root.service ? root.service.open : false
  readonly property bool everything: root.service ? root.service.everything : false
  readonly property string leadMonitor: root.service ? root.service.monitorName : ""

  // The real windows stay mapped underneath, so the veil is what hides them. It
  // ramps faster than `t`: by the time a thumbnail has visibly moved off its
  // window, the window it came from is already gone.
  readonly property real veil: Math.pow(Math.min(1, Math.max(0, root.t)), 0.65)

  readonly property string wallpaper: root.service ? root.service.wallpaper : ""
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
        active: top.activated === true,
        // Hyprland reports global coordinates; a surface covers one monitor.
        x: rect.x - mon.x,
        y: rect.y - mon.y,
        w: rect.w,
        h: rect.h,
      })
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
        active: top.activated === true,
      })
    }
    return out
  }

  // What the overview is drawing: the snapshot, never the live models.
  property var shot: []
  property var workspaces: []
  property var plans: ({})

  function sync() {
    root.shot = root.liveShot
    root.workspaces = root.liveWorkspaces
    root.plans = root.livePlans

    // Start on the window you were already using, so pressing enter straight
    // away puts you back rather than nowhere.
    if (root.selectedKey === "") {
      const active = root.shot.find(w => w.active)
      if (active) root.selectedKey = active.key
    }
  }

  function forget() {
    root.shot = []
    root.workspaces = []
    root.plans = ({})
    root.selectedKey = ""
    root.dragKey = ""
    root.dragTarget = -1
    root.dropOnKey = ""
    root.filter = ""
    root.peek = -1
    root.peekWanted = -1
  }

  Connections {
    target: root.service
    function onArming() { root.sync() }
  }

  onOpenedChanged: if (!root.opened) root.forget()

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
    const here = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    if (entered) {
      if (id === here) return
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
      root.moveSelection(-1, 0)
      break
    case Qt.Key_Right:
      root.moveSelection(1, 0)
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
