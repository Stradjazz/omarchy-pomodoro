.pragma library

// Shared across every bar instance (one per monitor), so all screens show
// the same timer and task list, and only one of them fires the end-of-phase
// notification. Everything here is plain data plus pure helpers; the widget
// owns timing, notifications, and the file on disk.

// ---- Timer
var phase = "idle"      // "idle" | "work" | "break"
var longBreak = false   // the running break is a long one
var endsAt = 0          // epoch ms when the running phase ends
var remainingMs = 0     // frozen remaining time while paused
var phaseMs = 0         // full length of the current phase, for progress
var paused = false
var completed = 0       // focus sessions finished since the last reset

// ---- Focus mode: silence notifications (Omarchy's do-not-disturb) while a
//      focus session is running.
var focusMode = false
var dndOwned = false    // we switched DND on, so we are the ones to switch it off
var dndChecked = false  // this running stretch already decided whether to silence
var dndBusy = false     // a DND query or change is in flight
var dndBusySince = 0

// ---- Tasks
// [{ id, title, estimate, pomodoros, done, created, doneAt }]
var tasks = []
var activeId = ""

// ---- History: "YYYY-MM-DD" -> { pomodoros, minutes }
var history = {}
var historyDays = 90

var loaded = false      // the state file has been read (or found missing)
var rev = 0             // bumped on every change the panel should redraw

function touch() { rev += 1 }

function pad(n) { return (n < 10 ? "0" : "") + n }

function dayKey(d) {
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
}

function newId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 6)
}

function clampEstimate(n) {
  n = Math.round(Number(n) || 1)
  return Math.max(1, Math.min(n, 20))
}

// "Write report ~3" → { title: "Write report", estimate: 3 }.
// A trailing ~N sets the estimate in pomodoros; everything else is the title.
function parseTaskInput(text) {
  var t = String(text || "").trim()
  var estimate = 1
  var m = t.match(/\s*~\s*(\d{1,2})\s*$/)
  if (m) {
    estimate = clampEstimate(m[1])
    t = t.slice(0, m.index).trim()
  }
  return t ? { title: t, estimate: estimate } : null
}

function indexOfTask(id) {
  for (var i = 0; i < tasks.length; i++) if (tasks[i].id === id) return i
  return -1
}

function findTask(id) {
  var i = indexOfTask(id)
  return i < 0 ? null : tasks[i]
}

function activeTask() {
  var t = findTask(activeId)
  return t && !t.done ? t : null
}

// First open task after `afterId` in list order, wrapping; "" when none.
function nextOpenTaskId(afterId) {
  var start = indexOfTask(afterId)
  for (var step = 1; step <= tasks.length; step++) {
    var t = tasks[(start + step + tasks.length) % tasks.length]
    if (!t.done && t.id !== afterId) return t.id
  }
  return ""
}

// Open tasks first, finished ones after — the order the panel lists them.
function displayTasks() {
  var open = [], done = []
  for (var i = 0; i < tasks.length; i++) (tasks[i].done ? done : open).push(tasks[i])
  return open.concat(done)
}

function openCount() {
  var n = 0
  for (var i = 0; i < tasks.length; i++) if (!tasks[i].done) n++
  return n
}

function addTask(title, estimate) {
  var task = {
    id: newId(),
    title: String(title),
    estimate: clampEstimate(estimate),
    pomodoros: 0,
    done: false,
    created: Date.now(),
    doneAt: 0
  }
  // New tasks join the end of the open block, ahead of finished ones.
  var at = tasks.length
  for (var i = 0; i < tasks.length; i++) if (tasks[i].done) { at = i; break }
  tasks.splice(at, 0, task)
  if (!activeTask()) activeId = task.id
  touch()
  return task
}

function removeTask(id) {
  var i = indexOfTask(id)
  if (i < 0) return
  if (activeId === id) activeId = nextOpenTaskId(id)
  tasks.splice(i, 1)
  touch()
}

function renameTask(id, title) {
  var t = findTask(id)
  if (!t || !String(title).trim()) return
  t.title = String(title).trim()
  touch()
}

function setEstimate(id, n) {
  var t = findTask(id)
  if (!t) return
  t.estimate = clampEstimate(n)
  touch()
}

function adjustEstimate(id, delta) {
  var t = findTask(id)
  if (t) setEstimate(id, t.estimate + delta)
}

function toggleDone(id) {
  var t = findTask(id)
  if (!t) return
  t.done = !t.done
  t.doneAt = t.done ? Date.now() : 0
  // A finished task moves down into the done block; a reopened one moves
  // back to the end of the open block.
  var i = indexOfTask(id)
  tasks.splice(i, 1)
  var at = tasks.length
  for (var k = 0; k < tasks.length; k++) if (tasks[k].done) { at = k; break }
  tasks.splice(at, 0, t)
  if (t.done && activeId === id) activeId = nextOpenTaskId(id)
  else if (!t.done && !activeTask()) activeId = id
  touch()
}

function setActive(id) {
  var t = findTask(id)
  if (!t) return
  if (t.done) toggleDone(id)
  activeId = id
  touch()
}

// Reorder within the list as displayed (open block, then done block), so
// moving never hops a task across the boundary.
function moveTask(id, delta) {
  var i = indexOfTask(id)
  var j = i + delta
  if (i < 0 || j < 0 || j >= tasks.length) return
  if (tasks[i].done !== tasks[j].done) return
  var t = tasks[i]
  tasks[i] = tasks[j]
  tasks[j] = t
  touch()
}

function clearDone() {
  tasks = tasks.filter(function(t) { return !t.done })
  touch()
}

// A focus session finished: log it for today and credit the active task.
// Returns the credited task (or null).
function creditFocus(minutes, when) {
  var key = dayKey(when || new Date())
  var day = history[key] || { pomodoros: 0, minutes: 0 }
  day.pomodoros += 1
  day.minutes += Math.max(0, Math.round(minutes))
  history[key] = day
  pruneHistory()

  var t = activeTask()
  if (t) t.pomodoros += 1
  touch()
  return t
}

function pruneHistory() {
  var cutoff = new Date()
  cutoff.setDate(cutoff.getDate() - historyDays)
  var cutoffKey = dayKey(cutoff)
  for (var k in history) if (k < cutoffKey) delete history[k]
}

function today() {
  return history[dayKey(new Date())] || { pomodoros: 0, minutes: 0 }
}

// The last `days` days, oldest first: [{ key, label, pomodoros, minutes, today }]
function recentDays(days) {
  var out = []
  var now = new Date()
  var labels = ["S", "M", "T", "W", "T", "F", "S"]
  for (var i = days - 1; i >= 0; i--) {
    var d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i)
    var h = history[dayKey(d)] || { pomodoros: 0, minutes: 0 }
    out.push({ key: dayKey(d), label: labels[d.getDay()], pomodoros: h.pomodoros, minutes: h.minutes, today: i === 0 })
  }
  return out
}

// Consecutive days with at least one finished focus session, ending today —
// or yesterday, so the streak doesn't read zero before the first session.
function streak() {
  var d = new Date()
  if (!history[dayKey(d)]) d.setDate(d.getDate() - 1)
  var n = 0
  while (history[dayKey(d)] && history[dayKey(d)].pomodoros > 0) {
    n++
    d.setDate(d.getDate() - 1)
  }
  return n
}

function formatMinutes(total) {
  total = Math.round(total)
  var h = Math.floor(total / 60), m = total % 60
  if (h === 0) return m + "m"
  return h + "h" + (m ? " " + pad(m) + "m" : "")
}

// ---- Persistence

function serialize() {
  return JSON.stringify({
    version: 1,
    timer: {
      phase: phase, longBreak: longBreak, endsAt: endsAt, remainingMs: remainingMs,
      phaseMs: phaseMs, paused: paused, completed: completed
    },
    focusMode: focusMode,
    dndOwned: dndOwned,
    tasks: tasks,
    activeId: activeId,
    history: history
  }, null, 2) + "\n"
}

function restore(raw) {
  var data = null
  try { data = raw ? JSON.parse(raw) : null } catch (e) { data = null }
  if (!data || data.version !== 1) return false

  var tm = data.timer || {}
  if (tm.phase === "work" || tm.phase === "break") {
    phase = tm.phase
    longBreak = !!tm.longBreak
    endsAt = Number(tm.endsAt) || 0
    remainingMs = Number(tm.remainingMs) || 0
    phaseMs = Number(tm.phaseMs) || 0
    paused = !!tm.paused
  }
  completed = Number(tm.completed) || 0
  focusMode = data.focusMode === true
  dndOwned = data.dndOwned === true

  tasks = Array.isArray(data.tasks) ? data.tasks.filter(function(t) {
    return t && typeof t.id === "string" && typeof t.title === "string"
  }).map(function(t) {
    return {
      id: t.id, title: t.title, estimate: clampEstimate(t.estimate),
      pomodoros: Math.max(0, Number(t.pomodoros) || 0), done: !!t.done,
      created: Number(t.created) || 0, doneAt: Number(t.doneAt) || 0
    }
  }) : []
  activeId = typeof data.activeId === "string" ? data.activeId : ""
  history = data.history && typeof data.history === "object" ? data.history : {}
  touch()
  return true
}
