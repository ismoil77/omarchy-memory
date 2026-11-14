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

// Every process whose argv[0] basename is `name`, with its owner.
function owners(name) {
  const ps = spawnSync("ps", ["-eo", "user=,args="], { encoding: "utf8" }).stdout.split("\n")
  return ps.map(l => l.trim().split(/\s+/)).filter(f => f.length > 1 && f[1].split("/").pop().replace(/:$/, "") === name).map(f => f[0])
}

test("a refused kill is counted as denied with the owner named", (t) => {
  if (process.getuid() === 0) return t.skip("root may signal anything")
  // PID 1 belongs to root; the kernel refuses a signal from a normal user.
  // Only run if every process with that name is root's: never signal one of ours.
  const name = fs.readFileSync("/proc/1/cmdline", "utf8").split("\0")[0].split("/").pop()
  const who = owners(name)
  if (who.length === 0 || who.some(u => u !== "root")) return t.skip("PID 1's name is shared with a process of this user")
  const [, ok, denied, owner] = run(name, "TERM")
  assert.equal(ok, "0")
  assert.ok(Number(denied) >= 1)
  assert.match(owner, /root/)
})

test("an empty name signals nothing, prints nothing and fails", () => {
  const r = spawnSync("sh", [script, "", "TERM"], { encoding: "utf8" })
  assert.equal(r.status, 2)
  assert.equal(r.stdout, "")
})

test("a signal other than TERM or KILL is refused, not reported as denied", async () => {
  const { dir, bin } = fixture("memtest-sig")
  const kid = spawn(bin, ["60"])
  await wait(200)
  const r = spawnSync("sh", [script, "memtest-sig", "BOGUS"], { encoding: "utf8" })
  assert.equal(r.status, 2)
  assert.equal(r.stdout, "")
  assert.equal(kid.signalCode, null)
  kid.kill("SIGKILL")
  fs.rmSync(dir, { recursive: true })
})

test("names with spaces, backslashes or regex characters match literally", async () => {
  const { dir, bin } = fixture("memtest-literal")
  const kid = spawn(bin, ["60"])
  await wait(200)
  for (const odd of ["memtest literal", "memtest-lit\\eral", "memtest-.*", "^memtest-literal$", "memtest-literal\\n"])
    assert.deepEqual(run(odd, "TERM"), [odd, "0", "0", ""], odd)
  assert.equal(kid.signalCode, null)
  kid.kill("SIGKILL")
  fs.rmSync(dir, { recursive: true })
})

test("the script never signals itself", () => {
  // Run it through a copy of sh called memtest-sh and ask it to stop memtest-sh.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "memkill-"))
  const copy = path.join(dir, "memtest-sh")
  fs.copyFileSync(spawnSync("which", ["sh"], { encoding: "utf8" }).stdout.trim(), copy)
  fs.chmodSync(copy, 0o755)
  const r = spawnSync(copy, [script, "memtest-sh", "TERM"], { encoding: "utf8" })
  assert.equal(r.signal, null)
  assert.equal(r.stdout, "memtest-sh\t0\t0\t\n")
  fs.rmSync(dir, { recursive: true })
})

test("with PIDs, only those of the row's processes are signalled, and a foreign PID never", async () => {
  const { dir, bin } = fixture("memtest-pids")
  const other = fixture("memtest-other")
  const kids = [spawn(bin, ["60"]), spawn(bin, ["60"])]
  const stranger = spawn(other.bin, ["60"])
  await wait(200)
  // The stranger's PID is in the list (a reused PID): it is not one of the row's processes.
  const [name, ok] = run("memtest-pids", "TERM", String(kids[0].pid), String(stranger.pid))
  assert.deepEqual([name, ok], ["memtest-pids", "1"])
  await wait(200)
  assert.equal(kids[0].signalCode, "SIGTERM")
  assert.equal(kids[1].signalCode, null)
  assert.equal(stranger.signalCode, null)
  kids[1].kill(); stranger.kill()
  fs.rmSync(dir, { recursive: true }); fs.rmSync(other.dir, { recursive: true })
})
