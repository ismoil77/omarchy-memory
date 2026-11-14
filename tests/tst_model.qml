import QtQuick
import QtTest
import "../Model.js" as Model
import "../kit/Contrast.js" as Contrast

// The same libraries the widget imports, run by Qt's own JavaScript engine:
// a syntax Node accepts but QML does not would fail here.
TestCase {
  name: "Model in the QML engine"

  function test_reading_and_verdict() {
    var ru = Model.config({ language: "ru" })
    var mem = Model.summarize(Model.parseMeminfo("MemTotal:  1000 kB\nMemAvailable:  100 kB\nMemFree: 100 kB\n"), null)
    compare(mem.ready, true)
    compare(Model.barLabel("percent", mem), "90%")
    compare(Model.verdict(mem, { full: 0 }, null).level, "tight")
    compare(Model.formatKb(ru, 3 * 1024 * 1024), "3,0 ГБ")
    compare(Model.parseOomctl("Swap Used Limit: 90.00%\nDefault Memory Pressure Limit: 50.00%\n").swapLimit, 0.9)
    compare(Model.matchApp("chrome", [{ id: "google-chrome", name: "Google Chrome", exec: "/usr/bin/google-chrome-stable" }]).name, "Google Chrome")
    compare(Model.keepOrder([{ name: "b" }, { name: "a" }], [{ name: "a" }, { name: "b" }])[0].name, "b")
    compare(Model.killStatus(ru, { phase: "failed" }), "Не удалось остановить")
  }

  function test_yellow_stays_readable_on_a_cream_popup() {
    var c = Contrast.ensure("#D0A215", "#FFFCF0", 4.5)
    verify(Contrast.ratio(c, "#FFFCF0") >= 4.5)
  }
}
