// Run with: node tests/test_prayer_times.js
// Reference times from api.aladhan.com for the same method and coordinates.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "PrayerTimes.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const sandbox = { module: { exports: {} } }
vm.runInNewContext(source, sandbox)
const PT = sandbox.module.exports

const cases = [
  { city: "Makkah", date: [2025, 1, 21], lat: 21.4225, lng: 39.8262, tz: 3, method: "Makkah",
    expect: { fajr: "05:41", sunrise: "07:01", dhuhr: "12:32", asr: "15:41", maghrib: "18:04", isha: "19:34" },
    hijri: [21, 7, 1446] },
  { city: "London", date: [2025, 3, 20], lat: 51.5074, lng: -0.1278, tz: 0, method: "MWL",
    expect: { fajr: "04:09", sunrise: "06:03", dhuhr: "12:08", asr: "15:25", maghrib: "18:14", isha: "20:01" },
    hijri: [20, 9, 1446] },
  { city: "Cairo", date: [2025, 9, 1], lat: 30.0444, lng: 31.2357, tz: 3, method: "Egypt",
    expect: { fajr: "05:02", sunrise: "06:32", dhuhr: "12:55", asr: "16:30", maghrib: "19:18", isha: "20:37" },
    hijri: [9, 3, 1447] },
  { city: "New York", date: [2025, 7, 15], lat: 40.7128, lng: -74.006, tz: -4, method: "ISNA",
    expect: { fajr: "04:03", sunrise: "05:38", dhuhr: "13:02", asr: "17:01", maghrib: "20:26", isha: "22:01" },
    hijri: [20, 1, 1447] }
]

const TOLERANCE_MIN = 2
let failures = 0

function minutesOf(hhmm) {
  const [h, m] = hhmm.split(":").map(Number)
  return h * 60 + m
}

for (const c of cases) {
  const date = new Date(c.date[0], c.date[1] - 1, c.date[2])
  const hours = PT.computeHours(date, c.lat, c.lng, { method: c.method, timezone: c.tz })
  for (const key of Object.keys(c.expect)) {
    const got = Math.round(hours[key] * 60)
    const want = minutesOf(c.expect[key])
    const diff = got - want
    const gotText = String(Math.floor(got / 60)).padStart(2, "0") + ":" + String(got % 60).padStart(2, "0")
    const ok = Math.abs(diff) <= TOLERANCE_MIN
    if (!ok) failures++
    console.log(`${ok ? "ok  " : "FAIL"} ${c.city.padEnd(9)} ${key.padEnd(8)} got ${gotText} want ${c.expect[key]} (${diff >= 0 ? "+" : ""}${diff}m)`)
  }

  const h = PT.hijri(date)
  const dayDiff = Math.abs(h.day - c.hijri[0])
  const ok = h.month === c.hijri[1] && h.year === c.hijri[2] && dayDiff <= 1
  if (!ok) failures++
  console.log(`${ok ? "ok  " : "FAIL"} ${c.city.padEnd(9)} hijri    got ${h.day}/${h.month}/${h.year} want ${c.hijri.join("/")}`)
}

// next/current prayer selection
{
  const day = new Date(2025, 2, 20)
  const opts = { method: "MWL", timezone: 0 }
  const today = PT.schedule(day, 51.5074, -0.1278, opts)
  const tomorrow = PT.schedule(new Date(2025, 2, 21), 51.5074, -0.1278, opts)
  const checks = [
    [new Date(2025, 2, 20, 3, 0), "fajr", null],
    [new Date(2025, 2, 20, 7, 0), "dhuhr", "fajr"],   // sunrise is skipped
    [new Date(2025, 2, 20, 16, 0), "maghrib", "asr"],
    [new Date(2025, 2, 20, 23, 0), "fajr", "isha"]    // rolls to tomorrow
  ]
  for (const [now, wantNext, wantCurrent] of checks) {
    const next = PT.nextPrayer(now, today, tomorrow)
    const cur = PT.currentPrayer(now, today)
    const ok = next.key === wantNext && (cur ? cur.key : null) === wantCurrent
    if (!ok) failures++
    console.log(`${ok ? "ok  " : "FAIL"} next/current at ${now.toTimeString().slice(0, 5)}: ${next.key}/${cur ? cur.key : "-"}`)
  }
}

// parsers
{
  const ip = PT.parseIpLocation('{"city":"Riyadh","country":"SA","loc":"24.6877,46.7219"}')
  const geo = PT.parseGeocode('{"results":[{"name":"Cairo","admin1":"Cairo","country":"Egypt","latitude":30.06,"longitude":31.25}]}')
  const ok = ip && ip.name === "Riyadh, SA" && ip.latitude === 24.6877 &&
    geo.length === 1 && geo[0].description === "Egypt" && PT.parseIpLocation("garbage") === null
  if (!ok) failures++
  console.log(`${ok ? "ok  " : "FAIL"} location parsers`)
}

console.log(failures ? `\n${failures} failure(s)` : "\nall passed")
process.exit(failures ? 1 : 0)
