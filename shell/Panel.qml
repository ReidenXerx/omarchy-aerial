import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../app/Shortcuts.js" as Shortcuts

// Aerial's settings, from a button on the bar.
//
// Two switches that take effect at once — frosted glass, and swiping between
// desktops — and Aerial's keyboard shortcuts, which are Hyprland bindings and
// so live in the user's Omarchy bindings file, in a section of their own (see
// app/Shortcuts.js). Shortcuts are edited here and only written on Save.
Panel {
  id: root
  moduleName: "reidenxerx.aerial"
  ipcTarget: "reidenxerx.aerial.settings"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var service: root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
                                 ? root.bar.shell.serviceFor("reidenxerx.aerial") : null

  // ------------------------------------------------------------- switches

  readonly property bool frost: root.setting("frost", true) !== false
  readonly property bool deskSwipe: root.setting("deskSwipe", true) !== false

  function setSetting(key, value) {
    const next = Object.assign({}, root.settings || {})
    next[key] = value
    root.settings = next
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // The service owns the behaviour; this only tells it what the user chose,
  // whenever either side comes or goes.
  function pushSettings() {
    if (!root.service) return
    root.service.frost = root.frost
    root.service.deskSwipe = root.deskSwipe
  }
  onServiceChanged: root.pushSettings()
  onFrostChanged: root.pushSettings()
  onDeskSwipeChanged: root.pushSettings()

  Timer {
    // The service can load after the bar; look again until it is there.
    interval: 800
    repeat: true
    running: !root.service
    onTriggered: {
      const found = root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
                    ? root.bar.shell.serviceFor("reidenxerx.aerial") : null
      if (found) root.pushSettings()
    }
  }

  // ------------------------------------------------------------ shortcuts

  readonly property string bindingsPath: {
    const config = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    const home = String(Quickshell.env("HOME") || "")
    return (config !== "" ? config : home + "/.config") + "/hypr/bindings.lua"
  }

  // What the file says, and what is being edited.
  property var saved: ({})
  property var draft: ({})
  readonly property bool dirty: JSON.stringify(root.draft) !== JSON.stringify(root.saved)
  // The action a key combination is being recorded for, or "".
  property string recordingId: ""
  // Every binding Hyprland has, for spotting clashes.
  property var binds: []
  property string status: ""

  FileView {
    id: bindingsFile
    path: root.bindingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: bindingsFile.reload()
    onLoaded: root.readBindings()
  }

  function readBindings() {
    let text = ""
    try { text = bindingsFile.text() } catch (e) { text = "" }
    const found = Shortcuts.read(text || "")
    const wasClean = !root.dirty
    root.saved = found
    if (wasClean) root.draft = Object.assign({}, found)
  }

  Process {
    id: bindsQuery
    command: ["/usr/bin/hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.binds = JSON.parse(text) } catch (e) { root.binds = [] }
      }
    }
  }

  function refreshBinds() { if (!bindsQuery.running) bindsQuery.running = true }

  /** What else a draft shortcut would collide with: another Aerial action,
      or something already bound in Hyprland. */
  function clashesFor(actionId) {
    const combo = root.draft[actionId]
    if (!combo) return []
    const out = []
    for (const act of Shortcuts.ACTIONS) {
      if (act.id !== actionId && root.draft[act.id] && root.draft[act.id].toLowerCase() === combo.toLowerCase())
        out.push({ description: act.label, ours: true })
    }
    // What Hyprland has on it now — unless that is this very binding, saved.
    if (root.saved[actionId] !== combo) {
      for (const c of Shortcuts.conflicts(root.binds, combo)) out.push({ description: c.description, ours: false })
    }
    return out
  }

  readonly property bool blocked: {
    for (const act of Shortcuts.ACTIONS) {
      if (root.clashesFor(act.id).some(c => c.ours)) return true
    }
    return false
  }

  function startRecording(actionId) {
    root.recordingId = actionId
    root.status = ""
    if (root.service) root.service.setRecording(true)
    recorder.forceActiveFocus()
  }

  function stopRecording() {
    if (root.recordingId === "") return
    root.recordingId = ""
    if (root.service && root.service.recording) root.service.setRecording(false)
    keyCatcher.forceActiveFocus()
  }

  function setDraft(actionId, combo) {
    const next = Object.assign({}, root.draft)
    if (combo) next[actionId] = combo
    else delete next[actionId]
    root.draft = next
  }

  function save() {
    if (root.blocked) return
    let text = ""
    try { text = bindingsFile.text() || "" } catch (e) { text = "" }
    // A combination something else already has is taken over, the way
    // Omarchy's own file says to: unbind, then bind.
    const takeOver = ({})
    for (const act of Shortcuts.ACTIONS) {
      if (root.clashesFor(act.id).some(c => !c.ours)) takeOver[act.id] = true
    }
    bindingsFile.setText(Shortcuts.write(text, root.draft, takeOver))
    root.saved = Object.assign({}, root.draft)
    root.status = "Saved — Hyprland picks it up by itself."
    // Hyprland reloads the file on its own; ask for the bindings again once
    // it has, so the warnings reflect it.
    rebindsLater.restart()
  }

  Timer {
    id: rebindsLater
    interval: 700
    onTriggered: root.refreshBinds()
  }

  function discard() {
    root.stopRecording()
    root.draft = Object.assign({}, root.saved)
    root.status = ""
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refreshBinds()
      bindingsFile.reload()
    } else {
      root.stopRecording()
    }
  }

  // The keyboard came back to Hyprland some other way (Escape does, in the
  // compositor, and the service gives up after a while): stop listening.
  Connections {
    target: root.service
    function onRecordingChanged() { if (!root.service.recording && root.recordingId !== "") root.stopRecording() }
  }

  // ----------------------------------------------------------------- button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰕰"
    tooltipText: "Aerial"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.service) root.service.toggle()
      } else {
        root.toggle()
      }
    }
  }

  // ------------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While recording, every key is the shortcut being recorded.
      blocked: root.recordingId !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Listens for the combination being recorded.
      Item {
        id: recorder
        focus: root.recordingId !== ""
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          event.accepted = true
          if (root.recordingId === "") return
          if (Shortcuts.isModifierKey(event.key)) return   // wait for the key itself
          if (event.key === Qt.Key_Escape && !(event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier))) {
            root.stopRecording()
            return
          }
          const name = Shortcuts.keyName(event.key)
          if (name === "") {
            root.status = "That key cannot be a shortcut."
            return
          }
          const mask = Shortcuts.maskOf(event.modifiers)
          if (mask === 0) {
            root.status = "Hold at least one modifier — Super, Ctrl, Alt or Shift."
            return
          }
          root.setDraft(root.recordingId, Shortcuts.format(mask, name))
          root.status = ""
          root.stopRecording()
        }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- title
        Row {
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: "󰕰"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Aerial"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: "Window overview and desktop swipes"
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground }

        // ---------- switches
        PanelSectionHeader {
          text: "BEHAVIOUR"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Toggle {
          width: parent.width
          label: "Frosted glass"
          description: "Blur behind see-through windows, the way Hyprland does. Uses more GPU."
          checked: root.frost
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.setSetting("frost", !root.frost)
        }

        Toggle {
          width: parent.width
          label: "Swipe between desktops"
          description: "Three fingers sideways on the desktop slide to the next one."
          checked: root.deskSwipe
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.setSetting("deskSwipe", !root.deskSwipe)
        }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground }

        // ---------- shortcuts
        PanelSectionHeader {
          text: "SHORTCUTS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Repeater {
          model: Shortcuts.ACTIONS

          delegate: Column {
            id: row
            required property var modelData
            readonly property string combo: root.draft[row.modelData.id] || ""
            readonly property bool listening: root.recordingId === row.modelData.id
            readonly property var clashes: root.clashesFor(row.modelData.id)
            width: parent.width
            spacing: Style.space(4)

            Rectangle {
              width: parent.width
              height: Style.spacing.popupRowHeight + Style.space(6)
              radius: Style.cornerRadius
              color: row.listening ? Style.selectedFill
                   : (rowMouse.containsMouse ? Style.hoverFill : "transparent")
              border.width: row.listening ? 1 : 0
              border.color: Color.accent

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: clear.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.listening ? "Press keys…  (Esc to cancel)"
                      : (row.combo !== "" ? row.combo : "Not set")
                color: row.listening ? Color.accent
                       : (row.clashes.some(c => c.ours) ? root.bar.urgent : root.bar.foreground)
                opacity: row.combo === "" && !row.listening ? 0.5 : 1
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: row.combo !== "" && !row.listening
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                anchors.rightMargin: clear.width + Style.space(8)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.listening ? root.stopRecording() : root.startRecording(row.modelData.id)
              }

              PanelActionButton {
                id: clear
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅖"
                tooltipText: "Clear"
                foreground: root.bar.foreground
                hoverColor: root.bar.urgent
                fontFamily: root.bar.fontFamily
                enabled: row.combo !== ""
                opacity: enabled ? 1 : 0.3
                onClicked: root.setDraft(row.modelData.id, "")
              }
            }

            // What it would collide with.
            Repeater {
              model: row.clashes

              delegate: Text {
                required property var modelData
                textFormat: Text.PlainText
                width: row.width
                leftPadding: Style.space(10)
                wrapMode: Text.WordWrap
                text: modelData.ours
                      ? "Same as " + modelData.description + " — pick another."
                      : "Also " + modelData.description + " — saving takes it over."
                color: modelData.ours ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.15)
                opacity: modelData.ours ? 1 : 0.75
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.status !== ""
          wrapMode: Text.WordWrap
          text: root.status
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Saved to the Aerial section of " + root.bindingsPath.replace(String(Quickshell.env("HOME") || ""), "~")
          color: root.bar.foreground
          opacity: 0.45
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---------- save / discard
        Row {
          anchors.right: parent.right
          spacing: Style.space(8)

          Button {
            text: "Discard"
            enabled: root.dirty
            opacity: enabled ? 1 : 0.4
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.discard()
          }

          Button {
            text: "Save"
            enabled: root.dirty && !root.blocked && root.recordingId === ""
            opacity: enabled ? 1 : 0.4
            foreground: root.bar.foreground
            accent: Color.accent
            selected: enabled
            fontFamily: root.bar.fontFamily
            onClicked: root.save()
          }
        }
      }
    }
  }
}
