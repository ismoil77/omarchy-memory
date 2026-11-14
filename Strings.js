.pragma library

// Every user-visible word of the widget, per language. {name} placeholders
// are filled by I18n.t; an array is the forms of a noun (see I18n.plural).
// Tests keep the two tables in step.

var en = {
  title: "Memory",
  reading: "Reading…",
  usedOf: "{used} used of {total}",
  calm: "calm",
  tight: "tight",
  danger: "danger",
  whyPressure: "programs wait for memory",
  whySwap: "swap is nearly full",
  whyRam: "almost no free memory",

  chartCaption: "Last 10 minutes",
  chartAgo: "10 min ago",
  chartNow: "now",
  chartMemory: "memory",
  chartPressure: "pressure",

  partPrograms: "programs",
  partCache: "cache",
  partZram: "zram",
  partFree: "free",

  tilePressure: "Pressure",
  tilePressureKill: "oomd acts at {limit} for {sec} s",
  tilePressureNoOomd: "time programs wait",
  tileSwap: "Swap",
  tileSwapKill: "{used} of {total} · oomd at {limit}",
  tileSwapPlain: "{used} of {total}",
  tileSwapRate: "↓{in}/s ↑{out}/s",
  tileZram: "zram",
  tileZramDetail: "{orig} → {used}",
  tileCache: "Cache",
  tileCacheDetail: "given back on demand",
  freeCache: "Free cache",
  freeing: "Freeing…",
  freed: "Gave back {n}",
  freedNone: "Nothing more to give back",
  noSwap: "no swap",

  sectionApps: "Apps",
  collecting: "Collecting…",
  growing: "↑ growing",
  inSwap: "+{n} in swap",
  lookingInside: "Looking inside…",

  stop: "Stop",
  stopN: "Stop {n}",
  cancel: "Cancel",
  force: "Force",
  stopping: "Stopping…",
  stillRunning: "Still running",
  unableToStop: "Unable to stop",
  notRunning: "Not running",
  notAllowed: "Not allowed · {owner}",
  partial: "Stopped {n} · {denied} not allowed, {owner}",
  ownerOther: "another user",
  ownerSystem: "system ({owners})",

  modeFree: "Free",
  modeUsed: "Used",
  modePercent: "Percent",
  modeIcon: "Icon only",

  tipBar: "RAM {used} / {total} ({pct}) · {free} free",
  tipSwap: " · swap {used} / {total}",
  tipState: " · {state}",

  notifyTitle: "Memory is running out",
  notifyBody: "{why}. oomd may stop an app soon: close something you do not need.",

  unitGB: "GB",
  unitMB: "MB",
  unitKB: "kB"
}

var ru = {
  title: "Память",
  reading: "Читаю…",
  usedOf: "занято {used} из {total}",
  calm: "спокойно",
  tight: "тесно",
  danger: "опасно",
  whyPressure: "программы ждут память",
  whySwap: "swap почти полон",
  whyRam: "свободной памяти почти нет",

  chartCaption: "Последние 10 минут",
  chartAgo: "10 мин назад",
  chartNow: "сейчас",
  chartMemory: "память",
  chartPressure: "давление",

  partPrograms: "программы",
  partCache: "кэш",
  partZram: "zram",
  partFree: "свободно",

  tilePressure: "Давление",
  tilePressureKill: "oomd при {limit} за {sec} с",
  tilePressureNoOomd: "сколько программы ждут",
  tileSwap: "Swap",
  tileSwapKill: "{used} из {total} · oomd при {limit}",
  tileSwapPlain: "{used} из {total}",
  tileSwapRate: "↓{in}/с ↑{out}/с",
  tileZram: "zram",
  tileZramDetail: "{orig} → {used}",
  tileCache: "Кэш",
  tileCacheDetail: "отдаётся по требованию",
  freeCache: "Освободить кэш",
  freeing: "Освобождаю…",
  freed: "Отдано {n}",
  freedNone: "Больше отдавать нечего",
  noSwap: "swap нет",

  sectionApps: "Приложения",
  collecting: "Собираю…",
  growing: "↑ растёт",
  inSwap: "+{n} в swap",
  lookingInside: "Смотрю внутрь…",

  stop: "Стоп",
  stopN: "Стоп {n}",
  cancel: "Отмена",
  force: "Убить",
  stopping: "Останавливаю…",
  stillRunning: "Ещё работает",
  unableToStop: "Не удалось остановить",
  notRunning: "Уже не запущено",
  notAllowed: "Нет прав · {owner}",
  partial: "Остановлено {n} · {denied} без прав, {owner}",
  ownerOther: "другой пользователь",
  ownerSystem: "система ({owners})",

  modeFree: "Свободно",
  modeUsed: "Занято",
  modePercent: "Проценты",
  modeIcon: "Только иконка",

  tipBar: "Память {used} / {total} ({pct}) · свободно {free}",
  tipSwap: " · swap {used} / {total}",
  tipState: " · {state}",

  notifyTitle: "Память заканчивается",
  notifyBody: "{why}. Скоро oomd может закрыть приложение: закрой что-нибудь лишнее.",

  unitGB: "ГБ",
  unitMB: "МБ",
  unitKB: "кБ"
}

var langs = ["en", "ru"]
var tables = { en: en, ru: ru }
