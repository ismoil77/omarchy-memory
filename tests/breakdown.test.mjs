import test from "node:test"
import assert from "node:assert/strict"
import { spawn, spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../breakdown.sh")
const wait = (ms) => new Promise(r => setTimeout(r, ms))

test("groups a row's processes by script and project folder", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "membreak-"))
  const proj = path.join(dir, "projA")
  fs.mkdirSync(proj)
  const bin = path.join(dir, "memtest-break")
  // A link to python3, not a copy of `sleep`: see kill-group.test.mjs.
  fs.symlinkSync(spawnSync("which", ["python3"], { encoding: "utf8" }).stdout.trim(), bin)
  const nap = "import time; time.sleep(60)"
  fs.writeFileSync(path.join(proj, "60"), nap) // a real file argument counts as the script
  const kids = [spawn(bin, ["60"], { cwd: proj }), spawn(bin, ["60"], { cwd: proj }), spawn(bin, ["-c", nap], { cwd: dir })]
  await wait(400)
  const rows = spawnSync("sh", [script, "memtest-break"], { encoding: "utf8" }).stdout.trim().split("\n").map(l => l.split("\t"))
  kids.forEach(k => k.kill())
  fs.rmSync(dir, { recursive: true })
  const byLabel = Object.fromEntries(rows.map(([, count, label, pids]) => [label, [count, pids.split(" ").length]]))
  assert.deepEqual(byLabel, { "60 · projA": ["2", 2], [path.basename(dir)]: ["1", 1] })
  assert.equal(rows.find(r => r[2] === "60 · projA")[3], [kids[0].pid, kids[1].pid].sort((a, b) => a - b).join(" "))
})

test("no name prints nothing and exits 2", () => {
  const r = spawnSync("sh", [script], { encoding: "utf8" })
  assert.equal(r.status, 2)
  assert.equal(r.stdout, "")
})
