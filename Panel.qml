import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "kit" as Kit
import "Model.js" as Model

// Memory widget. The bar shows free/used/percent and turns yellow or red when
// memory gets tight; the popup shows the last 10 minutes, what RAM is made of,
// pressure and swap against systemd-oomd's own kill lines, zram, the cache
// (and a button to give it back), and the apps holding the most memory: open
// one to see what is inside it, stop it in two clicks.
//
// Cost while closed: a few kernel files re-read every `interval` seconds, no
// process is started. While open: apps.py every 3 s, breakdown.sh for an
// opened row every 9 s.
//
//   left click   - open/close the popup
//   right click  - cycle the bar label (free -> used -> percent -> icon)
//   middle click - open btop
//   popup keys   - r refresh, m bar label, b btop, + / - more or fewer apps, Esc
Panel {
  id: root
  moduleName: "ismoil.memory"
  ipcTarget: "ismoil.memory"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits and can add refresh/cycleDisplay to the standard set.
  manageIpc: false

  readonly property var cfg: Model.config({ language: setting("language", "auto"), locale: Qt.locale().name })
  readonly property string display: String(setting("display", "free"))
  readonly property int pollSeconds: Math.max(2, Number(setting("interval", 3)) || 3)
  readonly property bool notifyOn: setting("notify", true) !== false
  readonly property var countOptions: [5, 10, 15]
  readonly property int topCount: Math.max(1, Math.min(20, Number(setting("topProcesses", 10)) || 10))
  // 10 minutes of history at the poll interval.
  readonly property int historySize: Math.max(30, Math.round(600 / pollSeconds))

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool showText: display !== "icon" && !vertical
  readonly property string icon: "󰍛"

  function tr(key, params) { return Model.tr(cfg, key, params) }
  function kb(n) { return Model.formatKb(cfg, n) }
  // file:///a%20b/x.sh -> /a b/x.sh
  function localPath(url) { return decodeURIComponent(String(url).replace(/^file:\/\//, "")) }

  readonly property string appsScript: localPath(Qt.resolvedUrl("apps.py"))
  readonly property string killScript: localPath(Qt.resolvedUrl("kill-group.sh"))
  readonly property string breakdownScript: localPath(Qt.resolvedUrl("breakdown.sh"))

  // The user's app.slice: its pressure is the number systemd-oomd watches.
  readonly property string uid: (String(Quickshell.env("XDG_RUNTIME_DIR") || "").match(/\/run\/user\/(\d+)/) || [])[1] || ""
  readonly property string appSlice: uid ? "/sys/fs/cgroup/user.slice/user-" + uid + ".slice/user@" + uid + ".service/app.slice" : ""

  // ---------- state ----------
  property var mem: Model.summarize({})
  property var pressure: null
  property var oom: null
  property var zram: null
  property var swaps: []
  property var vmstat: null
  property real vmstatAt: 0
  property var rate: ({ inKb: 0, outKb: 0 })
  readonly property var mood: Model.verdict(mem, pressure, oom)
  readonly property string kitLevel: Model.kitLevel(mood.level)
  property var memHistory: []
  property var pressureHistory: []

  property var apps: []
  // Rows do not change places under the pointer, while one is open or a stop waits for a click.
  readonly property bool appsFrozen: appsHover.hovered || expanded !== "" || Object.keys(killStates).length > 0
  // Installed apps as plain objects, for names and icons; rebuilt when they change.
  readonly property var desktopApps: Array.prototype.map.call(DesktopEntries.applications.values, function(e) {
    return { id: e.id, name: e.name, icon: e.icon, wmClass: e.startupClass, exec: e.command && e.command.length ? e.command[0] : "", cmd: e.command ? e.command.join(" ") : "" }
  })
  // { at: ms, rss: { name: kB } }, oldest first, for "growing".
  property var snapshots: []
  // Kill progress per row name: { phase, at, signal?, signalled?, denied?, owners? }
  // phases: armed -> sending -> sent -> (gone | stuck -> sending KILL), or denied/partial;
  // "failed" when the script gave no answer, "gone" when nothing by that name was running.
  property var killStates: ({})
  property string killing: ""
  readonly property var phaseTtl: ({ armed: 8000, sending: 5000, gone: 3000, failed: 6000, denied: 6000, partial: 6000, stuck: 10000 })
  // Row opened to show what is inside it; "" = none.
  property string expanded: ""
  property var breakdown: []
  property string subArmed: ""

  // "Free it now": "" | "freeing" | "done"; freedKb is what it gave back.
  property string freeState: ""
  property real freeBefore: 0
  property real freedKb: 0

  property int dangerStreak: 0
  property real notifiedAt: 0

  readonly property real pressureLimit: (oom ? oom.pressureLimit : 0.6) * 100

  // ---------- look ----------
  Kit.ThemePalette { id: themePalette }
  Kit.Look {
    id: skin
    textSize: String(root.setting("textSize", "Normal"))
    animations: root.setting("animations", true) !== false
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    themeColors: themePalette.colors
  }
  // The bar tints with the theme's own yellow/red, not the popup-adjusted ones.
  readonly property color levelBase: mood.level === "danger" ? skin.themed("red", Color.urgent)
                                   : mood.level === "tight" ? skin.themed("yellow", "#d0a215") : Color.accent

  TextMetrics { id: sizeMetrics; font.family: skin.fontFamily; font.pixelSize: skin.small; text: "00,0 " + root.tr("unitGB") }

  // ---------- the kernel's files: re-read in place, no process ----------
  FileView { id: meminfoFile; path: "/proc/meminfo"; blockLoading: true }
  FileView {
    id: pressureFile
    path: root.appSlice ? root.appSlice + "/memory.pressure" : "/proc/pressure/memory"
    blockLoading: true
    // No cgroup v2 user slice: the whole system's pressure.
    onLoadFailed: if (path !== "/proc/pressure/memory") path = "/proc/pressure/memory"
  }
  FileView { id: swapsFile; path: "/proc/swaps"; blockLoading: true }
  FileView { id: vmstatFile; path: "/proc/vmstat"; blockLoading: true }
  FileView {
    id: zramFile
    readonly property var dev: root.swaps.filter(function(s) { return s.kind === "zram" })[0]
    path: dev ? "/sys/block/" + dev.name.replace(/.*\//, "") + "/mm_stat" : ""
    blockLoading: true
  }

  function poll() {
    meminfoFile.reload()
    pressureFile.reload()
    if (opened) {
      swapsFile.reload()
      swaps = Model.parseSwaps(swapsFile.text())
      if (zramFile.path !== "") {
        zramFile.reload()
        zram = Model.parseZram(zramFile.text())
      } else {
        zram = null
      }
      // A rate over less than a second (two polls in a row) would divide by
      // almost nothing: keep the last rate and the older baseline instead.
      var now = Date.now()
      if (now - vmstatAt >= 1000) {
        vmstatFile.reload()
        var v = Model.parseVmstat(vmstatFile.text())
        rate = vmstat && now - vmstatAt < 30000 ? Model.swapRate(vmstat, v, (now - vmstatAt) / 1000) : { inKb: 0, outKb: 0 }
        vmstat = v
        vmstatAt = now
      }
    }
    var next = Model.summarize(Model.parseMeminfo(meminfoFile.text()), opened ? zram : null)
    // Keep the last good reading if a poll returns nothing.
    if (next.ready) mem = next
    pressure = Model.parsePressure(pressureFile.text())
    memHistory = Model.pushHistory(memHistory, mem.usedFraction, historySize)
    pressureHistory = Model.pushHistory(pressureHistory, pressure ? Math.min(1, pressure.full / pressureLimit) : 0, historySize)
    if (freeState === "freeing" && !reclaimProc.running) finishFree()
    checkNotify()
  }

  // A warning only after two danger readings in a row, then at most every 10 min.
  function checkNotify() {
    dangerStreak = mood.level === "danger" ? dangerStreak + 1 : 0
    if (!notifyOn || dangerStreak !== 2 || Date.now() - notifiedAt < 600000 || notifyProc.running) return
    notifiedAt = Date.now()
    notifyProc.command = ["notify-send", "-u", "critical", "-a", tr("title"), "-i", "dialog-warning",
                          tr("notifyTitle"), tr("notifyBody", { why: tr(mood.why) })]
    notifyProc.running = true
  }

  Process { id: notifyProc }

  // systemd-oomd's kill lines, once: they change only when its config does.
  Process {
    id: oomProc
    command: ["oomctl"]
    running: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.oom = Model.parseOomctl(text) }
  }

  // ---------- apps (popup only) ----------
  function refreshApps() {
    if (!appsProc.running) {
      appsProc.command = ["python3", "-I", appsScript, String(topCount)]
      appsProc.running = true
    }
  }

  function applyApps(raw) {
    var next = Model.parseApps(raw)
    if (next === null || (next.length === 0 && apps.length > 0)) return
    apps = appsFrozen ? Model.keepOrder(apps, next) : next
    var now = Date.now()
    var map = {}
    for (var i = 0; i < next.length; i++) map[next[i].name] = next[i].rssKb
    snapshots = snapshots.filter(function(s) { return now - s.at < 180000 }).concat([{ at: now, rss: map }])
    pruneKillStates()
  }

  Process {
    id: appsProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyApps(text) }
  }

  function refreshBreakdown() {
    if (expanded === "" || breakdownProc.running) return
    breakdownProc.command = ["sh", breakdownScript, expanded]
    breakdownProc.running = true
  }

  function toggleExpanded(name) {
    expanded = expanded === name ? "" : name
    breakdown = []
    subArmed = ""
    refreshBreakdown()
  }

  function applyBreakdown(raw) {
    var next = Model.parseBreakdown(raw)
    // Drop an answer for a row that was closed or swapped while it ran.
    if (next.length > 0 && breakdownProc.command[2] === expanded) breakdown = next
  }

  Process {
    id: breakdownProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyBreakdown(text) }
  }

  // ---------- stopping ----------
  function setKillState(name, s) {
    var next = Object.assign({}, killStates)
    if (s) next[name] = Object.assign({ at: Date.now() }, s)
    else delete next[name]
    killStates = next
  }

  // × arms the row, Stop sends SIGTERM, Force (after SIGTERM was ignored)
  // sends SIGKILL. Which processes may be signalled is left to the kernel.
  function armKill(name) { setKillState(name, { phase: "armed" }) }
  function cancelKill(name) { setKillState(name, null) }

  // Esc first drops a pending confirm, then closes the popup.
  function escapePressed() {
    if (subArmed !== "") { subArmed = ""; return }
    var next = {}
    var dropped = false
    for (var name in killStates) {
      if (killStates[name].phase === "armed") dropped = true
      else next[name] = killStates[name]
    }
    if (dropped) killStates = next
    else close()
  }

  function sendSignal(name, sig) {
    if (killProc.running) return
    setKillState(name, { phase: "sending", signal: sig })
    killing = name
    killProc.command = ["sh", killScript, name, sig]
    killProc.running = true
  }

  function applyKill(raw) {
    var r = Model.parseKillResult(raw)
    if (!r) {
      if (killing !== "") setKillState(killing, { phase: "failed" })
      return
    }
    var sig = killStates[r.name] ? killStates[r.name].signal : "TERM"
    if (r.denied > 0 && r.signalled === 0) setKillState(r.name, { phase: "denied", owners: r.owners })
    else if (r.denied > 0) setKillState(r.name, { phase: "partial", signalled: r.signalled, denied: r.denied, owners: r.owners })
    else if (r.signalled > 0) setKillState(r.name, { phase: "sent", signal: sig })
    else setKillState(r.name, { phase: "gone" })
    refreshApps()
  }

  function pruneKillStates() {
    var now = Date.now()
    var listed = {}
    for (var i = 0; i < apps.length; i++) listed[apps[i].name] = true
    var next = {}
    var changed = false
    for (var name in killStates) {
      var s = killStates[name]
      var age = now - s.at
      var keep = s
      // "sending" that outlives its TTL means the script never answered.
      if (s.phase === "sending" && age > phaseTtl.sending) keep = { phase: "failed", at: now }
      else if (s.phase !== "sent" && phaseTtl[s.phase] !== undefined && age > phaseTtl[s.phase]) keep = null
      else if (s.phase === "sent" && !listed[name]) keep = null
      else if (s.phase === "sent" && age > 3000)
        keep = s.signal === "TERM" ? Object.assign({}, s, { phase: "stuck" }) : null
      if (keep !== s) changed = true
      if (keep) next[name] = keep
    }
    if (changed) killStates = next
  }

  // Stops only the PIDs of one inner line; the kernel decides what is allowed.
  function stopPids(pids) {
    subArmed = ""
    if (subKillProc.running) return
    subKillProc.command = ["kill", "-TERM"].concat(pids)
    subKillProc.running = true
  }

  Process {
    id: subKillProc
    onExited: { root.refreshApps(); root.refreshBreakdown() }
  }

  Process {
    id: killProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyKill(text) }
  }

  // ---------- giving the cache back ----------
  // memory.reclaim with swappiness=0 drops file cache only: nothing is pushed
  // to swap, nothing is killed, and the file is the user's own (no root).
  function freeCache() {
    if (reclaimProc.running || !appSlice) return
    freeState = "freeing"
    freeBefore = mem.freeKb
    var mb = Math.max(64, Math.round(mem.cacheKb / 1024))
    reclaimProc.command = ["sh", "-c", "printf '%sM swappiness=0' \"$1\" > \"$2\"", "sh", String(mb), appSlice + "/memory.reclaim"]
    reclaimProc.running = true
  }

  function finishFree() {
    freedKb = Math.max(0, mem.freeKb - freeBefore)
    freeState = "done"
    freeReset.restart()
  }

  // The kernel answers "try again" when it gave back less than asked: that is fine.
  Process {
    id: reclaimProc
    onExited: root.poll()
  }

  Timer { id: freeReset; interval: 8000; onTriggered: root.freeState = "" }

  // ---------- timers ----------
  Timer {
    interval: root.pollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshApps()
  }

  Timer {
    interval: 9000
    running: root.opened && root.expanded !== ""
    repeat: true
    onTriggered: root.refreshBreakdown()
  }

  onOpenedChanged: {
    if (opened) {
      poll()
    } else {
      expanded = ""
      breakdown = []
      subArmed = ""
      scroller.contentY = 0
    }
  }

  // ---------- settings from the popup ----------
  function saveSettings(change) {
    settings = Object.assign({}, settings, change)
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
  }

  function cycleDisplay() { saveSettings({ display: Model.nextMode(display) }) }

  function setTopCount(n) {
    saveSettings({ topProcesses: Math.max(1, Math.min(20, Number(n) || 10)) })
    refreshApps()
  }

  // +/- keys walk the 5/10/15 presets.
  function stepTopCount(delta) {
    var idx = countOptions.indexOf(topCount)
    if (idx < 0) idx = delta > 0 ? -1 : countOptions.length
    setTopCount(countOptions[Math.max(0, Math.min(countOptions.length - 1, idx + delta))])
  }

  function openMonitor() {
    close()
    if (bar) bar.run("omarchy-launch-or-focus-tui btop")
  }

  IpcHandler {
    target: "ismoil.memory"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.poll(); root.refreshApps() }
    function cycleDisplay(): void { root.cycleDisplay() }
  }

  // ---------- bar ----------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  TextMetrics {
    id: barLabelMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: button.labelText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Omarchy 4.5: `text` is a single icon glyph; the number goes in `labelText`.
    text: root.icon
    labelText: root.showText ? Model.barLabel(root.display, root.mem) : ""
    active: root.mood.level !== "calm"
    activeColor: root.levelBase
    slotSize: root.showText ? Math.ceil(button.canvasSize + barLabelMetrics.width + Style.space(4)) + Style.space(14) : Style.bar.iconSlot
    tooltipText: root.opened ? "" : Model.tooltip(root.cfg, root.mem, root.mood)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleDisplay()
      else if (b === Qt.MiddleButton) root.openMonitor()
      else root.toggle()
    }
  }

  // ---------- popup ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Math.round(Style.space(410) * skin.textScale))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + skin.bottomPad)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.openMonitor()
      onCloseRequested: root.escapePressed()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") { root.poll(); root.refreshApps() }
        else if (t === "m") root.cycleDisplay()
        else if (t === "b") root.openMonitor()
        else if (t === "+" || t === "=") root.stepTopCount(1)
        else if (t === "-") root.stepTopCount(-1)
      }

      // Many apps or large text can outgrow the screen: it scrolls.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight + skin.bottomPad
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(12)

          // ---------- Hero: icon · percent and what is used · verdict ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.height, heroText.implicitHeight, chip.implicitHeight)

            Rectangle {
              id: heroIcon
              width: Math.round(skin.hero * 1.7)
              height: width
              radius: skin.radius
              color: Util.alpha(skin.levelFill(root.kitLevel), 0.16)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Behavior on color { ColorAnimation { duration: skin.fade } }

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.icon
                color: skin.levelText(root.kitLevel)
                font.family: skin.fontFamily
                font.pixelSize: skin.hero
              }
            }

            Column {
              id: heroText
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: chip.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.mem.ready ? Model.percent(root.mem.usedFraction) : "—"
                color: skin.ink
                font.family: skin.fontFamily
                font.pixelSize: skin.heroLarge
                font.bold: true
                font.features: { "tnum": 1 }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: !root.mem.ready ? root.tr("reading")
                    : root.mood.why !== "" ? root.tr(root.mood.why)
                    : root.tr("usedOf", { used: root.kb(root.mem.usedKb), total: root.kb(root.mem.totalKb) })
                color: root.mood.level === "calm" ? skin.dim : skin.levelText(root.kitLevel)
                font.family: skin.fontFamily
                font.pixelSize: skin.small
                wrapMode: Text.WordWrap
              }
            }

            Kit.Chip {
              id: chip
              look: skin
              text: root.mem.ready ? root.tr(root.mood.level) : ""
              tone: skin.levelFill(root.kitLevel)
              toneText: skin.levelText(root.kitLevel)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // ---------- Last 10 minutes ----------
          Kit.AreaChart {
            width: parent.width
            look: skin
            capacity: root.historySize
            leftLabel: root.tr("chartAgo")
            rightLabel: root.tr("chartNow")
            series: [
              { values: root.memHistory, color: skin.accentFill, fill: true, label: root.tr("chartMemory") },
              { values: root.pressureHistory, color: skin.bad, dashed: true, label: root.tr("chartPressure") }
            ]
          }

          // ---------- What RAM is made of ----------
          Kit.SegmentBar {
            width: parent.width
            look: skin
            segments: [
              { value: root.mem.programsKb, color: skin.accentFill, label: root.tr("partPrograms"), text: Model.shortKb(root.mem.programsKb) },
              { value: root.mem.cacheKb, color: skin.hue("cyan"), label: root.tr("partCache"), text: Model.shortKb(root.mem.cacheKb) },
              { value: root.mem.zramKb, color: skin.hue("magenta"), label: root.tr("partZram"), text: Model.shortKb(root.mem.zramKb) },
              { value: root.mem.freeKb, color: skin.track, label: root.tr("partFree"), text: Model.shortKb(root.mem.freeKb) }
            ].filter(function(s) { return s.value > 0 })
          }

          // ---------- Pressure · swap · zram · cache ----------
          Kit.TileRow {
            width: parent.width

            Kit.Tile {
              look: skin
              caption: root.tr("tilePressure")
              value: root.pressure ? Model.pressureText(root.pressure.full) : "—"
              fraction: root.pressure ? Math.min(1, root.pressure.full / (root.pressureLimit * 1.25)) : 0
              mark: 0.8
              fill: skin.levelFill(root.mood.why === "whyPressure" ? root.kitLevel : "good")
              detail: root.oom ? root.tr("tilePressureKill", { limit: Math.round(root.pressureLimit) + "%", sec: root.oom.durationSec })
                               : root.tr("tilePressureNoOomd")
            }

            Kit.Tile {
              look: skin
              caption: root.tr("tileSwap")
              value: root.mem.swapTotalKb > 0 ? Model.percent(root.mem.swapFraction) : root.tr("noSwap")
              fraction: root.mem.swapTotalKb > 0 ? root.mem.swapFraction : -1
              mark: root.oom ? root.oom.swapLimit : -1
              fill: skin.levelFill(root.mood.why === "whySwap" ? root.kitLevel : "good")
              detail: root.mem.swapTotalKb <= 0 ? ""
                    : (root.oom ? root.tr("tileSwapKill", { used: root.kb(root.mem.swapUsedKb), total: root.kb(root.mem.swapTotalKb), limit: Model.percent(root.oom.swapLimit) })
                                : root.tr("tileSwapPlain", { used: root.kb(root.mem.swapUsedKb), total: root.kb(root.mem.swapTotalKb) }))
                      + (root.rate.inKb + root.rate.outKb >= 64
                         ? "\n" + root.tr("tileSwapRate", { in: root.kb(root.rate.inKb), out: root.kb(root.rate.outKb) }) : "")
            }

          }

          Kit.TileRow {
            width: parent.width

            Kit.Tile {
              visible: root.zram !== null && root.zram.origKb > 0
              look: skin
              caption: root.tr("tileZram")
              value: Model.ratioText(root.cfg, root.zram)
              detail: root.zram ? root.tr("tileZramDetail", { orig: root.kb(root.zram.origKb), used: root.kb(root.zram.usedKb) }) : ""
            }

            Kit.Tile {
              look: skin
              caption: root.tr("tileCache")
              value: root.kb(root.mem.cacheKb)
              detail: root.freeState === "freeing" ? root.tr("freeing")
                    : root.freeState === "done" ? (root.freedKb >= 1024 ? root.tr("freed", { n: root.kb(root.freedKb) }) : root.tr("freedNone"))
                    : root.tr("tileCacheDetail")
              action: root.appSlice && root.freeState === "" ? root.tr("freeCache") : ""
              onActivated: root.freeCache()
            }
          }

          // ---------- Apps ----------
          Kit.Card {
            id: appsCard
            width: parent.width
            look: skin
            spacing: Style.space(2)

            HoverHandler { id: appsHover }

            Item {
              width: parent.width
              implicitHeight: Math.max(appsHeader.implicitHeight, countPicker.implicitHeight) + Style.space(4)

              Text {
                id: appsHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.tr("sectionApps").toUpperCase()
                color: skin.dim
                font.family: skin.fontFamily
                font.pixelSize: skin.small
                font.letterSpacing: 0.8
              }

              Row {
                id: countPicker
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Repeater {
                  model: root.countOptions

                  delegate: Button {
                    required property var modelData
                    text: String(modelData)
                    tooltipText: root.tr("showTop", { n: modelData })
                    selected: root.topCount === modelData
                    bordered: true
                    foreground: skin.ink
                    fontFamily: skin.fontFamily
                    fontSize: skin.small
                    horizontalPadding: Style.space(7)
                    verticalPadding: Style.space(1)
                    onClicked: root.setTopCount(modelData)
                  }
                }
              }
            }

            Text {
              visible: root.apps.length === 0
              textFormat: Text.PlainText
              text: root.tr("collecting")
              color: skin.dim
              font.family: skin.fontFamily
              font.pixelSize: skin.small
            }

            Repeater {
              model: root.apps

              // Normal:   [icon] Name ×3 ↑            1.9 GB   (hover: ×)
              //                  +1.6 GB in swap
              // Confirm:  [icon] Name ········ [Cancel] [Stop]
              // Result:   [icon] Name ····· status text [Force]
              delegate: Column {
                id: appRow
                required property var modelData
                readonly property bool open: root.expanded === modelData.name
                // The desktop entry gives a real name and icon.
                readonly property var entry: Model.matchApp(modelData.name, root.desktopApps)
                readonly property string title: entry && entry.name ? entry.name : modelData.name
                width: appsCard.width - appsCard.padding * 2

                Item {
                  id: appItem
                  readonly property var killState: root.killStates[appRow.modelData.name]
                  readonly property string killPhase: killState ? killState.phase : ""
                  readonly property string killText: Model.killStatus(root.cfg, killState)
                  readonly property bool confirming: killPhase === "armed"
                  readonly property bool refused: killPhase === "denied" || killPhase === "partial" || killPhase === "failed"
                  readonly property bool growing: Model.isGrowing(appRow.modelData.name, appRow.modelData.rssKb, root.snapshots, Date.now())
                  width: parent.width
                  implicitHeight: Math.max(appIcon.height, nameCol.implicitHeight) + Style.space(10)

                  HoverHandler { id: appHover }

                  Rectangle {
                    anchors.fill: parent
                    radius: Math.min(6, skin.radius)
                    color: appItem.confirming || appItem.refused ? Util.alpha(skin.bad, 0.14)
                         : appRow.open ? Util.alpha(skin.ink, 0.07)
                         : Util.alpha(skin.ink, appHover.hovered ? 0.05 : 0)
                    Behavior on color { ColorAnimation { duration: 120 } }
                  }

                  Kit.AppIcon {
                    id: appIcon
                    look: skin
                    size: Math.round(skin.small * 1.9)
                    name: appRow.title
                    source: Quickshell.iconPath(appRow.entry && appRow.entry.icon ? appRow.entry.icon : appRow.modelData.name, true)
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    id: nameCol
                    anchors.left: appIcon.right
                    anchors.leftMargin: Style.space(10)
                    anchors.right: tail.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: (appRow.open ? "▾ " : "") + appRow.title
                            + (appRow.modelData.count > 1 ? "  ×" + appRow.modelData.count : "")
                      color: skin.ink
                      font.family: skin.fontFamily
                      font.pixelSize: skin.small
                      font.bold: appRow.open
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: text !== ""
                      width: parent.width
                      textFormat: Text.PlainText
                      text: [appRow.title.toLowerCase() !== appRow.modelData.name.toLowerCase() ? appRow.modelData.name : "",
                             appItem.growing ? root.tr("growing") : "",
                             appRow.modelData.swapKb >= 50 * 1024 ? root.tr("inSwap", { n: root.kb(appRow.modelData.swapKb) }) : ""]
                            .filter(function(t) { return t !== "" }).join(" · ")
                      color: appItem.growing ? skin.warnText : skin.dim
                      font.family: skin.fontFamily
                      font.pixelSize: skin.small
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.left: parent.left
                    anchors.right: tail.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleExpanded(appRow.modelData.name)
                  }

                  Row {
                    id: tail
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    // Normal: the size, or the stop button under the pointer.
                    Item {
                      visible: appItem.killPhase === ""
                      width: sizeMetrics.width
                      height: sizeMetrics.height + Style.space(4)

                      Text {
                        anchors.fill: parent
                        visible: !appHover.hovered
                        horizontalAlignment: Text.AlignRight
                        verticalAlignment: Text.AlignVCenter
                        textFormat: Text.PlainText
                        text: root.kb(appRow.modelData.rssKb)
                        color: skin.ink
                        font.family: skin.fontFamily
                        font.pixelSize: skin.small
                        font.bold: true
                        font.features: { "tnum": 1 }
                      }

                      Button {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: appHover.hovered
                        iconText: "󰅖"
                        iconSize: skin.body
                        text: root.tr("stop")
                        tooltipText: root.tr("stopTip", { name: appRow.title }) + (appRow.modelData.count > 1 ? " · " + Model.count(root.cfg, "processes", appRow.modelData.count) : "")
                        foreground: skin.badText
                        fontFamily: skin.fontFamily
                        fontSize: skin.small
                        horizontalPadding: Style.space(4)
                        verticalPadding: 0
                        onClicked: root.armKill(appRow.modelData.name)
                      }
                    }

                    Button {
                      visible: appItem.confirming
                      text: root.tr("cancel")
                      fontSize: skin.small
                      foreground: skin.ink
                      fontFamily: skin.fontFamily
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(1)
                      onClicked: root.cancelKill(appRow.modelData.name)
                    }

                    Button {
                      visible: appItem.confirming
                      text: appRow.modelData.count > 1 ? root.tr("stopN", { n: appRow.modelData.count }) : root.tr("stop")
                      tooltipText: root.tr("stopAllTip", { name: appRow.modelData.name })
                      fontSize: skin.small
                      foreground: skin.badText
                      fontFamily: skin.fontFamily
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(1)
                      onClicked: root.sendSignal(appRow.modelData.name, "TERM")
                    }

                    Text {
                      visible: appItem.killText !== ""
                      textFormat: Text.PlainText
                      text: appItem.killText
                      color: appItem.refused ? skin.badText : skin.dim
                      font.family: skin.fontFamily
                      font.pixelSize: skin.small
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Button {
                      visible: appItem.killPhase === "stuck"
                      text: root.tr("force")
                      tooltipText: root.tr("forceTip")
                      fontSize: skin.small
                      foreground: skin.badText
                      fontFamily: skin.fontFamily
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(1)
                      onClicked: root.sendSignal(appRow.modelData.name, "KILL")
                    }
                  }
                }

                // What is inside the row: Chrome tabs/extensions/GPU, or one line per
                // script and project folder (node, php, claude ...).
                Text {
                  visible: appRow.open && root.breakdown.length === 0
                  leftPadding: appIcon.width + Style.space(14)
                  topPadding: Style.space(2)
                  bottomPadding: Style.space(4)
                  textFormat: Text.PlainText
                  text: root.tr("lookingInside")
                  color: skin.dim
                  font.family: skin.fontFamily
                  font.pixelSize: skin.small
                }

                Repeater {
                  model: appRow.open ? root.breakdown : []

                  delegate: Item {
                    id: subItem
                    required property var modelData
                    readonly property bool armed: root.subArmed === modelData.name
                    width: appRow.width
                    implicitHeight: sizeMetrics.height + Style.space(8)

                    HoverHandler { id: subHover }

                    Rectangle {
                      anchors.fill: parent
                      anchors.leftMargin: appIcon.width + Style.space(8)
                      radius: Math.min(4, skin.radius)
                      color: subItem.armed ? Util.alpha(skin.bad, 0.14) : Util.alpha(skin.ink, subHover.hovered ? 0.05 : 0)
                    }

                    // A thin guide line ties the inner lines to their app.
                    Rectangle {
                      x: Style.space(4) + appIcon.width / 2
                      width: 1
                      height: parent.height
                      color: skin.track
                    }

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: appIcon.width + Style.space(14)
                      anchors.right: subTail.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: subItem.modelData.name + (subItem.modelData.count > 1 ? "  ×" + subItem.modelData.count : "")
                      color: skin.ink
                      font.family: skin.fontFamily
                      font.pixelSize: skin.small
                      elide: Text.ElideMiddle
                    }

                    Row {
                      id: subTail
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)

                      Text {
                        visible: !subItem.armed && !subHover.hovered
                        textFormat: Text.PlainText
                        text: root.kb(subItem.modelData.rssKb)
                        color: skin.dim
                        font.family: skin.fontFamily
                        font.pixelSize: skin.small
                        font.features: { "tnum": 1 }
                      }

                      Button {
                        visible: subHover.hovered && !subItem.armed
                        iconText: "󰅖"
                        iconSize: skin.small
                        text: root.tr("stop")
                        tooltipText: root.tr("stopTip", { name: subItem.modelData.name })
                        foreground: skin.badText
                        fontFamily: skin.fontFamily
                        fontSize: skin.small
                        horizontalPadding: Style.space(4)
                        verticalPadding: 0
                        onClicked: root.subArmed = subItem.modelData.name
                      }

                      Button {
                        visible: subItem.armed
                        text: root.tr("cancel")
                        fontSize: skin.small
                        foreground: skin.ink
                        fontFamily: skin.fontFamily
                        horizontalPadding: Style.space(6)
                        verticalPadding: 0
                        onClicked: root.subArmed = ""
                      }

                      Button {
                        visible: subItem.armed
                        text: subItem.modelData.pids.length > 1 ? root.tr("stopN", { n: subItem.modelData.pids.length }) : root.tr("stop")
                        tooltipText: root.tr("stopPidsTip", { pids: subItem.modelData.pids.join(", ") })
                        fontSize: skin.small
                        foreground: skin.badText
                        fontFamily: skin.fontFamily
                        bordered: true
                        horizontalPadding: Style.space(6)
                        verticalPadding: 0
                        onClicked: root.stopPids(subItem.modelData.pids)
                      }
                    }
                  }
                }
              }
            }
          }

          // ---------- Actions ----------
          Row {
            id: actionRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing) / 2
            readonly property real buttonHeight: Math.max(btopButton.implicitHeight, modeButton.implicitHeight)

            Button {
              id: btopButton
              width: actionRow.cellWidth
              height: actionRow.buttonHeight
              iconText: "󰆍"
              iconSize: skin.strong
              text: root.tr("openBtop")
              fontSize: skin.small
              foreground: skin.ink
              fontFamily: skin.fontFamily
              bordered: true
              onClicked: root.openMonitor()
            }

            Button {
              id: modeButton
              width: actionRow.cellWidth
              height: actionRow.buttonHeight
              iconText: "󰈈"
              iconSize: skin.strong
              text: root.tr("barMode", { mode: Model.modeLabel(root.cfg, root.display) })
              fontSize: skin.small
              foreground: skin.ink
              fontFamily: skin.fontFamily
              bordered: true
              onClicked: root.cycleDisplay()
            }
          }
        }
      }
    }
  }
}
