.pragma library

// Offline prayer-time calculation following the PrayTimes.org algorithm
// (Hamid Zarrabi-Zadeh). Pure functions so the widget and the node tests
// share one implementation.

var PRAYERS = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]

var NAMES = {
  fajr: "Fajr",
  sunrise: "Sunrise",
  dhuhr: "Dhuhr",
  asr: "Asr",
  maghrib: "Maghrib",
  isha: "Isha"
}

// fajr/isha are sun depression angles; a string "N min" means minutes after
// maghrib. maghrib defaults to sunset unless an angle is given.
var METHODS = {
  MWL:       { name: "Muslim World League",                 fajr: 18,   isha: 17 },
  ISNA:      { name: "Islamic Society of North America",    fajr: 15,   isha: 15 },
  Egypt:     { name: "Egyptian General Authority",          fajr: 19.5, isha: 17.5 },
  Makkah:    { name: "Umm al-Qura, Makkah",                 fajr: 18.5, isha: "90 min" },
  Karachi:   { name: "University of Islamic Sciences, Karachi", fajr: 18, isha: 18 },
  Tehran:    { name: "Institute of Geophysics, Tehran",     fajr: 17.7, isha: 14, maghrib: 4.5 },
  Jafari:    { name: "Shia Ithna-Ashari, Qum",              fajr: 16,   isha: 14, maghrib: 4 },
  Gulf:      { name: "Gulf Region",                         fajr: 19.5, isha: "90 min" },
  Kuwait:    { name: "Kuwait",                              fajr: 18,   isha: 17.5 },
  Qatar:     { name: "Qatar",                               fajr: 18,   isha: "90 min" },
  Singapore: { name: "Singapore",                           fajr: 20,   isha: 18 },
  Turkey:    { name: "Diyanet, Turkey",                     fajr: 18,   isha: 17 }
}

// ---- degree math
function dtr(d) { return d * Math.PI / 180 }
function rtd(r) { return r * 180 / Math.PI }
function sin(d) { return Math.sin(dtr(d)) }
function cos(d) { return Math.cos(dtr(d)) }
function tan(d) { return Math.tan(dtr(d)) }
function arcsin(x) { return rtd(Math.asin(x)) }
function arccos(x) { return rtd(Math.acos(x)) }
function arccot(x) { return rtd(Math.atan(1 / x)) }
function arctan2(y, x) { return rtd(Math.atan2(y, x)) }
function fix(a, b) { a = a - b * Math.floor(a / b); return a < 0 ? a + b : a }
function fixAngle(a) { return fix(a, 360) }
function fixHour(a) { return fix(a, 24) }

function isMinutes(v) { return typeof v === "string" && v.indexOf("min") !== -1 }
function numeric(v) { return parseFloat(String(v)) }

function julian(year, month, day) {
  if (month <= 2) { year -= 1; month += 12 }
  var A = Math.floor(year / 100)
  var B = 2 - A + Math.floor(A / 4)
  return Math.floor(365.25 * (year + 4716)) + Math.floor(30.6001 * (month + 1)) + day + B - 1524.5
}

function sunPosition(jd) {
  var D = jd - 2451545.0
  var g = fixAngle(357.529 + 0.98560028 * D)
  var q = fixAngle(280.459 + 0.98564736 * D)
  var L = fixAngle(q + 1.915 * sin(g) + 0.020 * sin(2 * g))
  var e = 23.439 - 0.00000036 * D
  var RA = arctan2(cos(e) * sin(L), cos(L)) / 15
  return {
    declination: arcsin(sin(e) * sin(L)),
    equation: q / 15 - fixHour(RA)
  }
}

// Compute raw prayer times (hours, local clock) for one date.
//   date:     a JS Date (only y/m/d are used)
//   lat, lng: degrees
//   options:  { method, asr: "Standard"|"Hanafi", timezone (hours; defaults to
//              the system offset on that date), offsetMinutes }
function computeHours(date, lat, lng, options) {
  options = options || {}
  var method = METHODS[options.method] || METHODS.MWL
  var asrFactor = options.asr === "Hanafi" ? 2 : 1
  var timezone = options.timezone !== undefined && options.timezone !== null
    ? Number(options.timezone)
    : -new Date(date.getFullYear(), date.getMonth(), date.getDate(), 12).getTimezoneOffset() / 60
  var jDate = julian(date.getFullYear(), date.getMonth() + 1, date.getDate()) - lng / (15 * 24)

  function midDay(t) {
    var eqt = sunPosition(jDate + t).equation
    return fixHour(12 - eqt)
  }
  function sunAngleTime(angle, t, ccw) {
    var decl = sunPosition(jDate + t).declination
    var noon = midDay(t)
    var v = arccos((-sin(angle) - sin(decl) * sin(lat)) / (cos(decl) * cos(lat))) / 15
    return noon + (ccw ? -v : v)
  }
  function asrTime(factor, t) {
    var decl = sunPosition(jDate + t).declination
    var angle = -arccot(factor + tan(Math.abs(lat - decl)))
    return sunAngleTime(angle, t)
  }

  var riseSet = 0.833
  var times = { fajr: 5, sunrise: 6, dhuhr: 12, asr: 13, sunset: 18, maghrib: 18, isha: 18 }
  // One refinement pass over the default guesses, as in PrayTimes.
  for (var i = 0; i < 1; i++) {
    var p = {}
    for (var k in times) p[k] = times[k] / 24
    times = {
      fajr: sunAngleTime(numeric(method.fajr), p.fajr, true),
      sunrise: sunAngleTime(riseSet, p.sunrise, true),
      dhuhr: midDay(p.dhuhr),
      asr: asrTime(asrFactor, p.asr),
      sunset: sunAngleTime(riseSet, p.sunset),
      maghrib: method.maghrib !== undefined ? sunAngleTime(numeric(method.maghrib), p.maghrib) : sunAngleTime(riseSet, p.maghrib),
      isha: isMinutes(method.isha) ? 0 : sunAngleTime(numeric(method.isha), p.isha)
    }
  }

  for (var key in times) times[key] += timezone - lng / 15
  if (method.maghrib === undefined) times.maghrib = times.sunset
  if (isMinutes(method.isha)) times.isha = times.maghrib + numeric(method.isha) / 60

  // High-latitude fallback ("NightMiddle"): when the sun never reaches the
  // twilight angle, cap fajr/isha at half the night from sunset/sunrise.
  var night = fixHour(times.sunrise - times.sunset)
  var portion = night / 2
  if (isNaN(times.fajr) || fixHour(times.sunrise - times.fajr) > portion) times.fajr = times.sunrise - portion
  if (!isMinutes(method.isha) && (isNaN(times.isha) || fixHour(times.isha - times.sunset) > portion)) times.isha = times.sunset + portion

  var offset = Number(options.offsetMinutes || 0) / 60
  var out = {}
  for (var j = 0; j < PRAYERS.length; j++) out[PRAYERS[j]] = times[PRAYERS[j]] + offset
  return out
}

// Same as computeHours but returns { name: Date } on the given calendar day,
// rounded to the nearest minute.
function compute(date, lat, lng, options) {
  var hours = computeHours(date, lat, lng, options)
  var out = {}
  for (var i = 0; i < PRAYERS.length; i++) {
    var key = PRAYERS[i]
    var minutes = Math.round(hours[key] * 60)
    out[key] = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, minutes, 0, 0)
  }
  return out
}

// Ordered list of { key, name, time } for the day. Friday's dhuhr is Jumu'ah.
function schedule(date, lat, lng, options) {
  var times = compute(date, lat, lng, options)
  var friday = date.getDay() === 5
  return PRAYERS.map(function(key) {
    return {
      key: key,
      name: key === "dhuhr" && friday ? "Jumu'ah" : NAMES[key],
      time: times[key],
      isPrayer: key !== "sunrise"
    }
  })
}

// Next prayer (sunrise excluded) after `now`, rolling over to tomorrow's fajr.
function nextPrayer(now, today, tomorrow) {
  for (var i = 0; i < today.length; i++) {
    if (today[i].isPrayer && today[i].time.getTime() > now.getTime()) return today[i]
  }
  return tomorrow ? tomorrow[0] : null
}

// Latest prayer whose time has passed (null before today's fajr).
function currentPrayer(now, today) {
  var current = null
  for (var i = 0; i < today.length; i++) {
    if (today[i].isPrayer && today[i].time.getTime() <= now.getTime()) current = today[i]
  }
  return current
}

function formatTime(date, use12h) {
  var h = date.getHours()
  var m = date.getMinutes()
  var mm = (m < 10 ? "0" : "") + m
  if (!use12h) return (h < 10 ? "0" : "") + h + ":" + mm
  var suffix = h < 12 ? "AM" : "PM"
  h = h % 12
  if (h === 0) h = 12
  return h + ":" + mm + " " + suffix
}

// "1h 05m" / "9m" / "45s" style countdown.
function formatCountdown(ms) {
  var total = Math.max(0, Math.floor(ms / 1000))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
  if (m > 0) return m + "m"
  return s + "s"
}

// "-9:59" style clock countdown for the bar during the reminder window.
function formatShortCountdown(ms) {
  var total = Math.max(0, Math.ceil(ms / 1000))
  var m = Math.floor(total / 60)
  var s = total % 60
  return "-" + m + ":" + (s < 10 ? "0" : "") + s
}

// ---- Hijri (tabular / Kuwaiti algorithm; may differ by a day from local
// moon sighting).
var HIJRI_MONTHS = [
  "Muharram", "Safar", "Rabi' al-Awwal", "Rabi' al-Thani", "Jumada al-Ula", "Jumada al-Akhirah",
  "Rajab", "Sha'ban", "Ramadan", "Shawwal", "Dhu al-Qi'dah", "Dhu al-Hijjah"
]

function hijri(date, adjustDays) {
  var d = new Date(date.getFullYear(), date.getMonth(), date.getDate() + Number(adjustDays || 0))
  var jdn = Math.floor(julian(d.getFullYear(), d.getMonth() + 1, d.getDate()) + 0.5)
  var l = jdn - 1948440 + 10632
  var n = Math.floor((l - 1) / 10631)
  l = l - 10631 * n + 354
  var j = Math.floor((10985 - l) / 5316) * Math.floor((50 * l) / 17719) + Math.floor(l / 5670) * Math.floor((43 * l) / 15238)
  l = l - Math.floor((30 - j) / 15) * Math.floor((17719 * j) / 50) - Math.floor(j / 16) * Math.floor((15238 * j) / 43) + 29
  var month = Math.floor((24 * l) / 709)
  var day = l - Math.floor((709 * month) / 24)
  var year = 30 * n + j - 30
  return { day: day, month: month, year: year, monthName: HIJRI_MONTHS[month - 1] }
}

function hijriLabel(date, adjustDays) {
  var h = hijri(date, adjustDays)
  return h.day + " " + h.monthName + " " + h.year + " AH"
}

// ---- Location helpers

function validCoordinates(lat, lng) {
  lat = parseFloat(String(lat))
  lng = parseFloat(String(lng))
  return !isNaN(lat) && !isNaN(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180
}

// ipinfo.io/json → { name, latitude, longitude } or null.
function parseIpLocation(text) {
  try {
    var data = JSON.parse(text)
    var parts = String(data.loc || "").split(",")
    if (parts.length !== 2 || !validCoordinates(parts[0], parts[1])) return null
    var name = [data.city, data.country].filter(function(x) { return !!x }).join(", ")
    return { name: name || "Current location", latitude: parseFloat(parts[0]), longitude: parseFloat(parts[1]) }
  } catch (e) {
    return null
  }
}

// Open-Meteo geocoding → [{ name, description, latitude, longitude }].
function parseGeocode(text) {
  try {
    var data = JSON.parse(text)
    return (data.results || []).map(function(r) {
      return {
        name: r.name,
        description: [r.admin1, r.country].filter(function(x) { return !!x && x !== r.name }).join(", "),
        latitude: r.latitude,
        longitude: r.longitude
      }
    })
  } catch (e) {
    return []
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    METHODS: METHODS, PRAYERS: PRAYERS, computeHours: computeHours, compute: compute,
    schedule: schedule, nextPrayer: nextPrayer, currentPrayer: currentPrayer,
    formatTime: formatTime, formatCountdown: formatCountdown, formatShortCountdown: formatShortCountdown,
    hijri: hijri, hijriLabel: hijriLabel, parseIpLocation: parseIpLocation, parseGeocode: parseGeocode,
    validCoordinates: validCoordinates
  }
}
