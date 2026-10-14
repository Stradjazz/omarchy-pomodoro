import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "State.js" as S

// Pomodoro timer with a built-in task list.
//   left click   = start / pause / resume
//   middle click = skip to the next phase
//   right click  = open the panel (timer, tasks, today's stats)
//
// The timer and tasks live in State.js so every monitor's bar shows the same
// thing; this widget drives the clock, writes the state file, and hosts the
// panel. State survives shell restarts: tasks, history, and a running timer
// all come back from ~/.local/state/stradjazz.pomodoro/state.json.
BarWidget {
  id: root
  moduleName: "stradjazz.pomodoro"

  // shell.json may carry these as strings ("35"), so coerce explicitly.
  readonly property int workMinutes: Math.max(1, Number(setting("workMinutes", 25)) || 25)
  readonly property int breakMinutes: Math.max(1, Number(setting("breakMinutes", 5)) || 5)
  readonly property int longBreakMinutes: Math.max(1, Number(setting("longBreakMinutes", 15)) || 15)
  readonly property int longBreakEvery: Math.max(1, Number(setting("longBreakEvery", 4)) || 4)
  readonly property int dailyGoal: Math.max(1, Number(setting("dailyGoal", 8)) || 8)
  readonly property bool autoStartBreaks: setting("autoStartBreaks", true) !== false
  readonly property bool autoStartFocus: setting("autoStartFocus", true) !== false
  readonly property bool sound: setting("sound", true) !== false
  readonly property bool showTaskInBar: setting("showTaskInBar", false) === true

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/stradjazz.pomodoro"

  // ---- Mirrors of the shared state, refreshed by sync(). The panel binds
  //      to these rather than reaching into State.js.
  property string phase: "idle"
  property bool paused: false
  property bool longBreak: false
  property int secondsLeft: 0
  property real progress: 0
  property int completed: 0

  property var tasks: []
  property string activeId: ""
  property var activeTask: null
  property int openCount: 0
  property int todayPomodoros: 0
  property int todayMinutes: 0
  property var recent: []
  property int streak: 0

  property int seenRev: -1
  property string seenDay: ""

  readonly property bool running: phase !== "idle" && !paused
  readonly property string phaseName: phase === "work" ? "Focus"
    : (phase === "break" ? (longBreak ? "Long break" : "Short break") : "Ready")
  readonly property string icon: phase === "break" ? "󰅶" : "󱎫"
  readonly property string clockText: formatClock(phase === "idle" ? workMinutes * 60 : secondsLeft)
  readonly property string barTask: showTaskInBar && activeTask && phase === "work"
    ? "  " + truncate(activeTask.title, 22) : ""
  readonly property string label: phase === "idle" ? icon : icon + " " + clockText + barTask
  // Which focus session of the current set this is (1-based), for the dots.
  readonly property int cyclePosition: completed % longBreakEvery

  function formatClock(total) {
    var m = Math.floor(total / 60)
    var s = total % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  function truncate(text, n) {
    text = String(text || "")
    return text.length > n ? text.slice(0, n - 1) + "…" : text
  }

  function copyTask(t) {
    return t ? { id: t.id, title: t.title, estimate: t.estimate, pomodoros: t.pomodoros, done: t.done } : null
  }

  // ---- Engine

  function sync() {
    if (!S.paused && S.phase !== "idle" && Date.now() >= S.endsAt) finishPhase()
    phase = S.phase
    paused = S.paused
    longBreak = S.longBreak
    completed = S.completed
    var ms = S.phase === "idle" ? 0 : (S.paused ? S.remainingMs : S.endsAt - Date.now())
    secondsLeft = Math.max(0, Math.ceil(ms / 1000))
    progress = S.phase === "idle" || S.phaseMs <= 0 ? 0 : Math.max(0, Math.min(1, 1 - ms / S.phaseMs))

    var day = S.dayKey(new Date())
    if (S.rev !== seenRev || day !== seenDay) {
      seenRev = S.rev
      seenDay = day
      tasks = S.displayTasks().map(copyTask)
      activeId = S.activeId
      activeTask = copyTask(S.activeTask())
      openCount = S.openCount()
      var t = S.today()
      todayPomodoros = t.pomodoros
      todayMinutes = t.minutes
      recent = S.recentDays(7)
      streak = S.streak()
    }
  }

  // Every user-visible mutation ends here: redraw now and save shortly.
  function changed() {
    S.touch()
    sync()
    save()
  }

  function begin(next, minutes, long, run) {
    S.phase = next
    S.longBreak = !!long
    S.phaseMs = minutes * 60000
    S.paused = !run
    S.remainingMs = S.phaseMs
    S.endsAt = Date.now() + S.phaseMs
  }

  function startBreak(run) {
    var long = S.completed > 0 && S.completed % longBreakEvery === 0
    begin("break", long ? longBreakMinutes : breakMinutes, long, run)
  }

  function finishPhase() {
    if (S.phase === "work") {
      S.completed += 1
      var task = S.creditFocus(S.phaseMs / 60000)
      startBreak(autoStartBreaks)
      notifyFocusDone(task)
    } else {
      begin("work", workMinutes, false, autoStartFocus)
      notify("Break over", autoStartFocus
        ? (S.activeTask() ? "Back to: " + S.activeTask().title : "Back to focus.")
        : "Ready when you are — click the timer to start.", "bell")
    }
    S.touch()
    save()
  }

  function notifyFocusDone(task) {
    var lines = []
    if (task) {
      lines.push(task.title + " — " + task.pomodoros + "/" + task.estimate + " 🍅"
        + (task.pomodoros === task.estimate ? " (estimate reached)" : ""))
    }
    var today = S.today().pomodoros
    if (today === dailyGoal) lines.push("Daily goal reached: " + today + " 🍅 today 🎉")
    lines.push(S.longBreak
      ? "Take a long break (" + longBreakMinutes + " min)."
      : "Take a short break (" + breakMinutes + " min).")
    notify("Focus session done", lines.join("\n"), "complete")
  }

  // Task titles end up in the body, so pass argv straight to the programs
  // with no shell in between — there is nothing to quote or escape.
  function notify(title, body, soundName) {
    Quickshell.execDetached(["notify-send", "-a", "Pomodoro", "-i", "alarm-symbolic", "--", String(title), String(body)])
    if (root.sound)
      Quickshell.execDetached(["paplay", "/usr/share/sounds/freedesktop/stereo/" + soundName + ".oga"])
  }

  // ---- Timer actions

  function toggle() {
    if (S.phase === "idle") {
      begin("work", workMinutes, false, true)
    } else if (S.paused) {
      S.paused = false
      S.endsAt = Date.now() + S.remainingMs
    } else {
      S.paused = true
      S.remainingMs = Math.max(0, S.endsAt - Date.now())
    }
    changed()
  }

  function skip() {
    if (S.phase === "idle") return
    if (S.phase === "work") startBreak(true)
    else begin("work", workMinutes, false, true)
    changed()
  }

  function reset() {
    S.phase = "idle"
    S.paused = false
    S.longBreak = false
    S.completed = 0
    changed()
  }

  // Add (or with a negative value, take back) minutes on the running phase.
  function extend(minutes) {
    if (S.phase === "idle") return
    var delta = minutes * 60000
    var remaining = S.paused ? S.remainingMs : S.endsAt - Date.now()
    if (remaining + delta < 60000) delta = 60000 - remaining
    S.phaseMs = Math.max(60000, S.phaseMs + delta)
    if (S.paused) S.remainingMs += delta
    else S.endsAt += delta
    changed()
  }

  // ---- Task actions

  function addTask(text) {
    var parsed = S.parseTaskInput(text)
    if (!parsed) return null
    var task = S.addTask(parsed.title, parsed.estimate)
    changed()
    return task.id
  }

  function renameTask(id, text) {
    var parsed = S.parseTaskInput(text)
    if (!parsed) return
    S.renameTask(id, parsed.title)
    if (/~\s*\d+\s*$/.test(String(text))) S.setEstimate(id, parsed.estimate)
    changed()
  }

  function removeTask(id) { S.removeTask(id); changed() }
  function toggleDone(id) { S.toggleDone(id); changed() }
  function setActive(id) { S.setActive(id); changed() }
  function adjustEstimate(id, delta) { S.adjustEstimate(id, delta); changed() }
  function moveTask(id, delta) { S.moveTask(id, delta); changed() }
  function clearDone() { S.clearDone(); changed() }

  // "Work on this now": select it and, if nothing is running, start focusing.
  function focusTask(id) {
    S.setActive(id)
    if (S.phase === "idle" || (S.phase === "break" && S.paused)) begin("work", workMinutes, false, true)
    else if (S.phase === "work" && S.paused) { S.paused = false; S.endsAt = Date.now() + S.remainingMs }
    changed()
  }

  function completeActive() {
    if (S.activeTask()) toggleDone(S.activeId)
  }

  function statusLine() {
    var a = S.activeTask()
    return JSON.stringify({
      phase: S.phase, paused: S.paused, secondsLeft: root.secondsLeft,
      task: a ? a.title : "", today: S.today().pomodoros, goal: root.dailyGoal
    })
  }

  // ---- Persistence

  function hydrate(raw) {
    // Another monitor's instance (or a pre-reload copy) already loaded it.
    if (S.loaded) { sync(); return }
    S.restore(raw)
    S.loaded = true

    // Back after a long gap (shell restart, laptop asleep): a focus session
    // that ran out while we were gone still counts, but don't start a break
    // that nobody is around to take.
    if (S.phase !== "idle" && !S.paused && Date.now() - S.endsAt > 30 * 60000) {
      if (S.phase === "work") {
        S.completed += 1
        S.creditFocus(S.phaseMs / 60000, new Date(S.endsAt))
      }
      S.phase = "idle"
      S.paused = false
      save()
    }
    S.touch()
    sync()
  }

  function save() {
    if (S.loaded) saveTimer.restart()
  }

  Timer {
    id: saveTimer
    interval: 250
    onTriggered: stateFile.setText(S.serialize())
  }

  FileView {
    id: stateFile
    atomicWrites: true
    printErrors: false
    watchChanges: false
    onLoaded: root.hydrate(text())
    onLoadFailed: root.hydrate("")
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.path = root.stateDir + "/state.json"
  }

  Component.onCompleted: {
    if (S.loaded) sync()
    mkdirProc.running = true
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sync()
  }

  // ---- Panel. Shape contract for shell summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.labelWidth

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // omarchy-shell stradjazz.pomodoro <method> [arg]
  IpcHandler {
    target: "stradjazz.pomodoro"

    function toggle(): void { root.toggle() }
    function skip(): void { root.skip() }
    function reset(): void { root.reset() }
    function extend(minutes: string): void { root.extend(Number(minutes) || 5) }
    function add(title: string): void { root.addTask(title) }
    function done(): void { root.completeActive() }
    function panel(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function status(): string { return root.statusLine() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.icon : root.label
    active: root.phase === "break"
    dimmed: root.paused
    tooltipText: (root.phase === "idle"
        ? "Pomodoro — click to start focusing"
        : root.phaseName + (root.paused ? " (paused)" : "") + " · " + root.clockText + " left")
      + (root.activeTask ? "\nTask: " + root.activeTask.title + " (" + root.activeTask.pomodoros + "/" + root.activeTask.estimate + ")" : "")
      + "\nToday: " + root.todayPomodoros + "/" + root.dailyGoal + " 🍅 · " + S.formatMinutes(root.todayMinutes)
      + "\nLeft: " + (root.running ? "pause" : (root.phase === "idle" ? "start" : "resume")) + " · Middle: skip · Right: tasks"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePanel()
      else if (b === Qt.MiddleButton) root.skip()
      else root.toggle()
    }
  }
}
