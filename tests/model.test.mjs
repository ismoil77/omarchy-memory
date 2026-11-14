import test from "node:test"
import assert from "node:assert/strict"
import { Model as load } from "./loader.mjs"

const M = load()
const GB = 1024 * 1024
// The library runs in a vm context: compare plain copies, not cross-realm objects.
const plain = (x) => JSON.parse(JSON.stringify(x))
const en = M.config({ language: "en" })
const ru = M.config({ language: "ru" })

const MEMINFO = `MemTotal:       16000000 kB
MemFree:         2000000 kB
MemAvailable:    5000000 kB
Buffers:          100000 kB
Cached:          3000000 kB
SwapCached:       200000 kB
Shmem:            500000 kB
SReclaimable:     400000 kB
SwapTotal:      32000000 kB
SwapFree:       24000000 kB
`
const OOMCTL = `Dry Run: no
Swap Used Limit: 90.00%
Default Memory Pressure Limit: 60.00%
Default Memory Pressure Duration: 30s
System Context:
Swap Monitored CGroups:
	Path: /user.slice/user-1000.slice/user@1000.service/app.slice
		Swap Usage: 0B
Memory Pressure Monitored CGroups:
	Path: /user.slice/user-1000.slice/user@1000.service/app.slice
		Memory Pressure Limit: 50.00%
		Memory Pressure Duration: 20s
		Pressure: Avg10: 0.00, Avg60: 0.20, Avg300: 0.48, Total: 5min 1s
`

test("parseMeminfo reads /proc/meminfo as kB", () => {
  const m = M.parseMeminfo(MEMINFO + "Hugepagesize:       2048 kB\nHugePages_Total:       0\n")
  assert.equal(m.MemTotal, 16000000)
  assert.equal(m.Shmem, 500000)
  assert.equal(m.HugePages_Total, 0)
  assert.deepEqual(plain(M.parseMeminfo("")), {})
})

test("summarize: the split adds up to total, used follows MemAvailable", () => {
  const zram = { origKb: 7 * GB, comprKb: 2 * GB, usedKb: 2.2 * GB }
  const s = M.summarize(M.parseMeminfo(MEMINFO), zram)
  assert.equal(s.ready, true)
  assert.equal(s.usedKb, 11000000)
  assert.equal(s.cacheKb, 3000000)                 // Cached + Buffers + SReclaimable - Shmem
  assert.equal(s.programsKb + s.cacheKb + s.zramKb + s.freeKb, s.totalKb)
  assert.equal(s.swapFraction, 0.25)
  // Without zram, its share stays with programs.
  const n = M.summarize(M.parseMeminfo(MEMINFO), null)
  assert.equal(n.zramKb, 0)
  assert.equal(n.programsKb, 16000000 - 2000000 - 3000000)
  assert.equal(M.summarize({}).ready, false)
})

test("pressure, zram, swaps and vmstat files", () => {
  const p = M.parsePressure("some avg10=1.50 avg60=0.22 avg300=0.49 total=1\nfull avg10=0.75 avg60=0 avg300=0 total=2\n")
  assert.deepEqual(plain(p), { some: 1.5, full: 0.75 })
  assert.equal(M.parsePressure("garbage"), null)
  const z = M.parseZram("7015002112 2083287587 2162610176 0 2214592512 1 2 3 4\n")
  assert.equal(Math.round(z.usedKb), 2111924)
  assert.equal(M.parseZram(""), null)
  const swaps = M.parseSwaps("Filename\tType\tSize\tUsed\tPriority\n/swap/swapfile  file  15983020  140092  0\n/dev/zram0  partition  15977468  7198200  100\n")
  assert.deepEqual(plain(swaps.map(s => s.kind)), ["file", "zram"])
  assert.equal(swaps[1].usedKb, 7198200)
  assert.deepEqual(plain(M.parseVmstat("nr_free 1\npswpin 100\npswpout 250\n")), { pswpin: 100, pswpout: 250 })
})

test("oomctl: the app.slice limit wins over the default", () => {
  const o = M.parseOomctl(OOMCTL)
  assert.deepEqual(plain(o), { swapLimit: 0.9, pressureLimit: 0.5, durationSec: 20 })
  const d = M.parseOomctl("Swap Used Limit: 80.00%\nDefault Memory Pressure Limit: 60.00%\nDefault Memory Pressure Duration: 30s\n")
  assert.deepEqual(plain(d), { swapLimit: 0.8, pressureLimit: 0.6, durationSec: 30 })
  assert.equal(M.parseOomctl("oomctl: command not found"), null)
})

test("swap rate is kB/s from 4 kB pages and never negative", () => {
  const r = M.swapRate({ pswpin: 100, pswpout: 100 }, { pswpin: 600, pswpout: 50 }, 2)
  assert.deepEqual(plain(r), { inKb: 1000, outKb: 0 })
  assert.deepEqual(plain(M.swapRate(null, { pswpin: 1, pswpout: 1 }, 2)), { inKb: 0, outKb: 0 })
  assert.deepEqual(plain(M.swapRate({ pswpin: 1, pswpout: 1 }, { pswpin: 9, pswpout: 9 }, 0)), { inKb: 0, outKb: 0 })
})

test("verdict: pressure and swap against oomd's lines, not used percent", () => {
  const oom = { swapLimit: 0.9, pressureLimit: 0.5, durationSec: 20 }
  const mem = (avail, swapUsed) => M.summarize({ MemTotal: 100, MemAvailable: avail, MemFree: avail, SwapTotal: 100, SwapFree: 100 - swapUsed })
  // 90% used but nothing waits: calm.
  assert.equal(M.verdict(mem(15, 10), { full: 0 }, oom).level, "calm")
  assert.deepEqual(plain(M.verdict(mem(50, 10), { full: 12 }, oom)), { level: "tight", why: "whyPressure" })
  assert.deepEqual(plain(M.verdict(mem(50, 10), { full: 31 }, oom)), { level: "danger", why: "whyPressure" })
  assert.deepEqual(plain(M.verdict(mem(50, 70), { full: 0 }, oom)), { level: "tight", why: "whySwap" })
  assert.deepEqual(plain(M.verdict(mem(50, 86), { full: 0 }, oom)), { level: "danger", why: "whySwap" })
  assert.deepEqual(plain(M.verdict(mem(10, 0), null, null)), { level: "tight", why: "whyRam" })
  assert.deepEqual(plain(M.verdict(mem(3, 0), null, null)), { level: "danger", why: "whyRam" })
  assert.equal(M.verdict(M.summarize({}), null, null).level, "calm")
  assert.equal(M.kitLevel("danger"), "bad")
  assert.equal(M.kitLevel("tight"), "warn")
  assert.equal(M.kitLevel("calm"), "good")
})

test("history keeps the last `cap` values", () => {
  let h = []
  for (let i = 0; i < 5; i++) h = M.pushHistory(h, i, 3)
  assert.deepEqual(plain(h), [2, 3, 4])
})

test("words and sizes in both languages", () => {
  assert.equal(M.formatKb(en, 3.25 * GB), "3.3 GB")
  assert.equal(M.formatKb(ru, 3.25 * GB), "3,3 ГБ")
  assert.equal(M.formatKb(ru, 512 * 1024), "512 МБ")
  assert.equal(M.shortKb(1536 * 1024), "1.5G")
  assert.equal(M.pressureText(0), "0%")
  assert.equal(M.pressureText(0.3), "<1%")
  assert.equal(M.pressureText(12.6), "13%")
  assert.equal(M.ratioText(ru, { origKb: 7, usedKb: 2 }), "3,5×")
  assert.equal(M.ratioText(en, null), "—")
  const mem = M.summarize(M.parseMeminfo(MEMINFO))
  assert.equal(M.barLabel("percent", mem), "69%")
  assert.equal(M.barLabel("icon", mem), "")
  assert.equal(M.nextMode("icon"), "free")
  assert.equal(M.modeLabel(ru, "used"), "Занято")
  assert.match(M.tooltip(ru, mem, { level: "tight", why: "whySwap" }), /тесно: swap почти полон$/)
})

test("apps: parse, growth and a stable order under the pointer", () => {
  const apps = M.parseApps('{"apps":[{"name":"chrome","rss":2048,"swap":10,"count":3},{"name":"bad","rss":0},{"rss":5}]}')
  assert.deepEqual(plain(apps), [{ name: "chrome", rssKb: 2048, swapKb: 10, count: 3 }])
  assert.equal(M.parseApps("nope"), null)
  const now = 1_000_000
  const snaps = [{ at: now - 120000, rss: { a: 100 * 1024 } }, { at: now - 10000, rss: { a: 190 * 1024 } }]
  assert.equal(M.isGrowing("a", 200 * 1024, snaps, now), true)     // +100 MB in 2 min
  assert.equal(M.isGrowing("a", 120 * 1024, snaps, now), false)
  assert.equal(M.isGrowing("b", 900 * 1024, snaps, now), false)
  const prev = [{ name: "a" }, { name: "b" }, { name: "c" }]
  const next = [{ name: "c", rssKb: 3 }, { name: "d", rssKb: 2 }, { name: "a", rssKb: 1 }]
  assert.deepEqual(plain(M.keepOrder(prev, next).map(r => r.name)), ["a", "c", "d"])
})

test("matchApp: exact names first, web apps never, short names only exactly", () => {
  const entries = [
    { id: "chrome-maps.google.com__-Default", name: "Google Maps", wmClass: "chrome-maps.google.com__-Default", exec: "/opt/google/chrome/chrome", cmd: "/opt/google/chrome/chrome --app=https://maps.google.com" },
    { id: "google-chrome", name: "Google Chrome", wmClass: "", exec: "/usr/bin/google-chrome-stable", cmd: "/usr/bin/google-chrome-stable %U" },
    { id: "com.anthropic.Claude", name: "Claude", wmClass: "Claude", exec: "/usr/bin/claude-desktop", cmd: "/usr/bin/claude-desktop" },
    { id: "php-manual", name: "PHP manual", wmClass: "", exec: "/usr/bin/xdg-open", cmd: "" }
  ]
  assert.equal(M.matchApp("chrome", entries).name, "Google Chrome")
  assert.equal(M.matchApp("claude-desktop", entries).name, "Claude")
  assert.equal(M.matchApp("claude", entries).name, "Claude")
  assert.equal(M.matchApp("php", entries), null)
  assert.equal(M.matchApp("", entries), null)
})

test("stop states and breakdown lines", () => {
  assert.equal(M.parseKillResult("node\t2\t1\troot").owners, "root")
  assert.equal(M.parseKillResult(""), null)
  assert.equal(M.killStatus(en, { phase: "denied", owners: "root" }), "Not allowed · system (root)")
  assert.equal(M.killStatus(ru, { phase: "partial", signalled: 2, denied: 1, owners: "bob" }), "Остановлено 2 · 1 без прав, bob")
  assert.equal(M.killStatus(en, null), "")
  const b = M.parseBreakdown("719000\t3\tgeounit\t11 12 13\n5\t1\tjunk\tnope\n")
  assert.deepEqual(plain(b), [{ rssKb: 719000, count: 3, name: "geounit", pids: ["11", "12", "13"] }])
})

test("+ / - walk the presets from any count", () => {
  assert.equal(M.stepPreset([5, 10, 15], 12, 1), 15)
  assert.equal(M.stepPreset([5, 10, 15], 12, -1), 10)
  assert.equal(M.stepPreset([5, 10, 15], 15, 1), 15)
  assert.equal(M.stepPreset([5, 10, 15], 5, -1), 5)
})
