import test from "node:test"
import assert from "node:assert/strict"
import { spawn, spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../kill-group.sh")
const run = (...args) => spawnSync("sh", [script, ...args], { encoding: "utf8" }).stdout.replace(/\n$/, "").split("\t")
const wait = (ms) => new Promise(r => setTimeout(r, ms))

// A copy of `sleep` under a name nothing else uses, so the row is ours alone.
function fixture(name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "memkill-"))
  const bin = path.join(dir, name)
  fs.copyFileSync(spawnSync("which", ["sleep"], { encoding: "utf8" }).stdout.trim(), bin)
  fs.chmodSync(bin, 0o755)
  return { dir, bin }
}

test("TERM stops every process in the row and reports the count", async () => {
  const { dir, bin } = fixture("memtest-term")
  const kids = [spawn(bin, ["60"]), spawn(bin, ["60"])]
  await wait(200)
  const [name, ok, denied, owners] = run("memtest-term", "TERM")
  assert.deepEqual([name, ok, denied, owners], ["memtest-term", "2", "0", ""])
  await wait(200)
  assert.ok(kids.every(k => k.signalCode === "SIGTERM"))
  fs.rmSync(dir, { recursive: true })
})

test("KILL ends a process that is stopped and cannot act on TERM", async () => {
  const { dir, bin } = fixture("memtest-kill")
  const stubborn = spawn(bin, ["60"])
  await wait(200)
  stubborn.kill("SIGSTOP")
  assert.equal(run("memtest-kill", "KILL")[1], "1")
  await wait(200)
  assert.equal(stubborn.signalCode, "SIGKILL")
  fs.rmSync(dir, { recursive: true })
})

test("a name nobody runs signals nothing", () => {
  assert.deepEqual(run("memtest-no-such-program", "TERM"), ["memtest-no-such-program", "0", "0", ""])
})

test("only the exact basename matches, not a prefix or a substring", async () => {
  const { dir, bin } = fixture("memtest-exact")
  const kid = spawn(bin, ["60"])
  await wait(200)
  assert.equal(run("memtest", "TERM")[1], "0")
  assert.equal(run("exact", "TERM")[1], "0")
  assert.equal(kid.signalCode, null)
  kid.kill("SIGKILL")
  fs.rmSync(dir, { recursive: true })
})

test("a refused kill is counted as denied with the owner named", { skip: process.getuid() === 0 }, () => {
  // PID 1 belongs to root; the kernel refuses a signal from a normal user.
  const name = fs.readFileSync("/proc/1/cmdline", "utf8").split("\0")[0].split("/").pop()
  const [, ok, denied, owners] = run(name, "TERM")
  assert.equal(ok, "0")
  assert.ok(Number(denied) >= 1)
  assert.match(owners, /root/)
})
