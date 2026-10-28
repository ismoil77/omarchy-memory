import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "kit/Contrast.js" as Contrast

// Memory widget: icon plus a free/used/percent label in the bar, and a popup
// with the usage bar, swap, and the processes holding the most RAM.
//
//   left click   - open/close the popup
//   right click  - cycle the bar label (free -> used -> percent -> icon)
//   middle click - open btop
//   popup        - 5/10/15 picks how many processes to list (also +/- keys)
Panel {
  id: root
  moduleName: "ismoil.memory"
  ipcTarget: "ismoil.memory"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits and can add refresh/cycleDisplay to the standard set.
  manageIpc: false

  readonly property string display: String(setting("display", "free"))
  readonly property real warnPercent: Number(setting("warnPercent", 90))
  readonly property int pollSeconds: Math.max(1, Number(setting("interval", 3)) || 3)
  readonly property var countOptions: [5, 10, 15]
  readonly property int topCount: Math.max(1, Math.min(20, Number(setting("topProcesses", 10)) || 10))

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool showText: display !== "icon" && !vertical
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string icon: "󰍛"

  property var mem: Model.summarize({})
  property var processes: []
  // Kill progress per row name: { phase, at, signal?, signalled?, denied?, owners? }
  // phases: armed -> sending -> sent -> (gone | stuck -> sending KILL), or denied/partial;
  // "failed" when the script gave no answer, "gone" when nothing by that name was running.
  property var killStates: ({})
  property string killing: ""
  readonly property var phaseTtl: ({ armed: 8000, sending: 5000, gone: 3000, failed: 6000, denied: 6000, partial: 6000, stuck: 10000 })
  readonly property string killScript: decodeURIComponent(String(Qt.resolvedUrl("kill-group.sh")).replace(/^file:\/\//, ""))


  // Level colours come from the theme: its accent while memory is fine, its
  // yellow once it gets tight, its red at warnPercent. Popup colours are held
  // to a contrast the theme does not promise (a yellow that reads on a dark
  // popup is nearly invisible on a cream one).
  readonly property real cautionPercent: Number(setting("cautionPercent", 75))
  readonly property string level: mem.ready ? Model.level(mem.usedFraction, cautionPercent, warnPercent) : "ok"
  property var themePalette: ({})
  readonly property string popupBg: String(Color.popups.background)
  readonly property color popupText: Qt.color(Contrast.ensure(String(Color.popups.text), popupBg, 7))
  readonly property color popupDim: Qt.color(Contrast.ensure(Contrast.mix(String(Color.popups.text), popupBg, 0.22), popupBg, 4.5))
  readonly property color popupUrgent: onPopup(themeColor("red", Color.urgent), 4.5)
  readonly property color popupAccent: onPopup(Color.accent, 3)
  readonly property color levelBase: level === "red" ? themeColor("red", Color.urgent) : level === "yellow" ? themeColor("yellow", "#D0A215") : Color.accent
  readonly property color fillColor: onPopup(levelBase, 3)
  readonly property color fillText: onPopup(levelBase, 4.5)
  readonly property string colorsPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"

  function themeColor(name, fallback) { return themePalette[name] ? themePalette[name] : fallback }
  function onPopup(color, min) { return Qt.color(Contrast.ensure(String(color), popupBg, min)) }
  function parseColors(text) {
    var next = {}
    var re = /^\s*(red|yellow)\s*=\s*"(#[0-9A-Fa-f]{6})"/gm
    var m
    while ((m = re.exec(text)) !== null) next[m[1]] = m[2]
    themePalette = next
  }

  FileView {
    path: root.colorsPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.parseColors(text())
  }
  readonly property real listedKb: Model.sumRss(processes)

  // Column widths for the process list, measured once so rows line up.
  TextMetrics { id: shareMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; text: "100%" }
  TextMetrics { id: sizeMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; text: "00.0 GB" }

  function refresh() {
    if (!memProc.running) memProc.running = true
    if (opened && !psProc.running) psProc.running = true
  }

  function applyMeminfo(raw) {
    var next = Model.summarize(Model.parseMeminfo(raw))
    // Keep the last good reading if a poll returns nothing.
    if (!next.ready) return
    mem = next
  }

  function applyProcesses(raw) {
    var next = Model.parseProcesses(raw)
    if (next.length === 0 && processes.length > 0) return
    processes = next
    pruneKillStates()
  }

  function setKillState(name, state) {
    var next = Object.assign({}, killStates)
    if (state) next[name] = Object.assign({ at: Date.now() }, state)
    else delete next[name]
    killStates = next
  }

  // × arms the row, Stop sends SIGTERM, Force (after SIGTERM was ignored)
  // sends SIGKILL. Which processes may be signalled is left to the kernel.
  function armKill(name) { setKillState(name, { phase: "armed" }) }
  function cancelKill(name) { setKillState(name, null) }

  // Esc first drops a pending "Stop?" confirm, then closes the popup.
  function escapePressed() {
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
    refresh()
  }

  function pruneKillStates() {
    var now = Date.now()
    var listed = {}
    for (var i = 0; i < processes.length; i++) listed[processes[i].name] = true
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

  function cycleDisplay() {
    settings = Object.assign({}, settings, { display: Model.nextMode(display) })
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
  }

  function openMonitor() {
    close()
    if (bar) bar.run("omarchy-launch-or-focus-tui btop")
  }

  function setTopCount(n) {
    var count = Math.max(1, Math.min(20, Number(n) || 10))
    settings = Object.assign({}, settings, { topProcesses: count })
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
    refresh()
  }

  // +/- keys walk the 5/10/15 presets.
  function stepTopCount(delta) {
    var idx = countOptions.indexOf(topCount)
    if (idx < 0) idx = delta > 0 ? -1 : countOptions.length
    var next = Math.max(0, Math.min(countOptions.length - 1, idx + delta))
    setTopCount(countOptions[next])
  }

  IpcHandler {
    target: "ismoil.memory"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function cycleDisplay(): void { root.cycleDisplay() }
  }

  Process {
    id: memProc
    command: [
      "awk", "-F", "[: ]+",
      "/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SReclaimable|Shmem|SwapTotal|SwapFree):/ { printf \"%s\\t%s\\n\", $1, $2 }",
      "/proc/meminfo"
    ]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyMeminfo(text) }
  }

  // Resident memory grouped by executable name (basename of argv[0]), so an
  // app with many helper processes shows up once with its real footprint and
  // runtimes that rename their threads (node -> "MainThread") stay readable.
  Process {
    id: psProc
    command: [
      "sh", "-c",
      "ps -eo rss=,args= | awk '$1 > 0 { r = $1; n = $2; sub(/.*\\//, \"\", n); sub(/:$/, \"\", n); rss[n] += r; c[n]++ } END { for (k in rss) printf \"%d\\t%d\\t%s\\n\", rss[k], c[k], k }' | sort -rn | head -n " + root.topCount
    ]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyProcesses(text) }
  }

  Process {
    id: killProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyKill(text) }
  }

  Timer {
    interval: root.opened ? 1500 : root.pollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showText ? root.icon + " " + Model.barLabel(root.display, root.mem) : root.icon
    active: root.level !== "ok"
    activeColor: root.levelBase
    slotSize: root.showText ? Math.ceil(button.glyphPaintedWidth) + Style.space(14) : Style.bar.iconSlot
    tooltipText: Model.tooltip(root.mem)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleDisplay()
      else if (b === Qt.MiddleButton) root.openMonitor()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.openMonitor()
      onCloseRequested: root.escapePressed()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "m") root.cycleDisplay()
        else if (t === "b") root.openMonitor()
        else if (t === "+" || t === "=") root.stepTopCount(1)
        else if (t === "-") root.stepTopCount(-1)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: icon · title/status · used percent ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.icon
            color: root.fillText
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Memory"
              color: root.popupText
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.mem.ready
                ? (Model.formatKb(root.mem.availKb) + " free of " + Model.formatKb(root.mem.totalKb)).toUpperCase()
                : "READING…"
              color: root.popupDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.mem.ready ? Model.percent(root.mem.usedFraction) + "%" : "—"
            color: root.fillText
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Usage bar: solid = used, faint = cache/buffers ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(root.popupText, 0.12)
          }

          Rectangle {
            anchors.left: track.left
            anchors.verticalCenter: track.verticalCenter
            height: track.height
            radius: track.radius
            color: Util.alpha(root.fillColor, 0.3)
            width: Math.min(track.width, track.width * (root.mem.usedFraction + root.mem.cachedFraction))

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          }

          Rectangle {
            anchors.left: track.left
            anchors.verticalCenter: track.verticalCenter
            height: track.height
            radius: track.radius
            color: root.fillColor
            width: Math.max(root.mem.ready ? track.height : 0, track.width * root.mem.usedFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }
          }
        }

        // ---------- Stats ----------
        Row {
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Used"; value: root.mem.ready ? Model.formatKb(root.mem.usedKb) : "—" }
            InfoPair { label: "Cache"; value: root.mem.ready ? Model.formatKb(root.mem.cachedKb) : "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Available"; value: root.mem.ready ? Model.formatKb(root.mem.availKb) : "—" }
            InfoPair { label: "Total"; value: root.mem.ready ? Model.formatKb(root.mem.totalKb) : "—" }
          }
        }

        // ---------- Swap ----------
        Column {
          visible: root.mem.swapTotalKb > 0
          width: parent.width
          spacing: Style.space(6)

          InfoPair {
            label: "Swap"
            value: Model.formatKb(root.mem.swapUsedKb) + " / " + Model.formatKb(root.mem.swapTotalKb)
          }

          Item {
            width: parent.width
            implicitHeight: Style.space(4)

            Rectangle {
              id: swapTrack
              anchors.fill: parent
              radius: height / 2
              color: Util.alpha(root.popupText, 0.12)
            }

            Rectangle {
              anchors.left: swapTrack.left
              anchors.verticalCenter: swapTrack.verticalCenter
              height: swapTrack.height
              radius: swapTrack.radius
              color: root.popupAccent
              width: swapTrack.width * root.mem.swapFraction

              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }
          }
        }

        // ---------- Top processes ----------
        PanelSeparator { foreground: root.popupText }

        Column {
          id: procList
          width: parent.width
          spacing: Style.space(3)

          Item {
            width: parent.width
            implicitHeight: Math.max(procHeader.implicitHeight, countPicker.implicitHeight)

            PanelSectionHeader {
              id: procHeader
              text: "TOP PROCESSES"
              foreground: root.popupText
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
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
                  tooltipText: "Show top " + modelData
                  selected: root.topCount === modelData
                  bordered: true
                  foreground: root.popupText
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(2)
                  onClicked: root.setTopCount(modelData)
                }
              }
            }
          }

          Text {
            visible: root.processes.length === 0
            textFormat: Text.PlainText
            text: "Collecting…"
            color: root.popupText
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.processes

            // Normal:   name ·············· share  size   (hover: share -> ×)
            // Confirm:  name ········· [Cancel] [Stop]
            // Result:   name ········ status text  [Force]
            delegate: Item {
              id: procItem
              required property var modelData
              readonly property var killState: root.killStates[modelData.name]
              readonly property string killPhase: killState ? killState.phase : ""
              readonly property string killText: Model.killStatus(killState)
              readonly property bool confirming: killPhase === "armed"
              readonly property bool refused: killPhase === "denied" || killPhase === "partial" || killPhase === "failed"
              readonly property real lineHeight: Math.ceil(sizeMetrics.height)
              width: procList.width
              // Fixed height so the confirm buttons never make the list jump.
              implicitHeight: lineHeight + Style.space(8)

              HoverHandler { id: procHover }

              // Hover / confirm tint behind the whole row.
              Rectangle {
                anchors.fill: parent
                radius: Math.min(4, Style.cornerRadius)
                color: procItem.confirming || procItem.refused
                  ? Util.alpha(root.popupUrgent, 0.14)
                  : Util.alpha(root.popupText, procHover.hovered ? 0.06 : 0)
                Behavior on color { ColorAnimation { duration: 120 } }
              }

              // Share of total RAM, painted behind the row.
              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: root.mem.totalKb > 0 ? parent.width * Math.min(1, modelData.rssKb / root.mem.totalKb) : 0
                radius: Math.min(4, Style.cornerRadius)
                color: Util.alpha(root.popupAccent, 0.16)

                Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.right: procTail.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.name + (modelData.count > 1 ? "  ×" + modelData.count : "")
                color: root.popupText
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Row {
                id: procTail
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                // --- Normal: share column doubles as the kill button on hover ---
                Item {
                  visible: procItem.killPhase === ""
                  width: shareMetrics.width
                  height: procItem.lineHeight

                  Text {
                    anchors.fill: parent
                    visible: !procHover.hovered
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    textFormat: Text.PlainText
                    text: Model.share(modelData.rssKb, root.mem.totalKb)
                    color: root.popupText
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Button {
                    anchors.fill: parent
                    visible: procHover.hovered
                    iconText: "󰅖"
                    iconSize: Style.font.body
                    tooltipText: "Stop " + modelData.name
                      + (modelData.count > 1 ? " (" + modelData.count + " processes)" : "")
                    foreground: root.popupUrgent
                    fontFamily: root.fontFamily
                    horizontalPadding: 0
                    verticalPadding: 0
                    onClicked: root.armKill(modelData.name)
                  }
                }

                Text {
                  visible: procItem.killPhase === ""
                  width: sizeMetrics.width
                  height: procItem.lineHeight
                  horizontalAlignment: Text.AlignRight
                  verticalAlignment: Text.AlignVCenter
                  textFormat: Text.PlainText
                  text: Model.formatKb(modelData.rssKb)
                  color: root.popupText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // --- Confirm ---
                Button {
                  visible: procItem.confirming
                  height: procItem.lineHeight + Style.space(2)
                  text: "Cancel"
                  fontSize: Style.font.caption
                  foreground: root.popupText
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.space(6)
                  verticalPadding: 0
                  onClicked: root.cancelKill(modelData.name)
                }

                Button {
                  visible: procItem.confirming
                  height: procItem.lineHeight + Style.space(2)
                  text: modelData.count > 1 ? "Stop " + modelData.count : "Stop"
                  tooltipText: "SIGTERM to every " + modelData.name + " process"
                  fontSize: Style.font.caption
                  foreground: root.popupUrgent
                  fontFamily: root.fontFamily
                  bordered: true
                  horizontalPadding: Style.space(6)
                  verticalPadding: 0
                  onClicked: root.sendSignal(modelData.name, "TERM")
                }

                // --- Result / progress ---
                Text {
                  visible: procItem.killText !== ""
                  height: procItem.lineHeight
                  verticalAlignment: Text.AlignVCenter
                  textFormat: Text.PlainText
                  text: procItem.killText
                  color: procItem.refused ? root.popupUrgent : root.popupText
                  opacity: procItem.refused ? 1 : 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Button {
                  visible: procItem.killPhase === "stuck"
                  height: procItem.lineHeight + Style.space(2)
                  text: "Force"
                  tooltipText: "SIGKILL: cannot be ignored, unsaved data is lost"
                  fontSize: Style.font.caption
                  foreground: root.popupUrgent
                  fontFamily: root.fontFamily
                  bordered: true
                  horizontalPadding: Style.space(6)
                  verticalPadding: 0
                  onClicked: root.sendSignal(modelData.name, "KILL")
                }
              }
            }
          }
        }

        // Sum of the rows above, so the list explains how much of RAM it covers.
        // RSS counts shared pages once per process, so this is an upper bound.
        InfoPair {
          visible: root.processes.length > 0 && root.mem.ready
          label: "Listed " + root.processes.length + " programs"
          value: Model.formatKb(root.listedKb) + " · " + Model.share(root.listedKb, root.mem.totalKb).trim() + " of RAM"
        }

        // ---------- Actions ----------
        PanelSeparator { foreground: root.popupText }

        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing) / 2
          // Both buttons take the taller of the two, so an icon on one side
          // never leaves the other button shorter.
          readonly property real buttonHeight: Math.max(btopButton.implicitHeight, modeButton.implicitHeight)

          Button {
            id: btopButton
            width: actionRow.cellWidth
            height: actionRow.buttonHeight
            iconText: "󰆍"
            iconSize: Style.font.title
            text: "Open btop"
            fontSize: Style.font.bodySmall
            foreground: root.popupText
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.openMonitor()
          }

          Button {
            id: modeButton
            width: actionRow.cellWidth
            height: actionRow.buttonHeight
            iconText: "󰈈"
            iconSize: Style.font.title
            text: "Bar: " + Model.modeLabel(root.display)
            fontSize: Style.font.bodySmall
            foreground: root.popupText
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.cycleDisplay()
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.popupText
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.popupText
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
