// Pure helpers for the memory widget. No QML here so the file stays
// testable with plain node (`node -e 'require("./Model.js")'`).

// "Key\tvalue" lines (kB) -> { Key: number }
function parseMeminfo(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    var value = Number(lines[i].substring(idx + 1).trim())
    if (isFinite(value)) out[lines[i].substring(0, idx)] = value
  }
  return out
}

// Derive the numbers the UI shows. "Used" follows `free`: total minus
// MemAvailable, so page cache that the kernel can drop counts as free.
function summarize(info) {
  var m = info || {}
  var total = m.MemTotal || 0
  var avail = m.MemAvailable !== undefined ? m.MemAvailable : (m.MemFree || 0)
  var used = Math.max(0, total - avail)
  var cached = (m.Cached || 0) + (m.SReclaimable || 0) + (m.Buffers || 0)
  var swapTotal = m.SwapTotal || 0
  var swapUsed = Math.max(0, swapTotal - (m.SwapFree || 0))
  return {
    ready: total > 0,
    totalKb: total,
    availKb: avail,
    usedKb: used,
    freeKb: m.MemFree || 0,
    cachedKb: cached,
    swapTotalKb: swapTotal,
    swapUsedKb: swapUsed,
    usedFraction: total > 0 ? Math.min(1, used / total) : 0,
    cachedFraction: total > 0 ? Math.min(1, cached / total) : 0,
    swapFraction: swapTotal > 0 ? Math.min(1, swapUsed / swapTotal) : 0
  }
}

// "3.0 GB" / "512 MB"
function formatKb(kb) {
  var n = Number(kb) || 0
  if (n >= 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + " GB"
  if (n >= 1024) return Math.round(n / 1024) + " MB"
  return Math.round(n) + " kB"
}

// Compact form for the bar: "3.0G" / "512M"
function shortKb(kb) {
  var n = Number(kb) || 0
  if (n >= 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + "G"
  if (n >= 1024) return Math.round(n / 1024) + "M"
  return Math.round(n) + "k"
}

function percent(fraction) {
  return Math.round((Number(fraction) || 0) * 100)
}

// Share of total RAM as " 7%" / "13%": padded to three characters so the
// column lines up in a monospace list.
function share(kb, totalKb) {
  var t = Number(totalKb) || 0
  if (t <= 0) return ""
  var p = Math.round((Number(kb) || 0) / t * 100)
  return (p < 10 ? " " : "") + p + "%"
}

function sumRss(list) {
  var s = 0
  var items = Array.isArray(list) ? list : []
  for (var i = 0; i < items.length; i++) s += Number(items[i].rssKb) || 0
  return s
}

// "ok" / "yellow" / "red" for the used fraction. Yellow starts at
// cautionPercent, red at warnPercent; a missing or non-numeric threshold falls
// back to 75 / 90, and caution never sits above warn.
function level(usedFraction, cautionPercent, warnPercent) {
  var warn = Number(warnPercent)
  if (!isFinite(warn)) warn = 90
  var caution = Number(cautionPercent)
  if (!isFinite(caution)) caution = 75
  caution = Math.min(caution, warn)
  var used = (Number(usedFraction) || 0) * 100
  if (used >= warn) return "red"
  if (used >= caution) return "yellow"
  return "ok"
}

var MODES = ["free", "used", "percent", "icon"]

function barLabel(mode, mem) {
  if (mode === "icon") return ""
  if (!mem || !mem.ready) return "…"
  if (mode === "used") return shortKb(mem.usedKb)
  if (mode === "percent") return percent(mem.usedFraction) + "%"
  return shortKb(mem.availKb)
}

function nextMode(mode) {
  var idx = MODES.indexOf(mode)
  return MODES[(idx + 1) % MODES.length]
}

function modeLabel(mode) {
  if (mode === "used") return "Used"
  if (mode === "percent") return "Percent"
  if (mode === "icon") return "Icon only"
  return "Free"
}

// "rss_kb\tcount\tname" lines, already sorted by rss desc.
function parseProcesses(raw) {
  var list = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 3) continue
    var rss = Number(parts[0])
    if (!isFinite(rss) || rss <= 0) continue
    list.push({
      rssKb: rss,
      count: Number(parts[1]) || 1,
      name: parts.slice(2).join("\t").trim()
    })
  }
  return list
}

// One line from kill-group.sh: "name\tsignalled\tdenied\towners".
function parseKillResult(raw) {
  var line = String(raw || "").split("\n")[0]
  var parts = line.split("\t")
  if (parts.length < 3 || !parts[0]) return null
  return {
    name: parts[0],
    signalled: Number(parts[1]) || 0,
    denied: Number(parts[2]) || 0,
    owners: String(parts[3] || "").trim()
  }
}

// Who the kernel refused on behalf of: root-owned means a system process.
function ownerLabel(owners) {
  if (!owners) return "another user"
  if (owners.split(" ").indexOf("root") >= 0) return "system (" + owners + ")"
  return owners
}

// Row status for a kill in progress; "" means show the normal columns.
function killStatus(state) {
  if (!state) return ""
  if (state.phase === "sending" || state.phase === "sent") return "Stopping…"
  if (state.phase === "stuck") return "Still running"
  if (state.phase === "denied") return "Not allowed · " + ownerLabel(state.owners)
  if (state.phase === "partial")
    return "Stopped " + state.signalled + " · " + state.denied + " not allowed, " + ownerLabel(state.owners)
  return ""
}

function tooltip(mem) {
  if (!mem || !mem.ready) return "Memory"
  var text = "RAM " + formatKb(mem.usedKb) + " / " + formatKb(mem.totalKb)
    + " (" + percent(mem.usedFraction) + "%) · " + formatKb(mem.availKb) + " free"
  if (mem.swapTotalKb > 0) text += " · Swap " + formatKb(mem.swapUsedKb) + " / " + formatKb(mem.swapTotalKb)
  return text
}

if (typeof module !== "undefined") {
  module.exports = {
    parseMeminfo: parseMeminfo,
    summarize: summarize,
    formatKb: formatKb,
    shortKb: shortKb,
    percent: percent,
    level: level,
    share: share,
    sumRss: sumRss,
    barLabel: barLabel,
    nextMode: nextMode,
    modeLabel: modeLabel,
    parseProcesses: parseProcesses,
    parseKillResult: parseKillResult,
    ownerLabel: ownerLabel,
    killStatus: killStatus,
    tooltip: tooltip
  }
}
