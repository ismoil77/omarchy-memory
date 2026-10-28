import QtQuick
import QtTest
import "../Model.js" as Model
import "../kit/Contrast.js" as Contrast

// The same libraries the widget imports, run by Qt's own JavaScript engine:
// a syntax Node accepts but QML does not would fail here.
TestCase {
  name: "Model in the QML engine"

  function test_summary_and_levels() {
    var mem = Model.summarize(Model.parseMeminfo("MemTotal\t1000\nMemAvailable\t120\n"))
    compare(mem.ready, true)
    compare(Model.percent(mem.usedFraction), 88)
    compare(Model.level(mem.usedFraction, 75, 90), "yellow")
    compare(Model.level(0.91, 75, 90), "red")
    compare(Model.level(0.2, 75, 90), "ok")
    compare(Model.barLabel("percent", mem), "88%")
  }

  function test_processes_and_kill() {
    var list = Model.parseProcesses("2048\t3\tnode\n1024\t1\tchrome\n")
    compare(list.length, 2)
    compare(Model.formatKb(Model.sumRss(list)), "3 MB")
    compare(Model.parseKillResult("node\t2\t1\troot").owners, "root")
    compare(Model.killStatus({ phase: "denied", owners: "root" }), "Not allowed · system (root)")
    compare(Model.killStatus({ phase: "failed" }), "Unable to stop")
  }

  function test_yellow_stays_readable_on_a_cream_popup() {
    var c = Contrast.ensure("#D0A215", "#FFFCF0", 4.5)
    verify(Contrast.ratio(c, "#FFFCF0") >= 4.5)
    var r = Contrast.ensure("#D14D41", "#FFFCF0", 4.5)
    verify(Contrast.ratio(r, "#FFFCF0") >= 4.5)
  }
}
