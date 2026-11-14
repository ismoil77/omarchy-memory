.pragma library
.import "kit/I18n.js" as I18n
.import "Strings.js" as Strings

// Pure logic of the Memory widget: reading the kernel's files, the verdict,
// the texts. No QML here, so tests run it in plain Node.

// ---------- config and words ----------

// `raw` = { language, locale }; `lang` is what every text function reads.
function config(raw) {
  return { lang: I18n.resolve(raw && raw.language, raw && raw.locale, Strings.langs, { "русский": "ru", english: "en" }) }
}

function tr(cfg, key, params) {
  return I18n.t(Strings.tables, cfg.lang, key, params)
}

function count(cfg, key, n) {
  return I18n.count(Strings.tables, cfg.lang, key, n)
}

// "3.0 GB" / "512 MB" in the chosen language.
function formatKb(cfg, kb) {
  var n = Math.max(0, Number(kb) || 0)
  if (n >= 1024 * 1024) return I18n.num(cfg.lang, n / 1024 / 1024, 1) + " " + tr(cfg, "unitGB")
  if (n >= 1024) return Math.round(n / 1024) + " " + tr(cfg, "unitMB")
  return Math.round(n) + " " + tr(cfg, "unitKB")
}

// Compact form for the bar: "3.0G" / "512M" (units every language reads).
function shortKb(kb) {
  var n = Math.max(0, Number(kb) || 0)
  if (n >= 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + "G"
  if (n >= 1024) return Math.round(n / 1024) + "M"
  return Math.round(n) + "k"
}

function percent(fraction) {
  return Math.round((Number(fraction) || 0) * 100) + "%"
}

// ---------- the kernel's files ----------

// /proc/meminfo ("MemTotal:   16000000 kB") -> { MemTotal: 16000000, ... } in kB.
function parseMeminfo(text) {
  var out = {}
  var re = /^(\w+(?:\(\w+\))?):\s+(\d+)/gm
  var m
  while ((m = re.exec(String(text || ""))) !== null) out[m[1]] = Number(m[2])
  return out
}

// A PSI file (/proc/pressure/memory or a cgroup's memory.pressure):
// { some, full } = the avg10 percentages; null when unreadable.
function parsePressure(text) {
  var out = {}
  var re = /^(some|full)\s+avg10=([\d.]+)/gm
  var m
  while ((m = re.exec(String(text || ""))) !== null) out[m[1]] = Number(m[2])
  if (out.some === undefined && out.full === undefined) return null
  return { some: out.some || 0, full: out.full || 0 }
}

// /sys/block/zramN/mm_stat: orig_data_size compr_data_size mem_used_total ... (bytes)
// -> { origKb, comprKb, usedKb }; null without zram.
function parseZram(text) {
  var parts = String(text || "").trim().split(/\s+/)
  if (parts.length < 3) return null
  var orig = Number(parts[0]), compr = Number(parts[1]), used = Number(parts[2])
  if (!isFinite(orig) || !isFinite(used)) return null
  return { origKb: orig / 1024, comprKb: compr / 1024, usedKb: used / 1024 }
}

// /proc/swaps -> [{ name, kind: "zram"|"file"|"partition", sizeKb, usedKb, priority }]
function parseSwaps(text) {
  var lines = String(text || "").split("\n").slice(1)
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var p = lines[i].trim().split(/\s+/)
    if (p.length < 5) continue
    out.push({
      name: p[0],
      kind: /\/zram\d+$/.test(p[0]) ? "zram" : p[1],
      sizeKb: Number(p[2]) || 0,
      usedKb: Number(p[3]) || 0,
      priority: Number(p[4]) || 0
    })
  }
  return out
}

// /proc/vmstat -> { pswpin, pswpout } (pages since boot).
function parseVmstat(text) {
  var out = { pswpin: 0, pswpout: 0 }
  var re = /^(pswpin|pswpout)\s+(\d+)/gm
  var m
  while ((m = re.exec(String(text || ""))) !== null) out[m[1]] = Number(m[2])
  return out
}

// `oomctl` output -> { swapLimit, pressureLimit, durationSec } as fractions;
// the app.slice's own pressure limit wins over the default. null without oomd.
function parseOomctl(text) {
  var s = String(text || "")
  function pct(re) { var m = s.match(re); return m ? Number(m[1]) / 100 : NaN }
  var swap = pct(/Swap Used Limit:\s*([\d.]+)%/)
  var pressure = pct(/Default Memory Pressure Limit:\s*([\d.]+)%/)
  var app = s.match(/app\.slice\n\s*Memory Pressure Limit:\s*([\d.]+)%(?:\n\s*Memory Pressure Duration:\s*(\d+)s)?/)
  var dur = s.match(/Default Memory Pressure Duration:\s*(\d+)s/)
  if (!isFinite(swap) && !isFinite(pressure)) return null
  return {
    swapLimit: isFinite(swap) ? swap : 0.9,
    pressureLimit: app ? Number(app[1]) / 100 : isFinite(pressure) ? pressure : 0.6,
    durationSec: app && app[2] ? Number(app[2]) : dur ? Number(dur[1]) : 30
  }
}

// ---------- what the widget shows ----------

// RAM split the way a person thinks about it. "Used" is total minus
// MemAvailable (as `free` counts it); the split below adds up to total:
// programs + cache (files the kernel can drop) + zram (compressed swap held
// in RAM) + free.
function summarize(info, zram) {
  var m = info || {}
  var total = m.MemTotal || 0
  var avail = m.MemAvailable !== undefined ? m.MemAvailable : (m.MemFree || 0)
  var free = m.MemFree || 0
  var cache = Math.max(0, (m.Cached || 0) + (m.Buffers || 0) + (m.SReclaimable || 0) - (m.Shmem || 0))
  var zramKb = zram ? Math.min(zram.usedKb, Math.max(0, total - free - cache)) : 0
  var swapTotal = m.SwapTotal || 0
  var swapUsed = Math.max(0, swapTotal - (m.SwapFree || 0))
  return {
    ready: total > 0,
    totalKb: total,
    availKb: avail,
    usedKb: Math.max(0, total - avail),
    freeKb: free,
    cacheKb: cache,
    zramKb: zramKb,
    programsKb: Math.max(0, total - free - cache - zramKb),
    swapTotalKb: swapTotal,
    swapUsedKb: swapUsed,
    usedFraction: total > 0 ? Math.min(1, Math.max(0, total - avail) / total) : 0,
    availFraction: total > 0 ? Math.min(1, avail / total) : 0,
    swapFraction: swapTotal > 0 ? Math.min(1, swapUsed / swapTotal) : 0
  }
}

// Swap traffic between two /proc/vmstat readings, kB per second (4 kB pages).
function swapRate(prev, cur, seconds) {
  if (!prev || !cur || !(seconds > 0)) return { inKb: 0, outKb: 0 }
  return {
    inKb: Math.max(0, cur.pswpin - prev.pswpin) * 4 / seconds,
    outKb: Math.max(0, cur.pswpout - prev.pswpout) * 4 / seconds
  }
}

// calm / tight / danger, and why. "90% used" is normal on Linux (cache);
// what hurts is programs waiting for memory (pressure), swap running out, or
// no memory left to hand out. With oomd the lines are its own kill lines.
//   pressure: full avg10 percent; oom: parseOomctl() or null
function verdict(mem, pressure, oom) {
  if (!mem || !mem.ready) return { level: "calm", why: "" }
  var pLimit = (oom ? oom.pressureLimit : 0.6) * 100
  var sLimit = oom ? oom.swapLimit : 0.9
  var p = pressure ? pressure.full : 0
  var swap = mem.swapTotalKb > 0 ? mem.swapFraction : 0
  if (p >= pLimit * 0.6) return { level: "danger", why: "whyPressure" }
  if (mem.swapTotalKb > 0 && swap >= sLimit - 0.05) return { level: "danger", why: "whySwap" }
  if (mem.availFraction < 0.05) return { level: "danger", why: "whyRam" }
  if (p >= pLimit * 0.2) return { level: "tight", why: "whyPressure" }
  if (mem.swapTotalKb > 0 && swap >= sLimit * 0.75) return { level: "tight", why: "whySwap" }
  if (mem.availFraction < 0.12) return { level: "tight", why: "whyRam" }
  return { level: "calm", why: "" }
}

// The kit's level names.
function kitLevel(level) {
  return level === "danger" ? "bad" : level === "tight" ? "warn" : "good"
}

// A ring buffer as an array: `value` appended, oldest dropped past `cap`.
function pushHistory(list, value, cap) {
  var next = (Array.isArray(list) ? list : []).concat([value])
  return next.length > cap ? next.slice(next.length - cap) : next
}

var MODES = ["free", "used", "percent", "icon"]
var MODE_KEYS = { free: "modeFree", used: "modeUsed", percent: "modePercent", icon: "modeIcon" }

function barLabel(mode, mem) {
  if (mode === "icon") return ""
  if (!mem || !mem.ready) return "…"
  if (mode === "used") return shortKb(mem.usedKb)
  if (mode === "percent") return percent(mem.usedFraction)
  return shortKb(mem.availKb)
}

function nextMode(mode) {
  var idx = MODES.indexOf(mode)
  return MODES[(idx + 1) % MODES.length]
}

function modeLabel(cfg, mode) {
  return tr(cfg, MODE_KEYS[mode] || "modeFree")
}

function tooltip(cfg, mem, state) {
  if (!mem || !mem.ready) return tr(cfg, "title")
  var text = tr(cfg, "tipBar", { used: formatKb(cfg, mem.usedKb), total: formatKb(cfg, mem.totalKb), pct: percent(mem.usedFraction), free: formatKb(cfg, mem.availKb) })
  if (mem.swapTotalKb > 0) text += tr(cfg, "tipSwap", { used: formatKb(cfg, mem.swapUsedKb), total: formatKb(cfg, mem.swapTotalKb) })
  if (state && state.level !== "calm") text += tr(cfg, "tipState", { state: tr(cfg, state.level) + ": " + tr(cfg, state.why) })
  return text
}

// ---------- apps ----------

// apps.py prints {"apps": [{ name, rss, swap, count }]} (kB), largest first.
function parseApps(raw) {
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!data || !Array.isArray(data.apps)) return null
  var out = []
  for (var i = 0; i < data.apps.length; i++) {
    var a = data.apps[i]
    if (!a || typeof a.name !== "string" || !(Number(a.rss) > 0)) continue
    out.push({ name: a.name, rssKb: Number(a.rss), swapKb: Math.max(0, Number(a.swap) || 0), count: Math.max(1, Number(a.count) || 1) })
  }
  return out
}

function sumRss(list) {
  var s = 0
  for (var i = 0; i < (list || []).length; i++) s += Number(list[i].rssKb) || 0
  return s
}

// Share of total RAM as "13%".
function share(kb, totalKb) {
  var t = Number(totalKb) || 0
  return t > 0 ? Math.round((Number(kb) || 0) / t * 100) + "%" : ""
}

// How fast an app's memory grows, kB per minute, from the oldest snapshot
// ({ at: ms, rss: { name: kB } }) at least 45 s old; 0 when unknown.
function growthPerMinute(name, nowKb, snapshots, nowMs) {
  for (var i = 0; i < (snapshots || []).length; i++) {
    var s = snapshots[i]
    var age = (nowMs - s.at) / 60000
    if (age < 0.75) break
    if (s.rss[name] === undefined) continue
    return (nowKb - s.rss[name]) / age
  }
  return 0
}

// Growing = at least 30 MB a minute and 50 MB in total.
function isGrowing(name, nowKb, snapshots, nowMs) {
  var rate = growthPerMinute(name, nowKb, snapshots, nowMs)
  if (rate < 30 * 1024) return false
  for (var i = 0; i < (snapshots || []).length; i++)
    if (snapshots[i].rss[name] !== undefined) return nowKb - snapshots[i].rss[name] >= 50 * 1024
  return false
}

// breakdown.sh lines: "rss_kb\tcount\tlabel\tpids" -> { rssKb, count, name, pids: [..] }
function parseBreakdown(raw) {
  var list = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 4) continue
    var rss = Number(parts[0])
    var pids = parts[3].trim().split(" ").filter(function(p) { return /^[0-9]+$/.test(p) })
    if (!isFinite(rss) || pids.length === 0) continue
    list.push({ rssKb: rss, count: Number(parts[1]) || pids.length, name: parts[2], pids: pids })
  }
  return list
}

// ---------- stopping a row ----------

// One line from kill-group.sh: "name\tsignalled\tdenied\towners".
function parseKillResult(raw) {
  var line = String(raw || "").split("\n")[0]
  var parts = line.split("\t")
  if (parts.length < 3 || !parts[0]) return null
  return { name: parts[0], signalled: Number(parts[1]) || 0, denied: Number(parts[2]) || 0, owners: String(parts[3] || "").trim() }
}

// Who the kernel refused on behalf of: root-owned means a system process.
function ownerLabel(cfg, owners) {
  if (!owners) return tr(cfg, "ownerOther")
  if (owners.split(" ").indexOf("root") >= 0) return tr(cfg, "ownerSystem", { owners: owners })
  return owners
}

// Row status for a stop in progress; "" means show the normal columns.
function killStatus(cfg, state) {
  if (!state) return ""
  if (state.phase === "sending" || state.phase === "sent") return tr(cfg, "stopping")
  if (state.phase === "stuck") return tr(cfg, "stillRunning")
  if (state.phase === "failed") return tr(cfg, "unableToStop")
  if (state.phase === "gone") return tr(cfg, "notRunning")
  if (state.phase === "denied") return tr(cfg, "notAllowed", { owner: ownerLabel(cfg, state.owners) })
  if (state.phase === "partial") return tr(cfg, "partial", { n: state.signalled, denied: state.denied, owner: ownerLabel(cfg, state.owners) })
  return ""
}

// Pressure (avg10 percent) for a tile: "0%", "<1%" for a trace, else whole percent.
function pressureText(p) {
  var n = Number(p) || 0
  if (n <= 0) return "0%"
  return n < 1 ? "<1%" : Math.round(n) + "%"
}

// zram's squeeze: original data / RAM it takes, "3,4×".
function ratioText(cfg, zram) {
  return zram && zram.usedKb > 0 ? I18n.num(cfg.lang, zram.origKb / zram.usedKb, 1) + "×" : "—"
}

// The desktop entry for a process name, from plain entries
// [{ id, name, icon, wmClass, exec, cmd }] (cmd = the whole command line): an exact id, window class or program
// name first, then a whole word of one ("chrome" in "google-chrome") for
// names of 4+ letters. null when nothing fits.
function matchApp(name, entries) {
  var want = String(name || "").toLowerCase().replace(/(-bin|\.bin|-wrapped)$/, "")
  if (want === "") return null
  // Web apps are launchers for a browser: they never own a process name.
  var list = (entries || []).filter(function(e) {
    return !/--app(-id)?=|launch-webapp|webapp-handler/.test(String(e.cmd || "")) && !/^crx_|^chrome-.*__/.test(String(e.wmClass || ""))
  })
  function keys(e) {
    var exec = String(e.exec || "").toLowerCase().replace(/.*\//, "")
    return [String(e.id || "").toLowerCase().replace(/\.desktop$/, ""), String(e.wmClass || "").toLowerCase(), exec]
  }
  for (var i = 0; i < list.length; i++)
    if (keys(list[i]).indexOf(want) >= 0) return list[i]
  if (want.length < 4) return null
  for (var j = 0; j < list.length; j++) {
    var k = keys(list[j])
    for (var n = 0; n < k.length; n++)
      if (k[n].split(/[-_.\s]+/).indexOf(want) >= 0) return list[j]
  }
  return null
}

// `next` in the order of `prev`: rows the pointer is near stay put while
// their numbers update. Rows that are gone drop out; new ones go last.
function keepOrder(prev, next) {
  var byName = {}
  for (var i = 0; i < next.length; i++) byName[next[i].name] = next[i]
  var out = []
  for (var j = 0; j < (prev || []).length; j++) {
    var row = byName[prev[j].name]
    if (row) { out.push(row); delete byName[prev[j].name] }
  }
  for (var k = 0; k < next.length; k++) if (byName[next[k].name]) out.push(next[k])
  return out
}
