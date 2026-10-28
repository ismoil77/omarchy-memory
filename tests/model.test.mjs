import test from "node:test"
import assert from "node:assert/strict"
import { Model as load } from "./loader.mjs"

const M = load()
const GB = 1024 * 1024
// The library runs in a vm context: compare plain copies, not cross-realm objects.
const plain = (x) => JSON.parse(JSON.stringify(x))

const meminfo = (o) => M.parseMeminfo(Object.entries(o).map(([k, v]) => `${k}\t${v}`).join("\n"))

test("parseMeminfo reads tab-separated kB lines and skips junk", () => {
  assert.deepEqual({ ...M.parseMeminfo("MemTotal\t100\nMemFree\t40\n") }, { MemTotal: 100, MemFree: 40 })
  assert.deepEqual({ ...M.parseMeminfo("garbage\nNoTab 5\n\t7\nA\tx\n") }, {})
  assert.deepEqual({ ...M.parseMeminfo(undefined) }, {})
})

test("summarize: used follows `free` (total minus available)", () => {
  const s = M.summarize(meminfo({ MemTotal: 16 * GB, MemAvailable: 4 * GB, MemFree: GB, Cached: 2 * GB, SReclaimable: GB / 2, Buffers: GB / 2, SwapTotal: 8 * GB, SwapFree: 6 * GB }))
  assert.equal(s.ready, true)
  assert.equal(s.usedKb, 12 * GB)
  assert.equal(s.usedFraction, 0.75)
  assert.equal(s.cachedKb, 3 * GB)
  assert.equal(s.swapUsedKb, 2 * GB)
  assert.equal(s.swapFraction, 0.25)
})

test("summarize: no data is not ready, no swap is zero, fractions are clamped", () => {
  assert.equal(M.summarize({}).ready, false)
  assert.equal(M.summarize(undefined).usedFraction, 0)
  assert.equal(M.summarize({ MemTotal: 100, MemAvailable: 20 }).swapFraction, 0)
  assert.equal(M.summarize({ MemTotal: 100, MemAvailable: 0, Cached: 500 }).cachedFraction, 1)
  assert.equal(M.summarize({ MemTotal: 100, MemAvailable: 500 }).usedKb, 0)
  // Without MemAvailable (old kernels) MemFree stands in.
  assert.equal(M.summarize({ MemTotal: 100, MemFree: 30 }).usedKb, 70)
})

test("level: ok below caution, yellow from caution, red from warn", () => {
  assert.equal(M.level(0.5, 75, 90), "ok")
  assert.equal(M.level(0.7499, 75, 90), "ok")
  assert.equal(M.level(0.75, 75, 90), "yellow")
  assert.equal(M.level(0.8999, 75, 90), "yellow")
  assert.equal(M.level(0.9, 75, 90), "red")
  assert.equal(M.level(1, 75, 90), "red")
})

test("level: bad thresholds fall back to 75/90, caution never passes warn", () => {
  assert.equal(M.level(0.8, undefined, undefined), "yellow")
  assert.equal(M.level(0.95, "abc", NaN), "red")
  assert.equal(M.level(0.5, NaN, NaN), "ok")
  // caution above warn is clamped: it goes straight to red, never yellow.
  assert.equal(M.level(0.6, 95, 50), "red")
  assert.equal(M.level(0.4, 95, 50), "ok")
  // A 100 warn line is reachable only when memory is full.
  assert.equal(M.level(0.99, 75, 100), "yellow")
  assert.equal(M.level(NaN, 75, 90), "ok")
})

test("formatKb / shortKb pick the unit", () => {
  assert.equal(M.formatKb(3 * GB), "3.0 GB")
  assert.equal(M.formatKb(512 * 1024), "512 MB")
  assert.equal(M.formatKb(100), "100 kB")
  assert.equal(M.formatKb("x"), "0 kB")
  assert.equal(M.shortKb(1.5 * GB), "1.5G")
  assert.equal(M.shortKb(2048), "2M")
  assert.equal(M.shortKb(10), "10k")
})

test("percent and share", () => {
  assert.equal(M.percent(0.914), 91)
  assert.equal(M.percent(undefined), 0)
  assert.equal(M.share(70, 1000), " 7%")
  assert.equal(M.share(130, 1000), "13%")
  assert.equal(M.share(5, 0), "")
})

test("bar label per mode, and the mode cycle", () => {
  const mem = M.summarize({ MemTotal: 16 * GB, MemAvailable: 4 * GB })
  assert.equal(M.barLabel("free", mem), "4.0G")
  assert.equal(M.barLabel("used", mem), "12.0G")
  assert.equal(M.barLabel("percent", mem), "75%")
  assert.equal(M.barLabel("icon", mem), "")
  assert.equal(M.barLabel("free", M.summarize({})), "…")
  assert.equal(M.barLabel("nonsense", mem), "4.0G")
  assert.deepEqual(["free", "used", "percent", "icon"].map(M.nextMode), ["used", "percent", "icon", "free"])
  assert.equal(M.nextMode("nonsense"), "free")
  assert.deepEqual(["free", "used", "percent", "icon", "x"].map(m => M.modeLabel(m)), ["Free", "Used", "Percent", "Icon only", "Free"])
})

test("parseProcesses keeps names with tabs, drops bad rows, sumRss adds them", () => {
  const list = M.parseProcesses("2000\t3\tnode\n1000\t1\ta\tb\nbad\t1\tx\n0\t1\tzero\n500\tx\tchrome\nshort\n")
  assert.deepEqual(plain(list.map(p => [p.rssKb, p.count, p.name])), [[2000, 3, "node"], [1000, 1, "a\tb"], [500, 1, "chrome"]])
  assert.equal(M.sumRss(list), 3500)
  assert.equal(M.sumRss(undefined), 0)
  assert.deepEqual(plain(M.parseProcesses("")), [])
})

test("parseKillResult, ownerLabel and killStatus", () => {
  assert.deepEqual({ ...M.parseKillResult("node\t2\t1\troot ismoil\n") }, { name: "node", signalled: 2, denied: 1, owners: "root ismoil" })
  assert.equal(M.parseKillResult(""), null)
  assert.equal(M.parseKillResult("\t1\t0\t"), null)
  assert.equal(M.ownerLabel(""), "another user")
  assert.equal(M.ownerLabel("root"), "system (root)")
  assert.equal(M.ownerLabel("alice"), "alice")
  assert.equal(M.killStatus(null), "")
  assert.equal(M.killStatus({ phase: "armed" }), "")
  assert.equal(M.killStatus({ phase: "sending" }), "Stopping…")
  assert.equal(M.killStatus({ phase: "stuck" }), "Still running")
  assert.equal(M.killStatus({ phase: "failed" }), "Unable to stop")
  assert.equal(M.killStatus({ phase: "gone" }), "Not running")
  assert.equal(M.killStatus({ phase: "denied", owners: "root" }), "Not allowed · system (root)")
  assert.equal(M.killStatus({ phase: "partial", signalled: 2, denied: 1, owners: "bob" }), "Stopped 2 · 1 not allowed, bob")
})

test("tooltip", () => {
  assert.equal(M.tooltip(null), "Memory")
  const mem = M.summarize({ MemTotal: 16 * GB, MemAvailable: 4 * GB, SwapTotal: 8 * GB, SwapFree: 6 * GB })
  assert.equal(M.tooltip(mem), "RAM 12.0 GB / 16.0 GB (75%) · 4.0 GB free · Swap 2.0 GB / 8.0 GB")
})
