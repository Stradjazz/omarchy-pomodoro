import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "State.js" as S

// The pomodoro panel: a progress ring and controls up top, today's numbers
// and the last week beneath, then the task list. Everything reads from the
// host widget's mirrors and writes back through its actions, so all
// monitors stay in step.
//
// Keyboard (list focused):
//   space  start/pause        ⏎  focus on task (and start)
//   j/k    move cursor        J/K  reorder task
//   d      toggle done        x / Del  delete
//   n      new task           e / F2  rename
//   + / -  estimate           [ / ]  −/+ 5 minutes
//   s      skip phase         R  reset timer
//   C      clear done tasks   f  focus mode (silence notifications)
//   Esc    close
Panel {
  id: root
  moduleName: "stradjazz.pomodoro"
  ipcTarget: "stradjazz.pomodoro"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var host: hostWidget
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property color focusColor: Style.selectedStateColor(fg, Color.accent)
  readonly property color breakColor: Color.bar.active
  readonly property color phaseColor: host && host.phase === "break" ? breakColor : focusColor
  readonly property bool rounded: Style.cornerRadius > 0

  readonly property var tasks: host ? host.tasks : []
  readonly property string activeId: host ? host.activeId : ""
  readonly property var activeTask: host ? host.activeTask : null
  property int cursor: 0
  property string editingId: ""
  readonly property var cursorTask: cursor >= 0 && cursor < tasks.length ? tasks[cursor] : null
  readonly property bool fieldFocused: taskField.activeFocus

  readonly property int rowHeight: Style.space(30)
  readonly property int maxVisibleRows: 8

  onTasksChanged: clampCursor()

  function open() {
    cursorToId(activeId)
    root.controller.show()
  }

  function close() {
    if (editingId !== "" || taskField.text !== "") cancelEdit()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- Cursor

  function clampCursor() {
    if (cursor >= tasks.length) cursor = Math.max(0, tasks.length - 1)
    if (cursor < 0) cursor = 0
  }

  function cursorToId(id) {
    for (var i = 0; i < tasks.length; i++) if (tasks[i].id === id) { cursor = i; return }
    clampCursor()
  }

  function moveCursor(delta) {
    if (tasks.length === 0) return
    cursor = Math.max(0, Math.min(tasks.length - 1, cursor + delta))
    ensureVisible()
  }

  function ensureVisible() {
    var top = cursor * root.rowHeight
    if (top < taskScroll.contentY) taskScroll.contentY = top
    else if (top + root.rowHeight > taskScroll.contentY + taskScroll.height)
      taskScroll.contentY = top + root.rowHeight - taskScroll.height
  }

  // Run a task action and keep the cursor on the same task afterwards, since
  // finishing or reordering moves it within the list.
  function onCursorTask(fn) {
    var t = cursorTask
    if (!t || !host) return
    fn(t.id)
    cursorToId(t.id)
    ensureVisible()
  }

  // ---- Add / rename field

  function startAdd() {
    editingId = ""
    taskField.text = ""
    taskField.forceActiveFocus()
  }

  function startEdit() {
    var t = cursorTask
    if (!t) return
    editingId = t.id
    taskField.text = t.title
    taskField.selectAll()
    taskField.forceActiveFocus()
  }

  function cancelEdit() {
    editingId = ""
    taskField.text = ""
    keyCatcher.forceActiveFocus()
  }

  function commitField() {
    if (!host) return
    var text = taskField.text
    if (editingId !== "") {
      var id = editingId
      host.renameTask(id, text)
      cancelEdit()
      cursorToId(id)
      return
    }
    var added = host.addTask(text)
    taskField.text = ""
    if (added) { cursorToId(added); ensureVisible() }
  }

  function handleKey(event) {
    if (root.fieldFocused || !host) return
    var t = event.text
    var k = event.key

    if (k === Qt.Key_Escape) root.close()
    else if (k === Qt.Key_Tab || k === Qt.Key_Backtab)
      root.switchPanel((event.modifiers & Qt.ShiftModifier) || k === Qt.Key_Backtab ? -1 : 1)
    else if (k === Qt.Key_Down || t === "j") moveCursor(1)
    else if (k === Qt.Key_Up || t === "k") moveCursor(-1)
    else if (t === "J") onCursorTask(function(id) { host.moveTask(id, 1) })
    else if (t === "K") onCursorTask(function(id) { host.moveTask(id, -1) })
    else if (k === Qt.Key_Return || k === Qt.Key_Enter) onCursorTask(function(id) { host.focusTask(id) })
    else if (k === Qt.Key_Space) host.toggle()
    else if (t === "d") onCursorTask(function(id) { host.toggleDone(id) })
    else if (t === "x" || k === Qt.Key_Delete) { var c = cursorTask; if (c) host.removeTask(c.id) }
    else if (t === "n" || t === "a" || t === "i" || t === "o") startAdd()
    else if (t === "e" || k === Qt.Key_F2) startEdit()
    else if (t === "+" || t === "=") onCursorTask(function(id) { host.adjustEstimate(id, 1) })
    else if (t === "-" || t === "_") onCursorTask(function(id) { host.adjustEstimate(id, -1) })
    else if (t === "]") host.extend(5)
    else if (t === "[") host.extend(-5)
    else if (t === "s") host.skip()
    else if (t === "R") host.reset()
    else if (t === "C") host.clearDone()
    else if (t === "f") host.toggleFocusMode()
    else return
    event.accepted = true
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }

      Column {
        id: mainColumn
        width: parent.width
        spacing: Style.space(14)

        // ---- Hero: ring with the clock, current task and controls.
        Item {
          width: parent.width
          height: Math.max(ring.height, heroSide.implicitHeight)

          Item {
            id: ring
            width: Style.space(132)
            height: width
            anchors.verticalCenter: parent.verticalCenter

            Canvas {
              id: ringCanvas
              anchors.fill: parent
              property real progress: root.host ? root.host.progress : 0
              property color track: root.faint
              property color fill: root.phaseColor
              property bool square: !root.rounded

              onProgressChanged: requestPaint()
              onTrackChanged: requestPaint()
              onFillChanged: requestPaint()
              onWidthChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var lw = Math.max(4, Math.round(width * 0.055))
                var r = width / 2 - lw / 2 - 1
                var cx = width / 2, cy = height / 2
                ctx.lineWidth = lw
                ctx.lineCap = square ? "butt" : "round"
                ctx.strokeStyle = track
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, Math.PI * 2)
                ctx.stroke()
                if (progress > 0) {
                  ctx.strokeStyle = fill
                  ctx.beginPath()
                  ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * progress)
                  ctx.stroke()
                }
              }
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.space(2)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: root.host ? root.host.clockText : ""
                color: root.host && root.host.paused ? root.dim : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: root.host ? (root.host.phaseName + (root.host.paused ? " · paused" : "")).toUpperCase() : ""
                color: root.host && root.host.phase !== "idle" ? root.phaseColor : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            MouseArea {
              id: ringMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.host) root.host.toggle()
              onWheel: function(wheel) {
                if (!root.host || wheel.angleDelta.y === 0) return
                root.host.extend(wheel.angleDelta.y > 0 ? 1 : -1)
              }

              PanelToolTip {
                visible: ringMouse.containsMouse
                text: "Click: start/pause · Scroll: ±1 minute"
                fontFamily: root.fontFamily
              }
            }
          }

          Column {
            id: heroSide
            anchors.left: ring.right
            anchors.leftMargin: Style.space(20)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: !root.host ? "" : (root.host.phase === "work" ? "NOW FOCUSING ON"
                : (root.host.phase === "break" ? "UP NEXT" : "READY TO FOCUS ON"))
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.activeTask ? root.activeTask.title : "No task selected"
              color: root.activeTask ? root.fg : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: !!root.activeTask
              font.italic: !root.activeTask
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            PomodoroDots {
              theme: root
              visible: !!root.activeTask
              task: root.activeTask
              dotSize: Style.space(9)
            }

            Row {
              spacing: Style.space(6)

              Button {
                iconText: root.host && root.host.running ? "󰏤" : "󰐊"
                text: !root.host ? "" : (root.host.running ? "Pause" : (root.host.phase === "idle" ? "Start" : "Resume"))
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                tooltipText: "Space"
                onClicked: if (root.host) root.host.toggle()
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰒭"
                tooltipText: "Skip to " + (root.host && root.host.phase === "work" ? "break" : "focus") + " (s)"
                foreground: root.fg
                fontFamily: root.fontFamily
                enabled: !!root.host && root.host.phase !== "idle"
                onClicked: root.host.skip()
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "+5"
                fontSize: Style.font.bodySmall
                tooltipText: "Add 5 minutes (])"
                foreground: root.fg
                fontFamily: root.fontFamily
                enabled: !!root.host && root.host.phase !== "idle"
                onClicked: root.host.extend(5)
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰑓"
                tooltipText: "Reset timer and session count (R)"
                foreground: root.fg
                hoverColor: root.breakColor
                fontFamily: root.fontFamily
                enabled: !!root.host && (root.host.phase !== "idle" || root.host.completed > 0)
                onClicked: root.host.reset()
              }
            }
          }
        }

        // ---- Session cadence: one mark per focus session until the long
        //      break, filled as they finish.
        Item {
          width: parent.width
          height: cadenceLabel.implicitHeight

          Text {
            id: cadenceLabel
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: "SESSION"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Row {
            id: cadenceRow
            anchors.left: cadenceLabel.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: cadenceLabel.verticalCenter
            spacing: Style.space(5)

            Repeater {
              model: root.host ? root.host.longBreakEvery : 0

              Rectangle {
                required property int index
                readonly property int filled: !root.host ? 0
                  : (root.host.phase === "break" && root.host.longBreak ? root.host.longBreakEvery : root.host.cyclePosition)
                readonly property bool current: !!root.host && root.host.phase === "work" && index === filled
                width: Style.space(18)
                height: Style.space(6)
                radius: root.rounded ? height / 2 : 0
                color: index < filled ? root.focusColor : (current ? Qt.rgba(root.focusColor.r, root.focusColor.g, root.focusColor.b, 0.35) : root.faint)
              }
            }
          }

          Text {
            anchors.left: cadenceRow.right
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: cadenceLabel.verticalCenter
            textFormat: Text.PlainText
            text: root.host ? "long break after " + root.host.longBreakEvery : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Focus mode: do-not-disturb while a focus session runs.
        Item {
          width: parent.width
          height: Math.max(focusLabel.implicitHeight, focusSwitch.implicitHeight)

          Text {
            id: focusLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "FOCUS MODE"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Text {
            anchors.left: focusLabel.right
            anchors.leftMargin: Style.space(12)
            anchors.right: focusSwitch.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: !root.host ? ""
              : (root.host.silencing ? "󰂛 Notifications silenced until the break"
                : (root.host.focusMode ? "Silences notifications while you focus"
                  : "Off · notifications come through"))
            color: root.host && root.host.silencing ? root.focusColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          ToggleSwitch {
            id: focusSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: !!root.host && root.host.focusMode
            foreground: root.fg
            onToggled: if (root.host) root.host.toggleFocusMode()

            PanelToolTip {
              visible: focusSwitch.containsMouse
              text: "Turn on do-not-disturb during focus sessions (f)"
              fontFamily: root.fontFamily
            }
          }
        }

        // ---- Today and the last week.
        Item {
          width: parent.width
          height: Math.max(statsRow.implicitHeight, weekChart.height)

          Row {
            id: statsRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(22)

            Stat {
              theme: root
              value: root.host ? root.host.todayPomodoros + "/" + root.host.dailyGoal : "0"
              caption: "TODAY"
              highlight: !!root.host && root.host.todayPomodoros >= root.host.dailyGoal
            }
            Stat {
              theme: root
              value: root.host ? S.formatMinutes(root.host.todayMinutes) : "0m"
              caption: "FOCUSED"
            }
            Stat {
              theme: root
              value: root.host ? root.host.streak + "d" : "0d"
              caption: "STREAK"
            }
          }

          Row {
            id: weekChart
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(30) + weekLabelHeight
            spacing: Style.space(5)

            readonly property int barMax: Style.space(30)
            readonly property int weekLabelHeight: Style.space(14)
            readonly property int peak: {
              var m = root.host ? root.host.dailyGoal : 1
              var days = root.host ? root.host.recent : []
              for (var i = 0; i < days.length; i++) m = Math.max(m, days[i].pomodoros)
              return Math.max(1, m)
            }

            Repeater {
              model: root.host ? root.host.recent : []

              Item {
                required property var modelData
                width: Style.space(12)
                height: weekChart.height

                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: dayLabel.top
                  anchors.bottomMargin: Style.space(3)
                  width: parent.width
                  height: Math.max(Style.space(2), Math.round(weekChart.barMax * modelData.pomodoros / weekChart.peak))
                  radius: root.rounded ? Style.space(2) : 0
                  color: modelData.pomodoros === 0 ? root.faint
                    : (modelData.today ? root.focusColor : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.4))
                }

                Text {
                  id: dayLabel
                  anchors.bottom: parent.bottom
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: modelData.today ? root.fg : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: modelData.today
                }

                MouseArea {
                  id: dayMouse
                  anchors.fill: parent
                  hoverEnabled: true

                  PanelToolTip {
                    visible: dayMouse.containsMouse
                    text: modelData.key + " · " + modelData.pomodoros + " 🍅 · " + S.formatMinutes(modelData.minutes)
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---- Tasks
        Item {
          width: parent.width
          height: tasksHeader.implicitHeight

          PanelSectionHeader {
            id: tasksHeader
            anchors.left: parent.left
            text: "TASKS"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: tasksHeader.verticalCenter
            textFormat: Text.PlainText
            text: root.host ? root.host.openCount + " open" + (root.tasks.length > root.host.openCount
              ? " · " + (root.tasks.length - root.host.openCount) + " done" : "") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        TextField {
          id: taskField
          width: parent.width
          placeholderText: root.editingId !== ""
            ? "Rename task — Enter to save, Esc to cancel"
            : "Add a task…  (end with ~3 to estimate 3 pomodoros)"
          foreground: root.fg
          font.family: root.fontFamily

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.commitField()
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              if (root.editingId === "" && taskField.text !== "") taskField.text = ""
              else root.cancelEdit()
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
              root.cancelEdit()
              event.accepted = true
            }
          }
        }

        Text {
          visible: root.tasks.length === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          textFormat: Text.PlainText
          text: "No tasks yet. Type one above and press Enter — or just start the timer."
          wrapMode: Text.Wrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Flickable {
          id: taskScroll
          visible: root.tasks.length > 0
          width: parent.width
          height: Math.min(taskList.implicitHeight, root.rowHeight * root.maxVisibleRows)
          contentWidth: width
          contentHeight: taskList.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: taskList
            width: taskScroll.width

            Repeater {
              model: root.tasks

              CursorSurface {
                id: row
                required property var modelData
                required property int index
                readonly property bool isActive: modelData.id === root.activeId && !modelData.done
                readonly property bool isCursor: index === root.cursor && !root.fieldFocused

                width: taskList.width
                height: root.rowHeight
                hasCursor: isCursor
                current: isActive
                foreground: root.fg

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursor = row.index
                  onClicked: { root.cursor = row.index; if (root.host) root.host.setActive(row.modelData.id) }
                  onDoubleClicked: if (root.host) root.host.focusTask(row.modelData.id)
                }

                PanelActionButton {
                  id: check
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: row.modelData.done ? "󰄵" : "󰄱"
                  tooltipText: row.modelData.done ? "Reopen (d)" : "Mark done (d)"
                  foreground: row.modelData.done ? root.dim : root.fg
                  fontFamily: root.fontFamily
                  onClicked: if (root.host) root.host.toggleDone(row.modelData.id)
                }

                Text {
                  id: playMark
                  visible: row.isActive
                  anchors.left: check.right
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "󰐊"
                  color: root.phaseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  anchors.left: row.isActive ? playMark.right : check.right
                  anchors.leftMargin: Style.space(6)
                  anchors.right: rowDots.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: row.modelData.title
                  color: row.modelData.done ? root.dim : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: row.isActive
                  font.strikeout: row.modelData.done
                  elide: Text.ElideRight
                }

                PomodoroDots {
                  id: rowDots
                  theme: root
                  anchors.right: deleteButton.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  task: row.modelData
                  dotSize: Style.space(7)
                  opacity: row.modelData.done ? 0.5 : 1
                  editable: true
                  onAdjust: function(delta) { if (root.host) root.host.adjustEstimate(row.modelData.id, delta) }
                }

                PanelActionButton {
                  id: deleteButton
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰅖"
                  tooltipText: "Delete (x)"
                  opacity: row.isCursor ? 1 : 0
                  enabled: row.isCursor
                  foreground: root.dim
                  hoverColor: root.breakColor
                  fontFamily: root.fontFamily
                  onClicked: if (root.host) root.host.removeTask(row.modelData.id)
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: root.fieldFocused
            ? "⏎ save · esc / ↓ back to list"
            : "space start/pause · ⏎ focus task · n new · e rename · d done · x delete · J/K reorder · +/- estimate · s skip · [ ] ∓5m · C clear done · f focus mode"
          color: Qt.darker(root.fg, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---- Small pieces. Inline components get `theme: root` handed in
  //      rather than reaching for the outer id.

  // A number over a small-caps caption.
  component Stat: Column {
    id: stat
    property var theme: null
    property string value: ""
    property string caption: ""
    property bool highlight: false
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      text: stat.value
      color: stat.highlight ? stat.theme.focusColor : stat.theme.fg
      font.family: stat.theme.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      text: stat.caption
      color: stat.theme.dim
      font.family: stat.theme.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }

  // Pomodoros spent against the estimate: filled marks for done, hollow for
  // remaining, and the overrun in the break color. Editable rows take clicks
  // to raise the estimate and right-clicks (or scroll) to lower it.
  component PomodoroDots: Item {
    id: dots
    property var theme: null
    property var task: null
    property int dotSize: 8
    property bool editable: false
    signal adjust(int delta)

    readonly property int estimate: task ? task.estimate : 0
    readonly property int spent: task ? task.pomodoros : 0
    readonly property bool compact: Math.max(estimate, spent) > 8

    implicitWidth: dotsRow.implicitWidth
    implicitHeight: Math.max(dotsRow.implicitHeight, dotSize)

    Row {
      id: dotsRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Math.max(2, Math.round(dots.dotSize * 0.45))

      Repeater {
        model: dots.compact ? 0 : Math.max(dots.estimate, dots.spent)

        Rectangle {
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          width: dots.dotSize
          height: dots.dotSize
          radius: dots.theme.rounded ? width / 2 : 0
          color: index < dots.spent ? (index >= dots.estimate ? dots.theme.breakColor : dots.theme.focusColor) : "transparent"
          border.width: index < dots.spent ? 0 : 1
          border.color: dots.theme.dim
        }
      }

      Text {
        visible: dots.compact
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: dots.spent + "/" + dots.estimate + " 🍅"
        color: dots.spent > dots.estimate ? dots.theme.breakColor : dots.theme.fg
        font.family: dots.theme.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: dotsMouse
      enabled: dots.editable
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { dots.adjust(mouse.button === Qt.RightButton ? -1 : 1) }
      onWheel: function(wheel) { if (wheel.angleDelta.y !== 0) dots.adjust(wheel.angleDelta.y > 0 ? 1 : -1) }

      PanelToolTip {
        visible: dotsMouse.containsMouse
        text: dots.spent + " of " + dots.estimate + " pomodoros · click +1 · right-click −1"
        fontFamily: dots.theme.fontFamily
      }
    }
  }
}
