import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Commons
import "../app/Layout.js" as Layout

// One screen's worth of overview.
//
// Every monitor gets one of these, each spreading its own workspace's windows,
// because a second screen that merely dims while you are looking for a window
// on it is worse than no overview at all. The workspace strip belongs to the
// screen you were pointing at; the others are just their own windows.
PanelWindow {
  id: surface

  required property var overlay
  required property var screenInfo

  screen: surface.screenInfo
  visible: overlay.opened
  color: "transparent"
  WlrLayershell.namespace: "omarchy-aerial"
  WlrLayershell.layer: WlrLayer.Overlay
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }

  // Only the screen you swiped on grabs the keyboard; two surfaces both
  // claiming it exclusively is a fight nobody wins. And only once the overview
  // is actually open — a swipe still in progress must not take keys from the
  // window underneath.
  WlrLayershell.keyboardFocus: surface.leading && overlay.active
                               ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // A swipe in progress should not swallow clicks meant for the desktop.
  mask: overlay.active ? null : emptyRegion
  Region { id: emptyRegion }

  readonly property string monitorName: surface.screenInfo ? surface.screenInfo.name : ""
  readonly property var monitor: (Hyprland.monitors.values || []).find(m => m.name === surface.monitorName) || null
  readonly property bool leading: surface.monitorName === overlay.leadMonitor

  // Which workspace this screen is showing. Peeking at a tile swaps it without
  // going there.
  readonly property int shownWorkspace: {
    if (surface.leading && overlay.peek > 0) return overlay.peek
    return surface.monitor && surface.monitor.activeWorkspace ? surface.monitor.activeWorkspace.id : -1
  }

  readonly property var windows: {
    const out = []
    for (const win of overlay.shot) {
      if (win.monitor !== surface.monitorName) continue
      if (!overlay.everything && win.workspace !== surface.shownWorkspace) continue
      out.push(win)
    }
    return out
  }

  // What the filter leaves standing. The card for a window that does not match
  // stays alive but steps out of the spread, so typing does not tear down and
  // rebuild a live capture on every keystroke.
  readonly property var shownWindows: surface.windows.filter(w => overlay.matches(w))

  // Room for the workspace strip along the top, the way Mission Control does.
  readonly property real stripHeight: surface.leading ? Math.max(96, surface.height * 0.15) : 24
  readonly property real padding: 32

  // The strip is laid out from these and hit-tested from these, so a dragged
  // window lands on the tile it looks like it is over.
  readonly property real tileWidth: Math.max(96, surface.height * 0.15) * 0.92
  readonly property real tileHeight: surface.tileWidth * (surface.height / Math.max(1, surface.width))
  readonly property real tileGap: 16
  readonly property real tileTop: (surface.stripHeight - surface.tileHeight) / 2
  readonly property real tileLeft: {
    const count = overlay.workspaces.length
    const total = count * surface.tileWidth + Math.max(0, count - 1) * surface.tileGap
    return (surface.width - total) / 2
  }

  function tileX(index) { return surface.tileLeft + index * (surface.tileWidth + surface.tileGap) }

  /** Which workspace is under this point, or -1. Generous by a few pixels: a
   *  drop that looks like it is on a tile should count as one. */
  function workspaceAtPoint(px, py) {
    if (!surface.leading) return -1
    const slack = 10
    if (py < surface.tileTop - slack || py > surface.tileTop + surface.tileHeight + slack) return -1
    for (let i = 0; i < overlay.workspaces.length; i++) {
      const left = surface.tileX(i)
      if (px >= left - slack && px <= left + surface.tileWidth + slack) return overlay.workspaces[i].id
    }
    return -1
  }

  /** Which window's card is under this point, ignoring the one being dragged. */
  function cardAtPoint(px, py) {
    for (const win of surface.shownWindows) {
      const slot = surface.slots[win.key]
      if (!slot || win.key === overlay.dragKey) continue
      if (px >= slot.x && px <= slot.x + slot.w && py >= slot.y && py <= slot.y + slot.h) return win.key
    }
    return ""
  }

  readonly property var slots: {
    if (surface.shownWindows.length === 0 || surface.width <= 0) return ({})
    const area = {
      width: surface.width - surface.padding * 2,
      height: surface.height - surface.stripHeight - surface.padding * 2,
    }
    const options = { gap: 26, rowGap: 62, maxScale: 0.78 }

    const byKey = ({})

    if (!overlay.everything) {
      for (const slot of Layout.spread(surface.shownWindows, area, options)) {
        byKey[slot.key] = {
          x: slot.x + surface.padding,
          y: slot.y + surface.stripHeight + surface.padding,
          w: slot.w,
          h: slot.h,
        }
      }
      return byKey
    }

    // Every window on this screen, kept in its workspace's own column so the
    // answer to "where is it" is still "on that desktop".
    const groups = Layout.groupBy(surface.shownWindows, w => w.workspace)
    for (const column of Layout.columns(groups, area, options)) {
      for (const slot of column.slots) {
        byKey[slot.key] = {
          x: slot.x + column.x + surface.padding,
          y: slot.y + surface.stripHeight + surface.padding + Layout.LABEL_SPACE,
          w: slot.w,
          h: slot.h,
        }
      }
    }
    return byKey
  }

  readonly property var columnLabels: {
    if (!overlay.everything || surface.shownWindows.length === 0 || surface.width <= 0) return []
    const area = {
      width: surface.width - surface.padding * 2,
      height: surface.height - surface.stripHeight - surface.padding * 2,
    }
    const groups = Layout.groupBy(surface.shownWindows, w => w.workspace)
    return Layout.columns(groups, area, { gap: 26, rowGap: 62, maxScale: 0.78 }).map(column => ({
      key: column.key,
      x: column.x + surface.padding,
      width: column.width,
    }))
  }

  Item {
    id: stage
    anchors.fill: parent
    focus: surface.leading

    Keys.onPressed: function (event) { if (surface.leading) overlay.onKey(event) }

    // The desktop goes away: the windows you are about to see spread out are
    // still sitting there underneath, and two of everything reads as a mess.
    // What replaces them is the wallpaper they were covering, softened — loaded
    // small and drawn large, which is a blur that costs nothing per frame,
    // unlike asking the compositor for one.
    Image {
      anchors.fill: parent
      source: overlay.wallpaperUrl
      visible: overlay.wallpaper !== ""
      opacity: overlay.veil
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: 320
      smooth: true
      asynchronous: true
      cache: true
    }

    Rectangle {
      anchors.fill: parent
      color: "#07070A"
      opacity: (overlay.wallpaper === "" ? 0.93 : 0.74) * overlay.veil
    }

    MouseArea {
      anchors.fill: parent
      onClicked: overlay.dismiss()
    }

    // ------------------------------------------------------------ the strip
    Item {
      id: strip
      width: parent.width
      height: surface.stripHeight
      y: -height * (1 - overlay.veil)
      opacity: overlay.veil
      visible: surface.leading

      Repeater {
        model: surface.leading ? overlay.workspaces : []

        delegate: Item {
          id: space
          required property var modelData
          required property int index
          readonly property bool focused: space.modelData.focused
          readonly property bool targeted: overlay.dragTarget === space.modelData.id
          readonly property bool peeked: overlay.peek === space.modelData.id
          readonly property var plan: overlay.plans[space.modelData.id] || []

          x: surface.tileX(space.index)
          y: surface.tileTop
          width: surface.tileWidth
          height: surface.tileHeight

          scale: space.targeted ? 1.12 : (space.peeked ? 1.06 : 1)
          Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

          ClippingRectangle {
            id: tile
            anchors.fill: parent
            radius: 8
            color: "#0B0B0E"

            // Each desktop is a small picture of the desktop: the same
            // wallpaper, with a block where each window sits.
            Image {
              anchors.fill: parent
              source: overlay.wallpaperUrl
              visible: overlay.wallpaper !== ""
              fillMode: Image.PreserveAspectCrop
              sourceSize.width: 200
              smooth: true
              asynchronous: true
              cache: true
              opacity: space.focused || space.peeked ? 0.85 : 0.5
            }

            Rectangle {
              anchors.fill: parent
              color: space.targeted ? Qt.rgba(1, 1, 1, 0.16) : "transparent"
            }

            Repeater {
              model: space.plan

              delegate: Rectangle {
                id: mini
                required property var modelData
                x: mini.modelData.x * tile.width
                y: mini.modelData.y * tile.height
                width: Math.max(3, mini.modelData.w * tile.width)
                height: Math.max(3, mini.modelData.h * tile.height)
                radius: 3
                // Dark enough to read as a window against any wallpaper, rather
                // than a grey square that could be anything.
                color: mini.modelData.active ? Qt.rgba(0.10, 0.10, 0.13, 0.94)
                                             : Qt.rgba(0.07, 0.07, 0.09, 0.84)
                border.width: 1
                border.color: mini.modelData.active ? Qt.rgba(1, 1, 1, 0.34)
                                                    : Qt.rgba(1, 1, 1, 0.16)

                IconImage {
                  anchors.centerIn: parent
                  implicitSize: Math.round(Math.min(18, Math.min(mini.width, mini.height) * 0.62))
                  source: overlay.iconFor(mini.modelData.appId)
                  visible: source !== "" && mini.width > 16 && mini.height > 14
                  opacity: space.focused || space.peeked ? 0.95 : 0.7
                }
              }
            }

            // An untouched workspace says so, instead of looking broken — and
            // the one past the end offers itself.
            Text {
              anchors.centerIn: parent
              visible: space.plan.length === 0
              text: space.modelData.fresh ? "\u002b" : "empty"
              color: Qt.rgba(1, 1, 1, space.modelData.fresh ? 0.5 : 0.34)
              font.family: Style.font.family
              font.pixelSize: space.modelData.fresh
                              ? Math.round(Style.font.body * 1.6) : Style.font.caption
            }
          }

          Rectangle {
            anchors.fill: parent
            radius: tile.radius
            color: "transparent"
            border.width: space.targeted || space.focused || space.peeked ? 2 : 1
            border.color: space.targeted ? "#F2EFE7"
                        : space.focused ? Color.accent
                        : space.peeked ? Qt.rgba(1, 1, 1, 0.5)
                        : Qt.rgba(1, 1, 1, 0.14)
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.bottom
            anchors.topMargin: 6
            text: space.modelData.name
            color: space.focused ? "#F2EFE7" : "#8D8880"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.weight: space.focused ? Font.DemiBold : Font.Normal
          }

          HoverHandler {
            enabled: overlay.active && !overlay.everything
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: overlay.hoverWorkspace(space.modelData.id, hovered)
          }

          TapHandler {
            enabled: overlay.active
            onTapped: overlay.goToWorkspace(space.modelData.id)
          }
        }
      }
    }

    // ------------------------------------------------------- column labels
    Repeater {
      model: surface.columnLabels

      delegate: Text {
        required property var modelData
        x: modelData.x
        y: surface.stripHeight + surface.padding
        width: modelData.width
        horizontalAlignment: Text.AlignHCenter
        text: modelData.key
        color: Qt.rgba(1, 1, 1, 0.45)
        opacity: overlay.veil
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.weight: Font.DemiBold
      }
    }

    // ------------------------------------------------------------ the windows
    Repeater {
      model: surface.windows

      delegate: Item {
        id: card
        required property var modelData
        readonly property var slot: surface.slots[card.modelData.key] || null
        readonly property bool shown: overlay.matches(card.modelData)
        readonly property bool hovered: hover.hovered && overlay.active
        readonly property bool picked: card.hovered || overlay.selectedKey === card.modelData.key
        readonly property bool dragging: dragger.active
        readonly property bool landing: overlay.dropOnKey === card.modelData.key
        // Resolved once per card rather than per frame: a desktop-entry search
        // is a directory walk.
        readonly property string icon: overlay.iconFor(card.modelData.appId)

        // The whole animation: where it is, blended with where it goes — plus
        // however far it has been dragged since it was picked up.
        x: (card.slot ? card.modelData.x + (card.slot.x - card.modelData.x) * overlay.t : card.modelData.x)
           + (card.dragging ? dragger.activeTranslation.x : 0)
        y: (card.slot ? card.modelData.y + (card.slot.y - card.modelData.y) * overlay.t : card.modelData.y)
           + (card.dragging ? dragger.activeTranslation.y : 0)
        width: card.slot ? card.modelData.w + (card.slot.w - card.modelData.w) * overlay.t : card.modelData.w
        height: card.slot ? card.modelData.h + (card.slot.h - card.modelData.h) * overlay.t : card.modelData.h

        Behavior on x { enabled: overlay.active && !card.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: overlay.active && !card.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on width { enabled: overlay.active && !card.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on height { enabled: overlay.active && !card.dragging; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        z: card.dragging ? 3 : (card.picked ? 2 : 1)
        // Held, it shrinks the way a thing you have picked up does — and
        // shrinks further over somewhere it would land, so it stops covering
        // what it is about to drop into.
        scale: card.dragging ? (overlay.dragTarget > 0 || overlay.dropOnKey !== "" ? 0.4 : 0.82)
             : (card.picked ? 1.035 : 1)
        opacity: card.shown ? (card.dragging ? 0.94 : 1) : 0
        visible: card.opacity > 0.01
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 150 } }

        readonly property real radius: 14 * overlay.veil

        ClippingRectangle {
          id: frame
          anchors.fill: parent
          radius: card.radius
          // Under the capture, so a window whose first frame has not arrived
          // yet reads as a tile and not as a hole.
          color: "#101014"

          ScreencopyView {
            id: shot
            anchors.fill: parent
            captureSource: card.modelData.capture
            // Never live, not even for the window under the pointer. A live
            // capture is a texture that changes every frame, and one of those
            // makes the compositor redraw this whole surface sixty times a
            // second — the wallpaper, every tile, every icon — which cost more
            // than all eight captures put together. On the clock instead, they
            // still read as alive and the surface redraws a dozen times a
            // second rather than sixty.
            live: false
          }

          Connections {
            target: overlay
            function onBeatChanged() { shot.captureFrame() }
          }
        }

        // Hairline at rest, accent ring under the pointer, bright ring for a
        // window something is about to be dropped onto.
        Rectangle {
          anchors.fill: parent
          radius: card.radius
          color: "transparent"
          border.width: card.landing ? 3 : (card.picked ? 3 : 1)
          border.color: card.landing ? "#F2EFE7" : (card.picked ? Color.accent : Qt.rgba(1, 1, 1, 0.14))
          opacity: overlay.veil
        }

        HoverHandler {
          id: hover
          enabled: overlay.active && card.shown
          cursorShape: card.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
          onHoveredChanged: if (hover.hovered) overlay.selectedKey = card.modelData.key
        }

        TapHandler {
          enabled: overlay.active && card.shown
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton
          onTapped: function (point, button) {
            if (button === Qt.MiddleButton) overlay.closeWindow(card.modelData.key)
            else overlay.focusWindow(card.modelData.key)
          }
        }

        // Pick a window up: drop it on a workspace to send it there, or on
        // another window to trade places with it.
        DragHandler {
          id: dragger
          enabled: overlay.active && card.shown
          target: null

          onActiveChanged: {
            if (dragger.active) {
              overlay.dragKey = card.modelData.key
              overlay.selectedKey = card.modelData.key
            } else {
              overlay.drop(card.modelData.key)
              overlay.dragKey = ""
            }
          }

          onCentroidChanged: {
            if (!dragger.active) return
            const at = dragger.centroid.scenePosition
            overlay.aimDrag(surface.workspaceAtPoint(at.x, at.y), surface.cardAtPoint(at.x, at.y))
          }
        }

        // Close it from here, rather than going there to close it.
        Rectangle {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 8
          width: 26
          height: 26
          radius: 13
          color: shut.hovered ? "#D2604F" : Qt.rgba(0, 0, 0, 0.62)
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.22)
          visible: overlay.active && card.picked && !card.dragging
          opacity: visible ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 110 } }

          Text {
            anchors.centerIn: parent
            text: "×"
            color: "#F4F1E9"
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 1.1)
          }

          HoverHandler { id: shut }

          TapHandler {
            onTapped: overlay.closeWindow(card.modelData.key)
          }
        }

        // The name of the window, under it, the way a caption sits under a
        // photograph — with the app's own icon, because at thumbnail size the
        // icon is what you recognise before you have read anything.
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.bottom
          anchors.topMargin: 10
          width: Math.min(caption.implicitWidth + 20, parent.width)
          height: caption.implicitHeight + 10
          radius: height / 2
          color: card.picked ? Qt.rgba(0, 0, 0, 0.78) : Qt.rgba(0, 0, 0, 0.5)
          opacity: overlay.active ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 120 } }

          Row {
            id: caption
            anchors.centerIn: parent
            spacing: 7

            IconImage {
              anchors.verticalCenter: parent.verticalCenter
              implicitSize: Math.round(Style.font.caption * 1.35)
              source: card.icon
              visible: card.icon !== ""
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, card.width - 40)
              text: card.modelData.title
              elide: Text.ElideRight
              color: card.picked ? "#F7F4EC" : "#C9C3B9"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // ----------------------------------------------------------- the filter
    // Only ever on the screen you are typing at, and only once you have typed.
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      y: surface.stripHeight + 14
      visible: surface.leading && overlay.filter !== ""
      width: query.implicitWidth + 34
      height: query.implicitHeight + 20
      radius: height / 2
      color: Qt.rgba(0, 0, 0, 0.72)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.16)
      opacity: overlay.veil

      Text {
        id: query
        anchors.centerIn: parent
        text: overlay.filter + "   " + surface.shownWindows.length
              + (surface.shownWindows.length === 1 ? " window" : " windows")
        color: surface.shownWindows.length === 0 ? "#D2604F" : "#F2EFE7"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }
}
