import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PrayerTimes.js" as PT
import "components"

// Prayer times in the bar: next prayer + time, a reminder before each azan,
// the azan itself at prayer time, and a popup with today's schedule,
// location (automatic or manual) and alert switches.
Panel {
  id: root
  moduleName: "io.github.ahmadrun.prayer-times"
  ipcTarget: "io.github.ahmadrun.prayer-times"

  // nf-md-mosque
  readonly property string mosqueGlyph: "󱠧"

  // ---- Settings (shell.json via the plugin settings form)
  readonly property string method: String(setting("method", "MWL"))
  readonly property string asrMethod: String(setting("asrMethod", "Standard"))
  readonly property bool use12h: String(setting("timeFormat", "24h")) === "12h"
  readonly property int reminderMinutes: Math.max(0, Math.min(60, Number(setting("reminderMinutes", 10)) || 0))
  readonly property int offsetMinutes: Number(setting("offsetMinutes", 0)) || 0
  readonly property int hijriAdjust: Number(setting("hijriAdjust", 0)) || 0
  readonly property string azanSound: expandHome(String(setting("azanSound", "")))
  readonly property string fajrAzanSound: expandHome(String(setting("fajrAzanSound", "")))

  // ---- Live state (~/.local/state/omarchy/settings/prayer-times.json)
  property var store: ({})
  readonly property string locationMode: store.mode === "manual" ? "manual" : "auto"
  readonly property bool soundEnabled: store.soundEnabled !== false
  readonly property bool reminderEnabled: store.reminderEnabled !== false
  property var weatherLocation: null

  readonly property var location: {
    var manual = store.manual
    var auto = store.auto
    if (locationMode === "manual" && manual && PT.validCoordinates(manual.latitude, manual.longitude)) return manual
    if (auto && PT.validCoordinates(auto.latitude, auto.longitude)) return auto
    if (weatherLocation && PT.validCoordinates(weatherLocation.latitude, weatherLocation.longitude)) return weatherLocation
    return null
  }
  readonly property string locationName: location ? (location.name || "Unknown location") : ""

  // ---- Clock + schedule
  property date now: new Date()
  readonly property string dayKey: Qt.formatDate(now, "yyyy-MM-dd")
  readonly property var calcOptions: ({ method: method, asr: asrMethod, offsetMinutes: offsetMinutes })

  // Derived from dayKey (not `now`) so the schedule recomputes once a day,
  // not on every clock tick.
  function dayFromKey(key, plusDays) {
    var p = key.split("-")
    return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]) + plusDays)
  }
  readonly property var today: location
    ? PT.schedule(dayFromKey(dayKey, 0), location.latitude, location.longitude, calcOptions)
    : []
  readonly property var tomorrow: location
    ? PT.schedule(dayFromKey(dayKey, 1), location.latitude, location.longitude, calcOptions)
    : []
  readonly property var nextPrayer: today.length ? PT.nextPrayer(now, today, tomorrow) : null
  readonly property var currentPrayer: today.length ? PT.currentPrayer(now, today) : null
  readonly property real msToNext: nextPrayer ? nextPrayer.time.getTime() - now.getTime() : -1
  readonly property bool inReminderWindow: reminderEnabled && reminderMinutes > 0 && nextPrayer !== null
    && msToNext > 0 && msToNext <= reminderMinutes * 60000

  readonly property string barText: {
    if (bar && bar.vertical) return mosqueGlyph
    if (!nextPrayer) return mosqueGlyph
    var when = inReminderWindow ? PT.formatShortCountdown(msToNext) : PT.formatTime(nextPrayer.time, use12h)
    return mosqueGlyph + "  " + nextPrayer.name + " " + when
  }

  // Fired alerts, keyed "<kind>:<yyyy-MM-dd>:<prayer>", so each one fires once.
  property var fired: ({})
  readonly property bool playing: azanProc.running

  function expandHome(path) {
    if (path.indexOf("~/") === 0) return Quickshell.env("HOME") + path.substring(1)
    return path
  }

  function resolvePath(relative) {
    var url = String(Qt.resolvedUrl(relative))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  function stateFor(entry) {
    if (nextPrayer && entry.key === nextPrayer.key && entry.time.getTime() === nextPrayer.time.getTime()) return "next"
    if (currentPrayer && entry.key === currentPrayer.key) return "current"
    return entry.time.getTime() <= now.getTime() ? "past" : "upcoming"
  }

  // ---- Alerts

  // notify-send only takes its text as arguments, which are world-readable
  // through /proc/<pid>/cmdline, so notifications never include the location.
  function notify(title, body, urgency) {
    Quickshell.execDetached(["notify-send", "-a", "Prayer Times", "-u", urgency || "normal", title, body])
  }

  function soundFor(prayerKey) {
    if (prayerKey === "fajr" && fajrAzanSound !== "") return fajrAzanSound
    return azanSound
  }

  function playAzan(prayerKey) {
    var file = soundFor(prayerKey)
    if (!soundEnabled || file === "") return
    azanProc.running = false
    azanProc.command = ["sh", "-c",
      "if command -v mpv >/dev/null 2>&1; then exec mpv --no-video --really-quiet -- \"$1\"; else exec pw-play -- \"$1\"; fi",
      "azan", file]
    azanProc.running = true
  }

  function stopAzan() {
    azanProc.running = false
  }

  function announce(entry) {
    notify("It's time for " + entry.name, PT.formatTime(entry.time, use12h), "critical")
    playAzan(entry.key)
  }

  function remind(entry, ms) {
    var minutes = Math.max(1, Math.round(ms / 60000))
    notify(entry.name + " in " + minutes + " minute" + (minutes === 1 ? "" : "s"),
      PT.formatTime(entry.time, use12h), "normal")
  }

  function checkAlerts() {
    var t = now.getTime()
    var events = today.concat(tomorrow.length ? [tomorrow[0]] : [])
    for (var i = 0; i < events.length; i++) {
      var entry = events[i]
      if (!entry.isPrayer) continue
      var at = entry.time.getTime()
      var key = Qt.formatDate(entry.time, "yyyy-MM-dd") + ":" + entry.key

      if (reminderEnabled && reminderMinutes > 0 && !fired["remind:" + key]
          && t >= at - reminderMinutes * 60000 && t < at) {
        fired["remind:" + key] = true
        remind(entry, at - t)
      }
      // Only within two minutes of the time, so waking from suspend hours
      // later doesn't replay a missed azan.
      if (!fired["azan:" + key] && t >= at && t - at < 120000) {
        fired["azan:" + key] = true
        announce(entry)
      }
    }
  }

  function testAzan() {
    var entry = nextPrayer || { key: "dhuhr", name: "Dhuhr", time: new Date() }
    notify("Azan test · " + entry.name, (soundEnabled && soundFor(entry.key) !== "")
      ? "Playing the azan sound"
      : (soundEnabled ? "No azan sound file set in plugin settings" : "Azan sound is turned off"), "normal")
    playAzan(entry.key)
  }

  // ---- State persistence

  function mergeState(patch) {
    var next = JSON.parse(JSON.stringify(store || {}))
    for (var k in patch) {
      if (patch[k] && typeof patch[k] === "object" && next[k] && typeof next[k] === "object") {
        for (var kk in patch[k]) next[k][kk] = patch[k][kk]
      } else {
        next[k] = patch[k]
      }
    }
    store = next
    stateWriteQueue.push(JSON.stringify(patch))
    flushStateWrites()
  }

  property var stateWriteQueue: []
  function flushStateWrites() {
    if (stateProc.running || stateWriteQueue.length === 0) return
    // The patch (location name, coordinates) goes over stdin, never argv:
    // process arguments are world-readable through /proc/<pid>/cmdline.
    stateProc.patch = stateWriteQueue.shift()
    stateProc.command = ["bash", resolvePath("bin/prayer-times-state"), "merge"]
    stateProc.running = true
  }

  function setMode(mode) {
    if (mode === locationMode) return
    mergeState({ mode: mode })
    if (mode === "auto") detectLocation()
    else if (!store.manual || !PT.validCoordinates(store.manual.latitude, store.manual.longitude)) startEditingLocation()
  }

  function detectLocation() {
    if (!ipProc.running) ipProc.running = true
  }

  // ---- Manual location editing (same interaction as the weather panel)
  property bool editingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodeQuery: ""

  function startEditingLocation() {
    editingLocation = true
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = store.manual && store.manual.name ? store.manual.name : ""
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function pickSuggestion(s) {
    if (!s) return
    var name = s.description ? s.name + ", " + s.description.split(", ").pop() : s.name
    mergeState({ mode: "manual", manual: { name: name, latitude: s.latitude, longitude: s.longitude } })
    cancelEditingLocation()
  }

  function requestGeocode() {
    var query = locationField.text.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodeQuery = query
    if (geocodeProc.running) return
    // The URL (with the typed city) goes to curl as a config on stdin, never
    // argv: process arguments are world-readable through /proc/<pid>/cmdline.
    // encodeURIComponent leaves no quotes or backslashes to escape.
    geocodeProc.config = 'url = "https://geocoding-api.open-meteo.com/v1/search?name='
      + encodeURIComponent(query) + '&count=5&language=en&format=json"'
    geocodeProc.running = true
  }

  // ---- Panel lifecycle

  function close() {
    if (editingLocation) cancelEditingLocation()
    controller.hide()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    stateFile.reload()
    weatherFile.reload()
  }

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/prayer-times.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var data = JSON.parse(text())
        root.store = data && typeof data === "object" ? data : {}
      } catch (e) {
        root.store = {}
      }
      if (root.locationMode === "auto") root.detectLocation()
    }
    onLoadFailed: {
      root.store = {}
      root.detectLocation()
    }
  }

  FileView {
    id: weatherFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var data = JSON.parse(text())
        var lat = parseFloat(data.latitude)
        var lng = parseFloat(data.longitude)
        root.weatherLocation = PT.validCoordinates(lat, lng) ? { name: data.name || "", latitude: lat, longitude: lng } : null
      } catch (e) {
        root.weatherLocation = null
      }
    }
  }

  Process {
    id: stateProc
    property string patch: ""
    stdinEnabled: true
    onStarted: {
      write(patch + "\n")
      patch = ""
      stdinEnabled = false
    }
    onExited: {
      stdinEnabled = true
      root.flushStateWrites()
    }
  }

  Process {
    id: ipProc
    command: ["curl", "-fsS", "--max-time", "4", "https://ipinfo.io/json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var loc = PT.parseIpLocation(String(text || ""))
        if (!loc) return
        var prev = root.store.auto
        var changed = !prev || prev.name !== loc.name
          || Math.abs(prev.latitude - loc.latitude) > 0.01 || Math.abs(prev.longitude - loc.longitude) > 0.01
        if (changed) root.mergeState({ auto: loc })
      }
    }
  }

  Process {
    id: geocodeProc
    property string activeQuery: ""
    property string config: ""
    command: ["curl", "-fsS", "--max-time", "5", "-K", "-"]
    stdinEnabled: true
    onStarted: {
      activeQuery = root.geocodeQuery
      write(config + "\n")
      config = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.editingLocation) return
        root.locationSuggestions = PT.parseGeocode(String(text || ""))
        root.suggestionIndex = 0
      }
    }
    onExited: {
      stdinEnabled = true
      if (root.editingLocation && root.geocodeQuery !== activeQuery) root.requestGeocode()
    }
  }

  Process {
    id: azanProc
  }

  // Panel owns the open/close/toggle target; alerts get their own.
  //   qs ipc -p /usr/share/omarchy/shell call io.github.ahmadrun.prayer-times.azan test
  IpcHandler {
    target: "io.github.ahmadrun.prayer-times.azan"

    function test(): void { root.testAzan() }
    function stop(): void { root.stopAzan() }
    function remindTest(): void {
      var entry = root.nextPrayer || { key: "dhuhr", name: "Dhuhr", time: new Date() }
      root.remind(entry, root.reminderMinutes * 60000)
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.now = new Date()
      root.checkAlerts()
    }
  }

  Timer {
    // Re-detect in auto mode every 6 hours (travel, VPN changes).
    interval: 6 * 60 * 60 * 1000
    running: root.locationMode === "auto"
    repeat: true
    onTriggered: root.detectLocation()
  }

  // ---- Bar pill

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: root.inReminderWindow
    activeColor: Color.accent
    horizontalMargin: 8.75
    fixedWidth: root.bar && root.bar.vertical ? Style.bar.statusSlot : -1
    tooltipText: {
      if (!root.location) return "Prayer Times: detecting location…"
      if (!root.nextPrayer) return "Prayer Times"
      return root.nextPrayer.name + " in " + PT.formatCountdown(root.msToNext) + " · " + root.locationName
    }
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.playing ? root.stopAzan() : root.testAzan()
      else root.toggle()
    }
  }

  // ---- Popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
    readonly property string fontName: root.bar ? root.bar.fontFamily : Style.font.family

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---- Hero: next prayer
        PanelHero {
          foreground: panel.fg
          fontFamily: panel.fontName
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.mosqueGlyph
              color: root.inReminderWindow ? Color.accent : panel.fg
              font.family: panel.fontName
              font.pixelSize: Style.font.display
            }
          }
          title: root.nextPrayer
            ? root.nextPrayer.name + "  " + PT.formatTime(root.nextPrayer.time, root.use12h)
            : (root.location ? "Prayer times" : "Finding your location…")
          meta: root.nextPrayer
            ? (Qt.formatDate(root.nextPrayer.time, "yyyy-MM-dd") !== root.dayKey ? "tomorrow · " : "")
              + "in " + PT.formatCountdown(root.msToNext) + (root.locationName ? " · " + root.locationName : "")
            : ""
          detail: PT.hijri(root.now, root.hijriAdjust).day + " " + PT.hijri(root.now, root.hijriAdjust).monthName
        }

        // ---- Today's schedule
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.today.length > 0

          PanelSectionHeader {
            text: "TODAY · " + Qt.formatDate(root.now, "ddd d MMM").toUpperCase() + " · " + PT.hijriLabel(root.now, root.hijriAdjust).toUpperCase()
            foreground: panel.fg
            fontFamily: panel.fontName
            width: parent.width
            elide: Text.ElideRight
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.today
              delegate: PrayerRow {
                required property var modelData
                width: parent.width
                name: modelData.name
                time: PT.formatTime(modelData.time, root.use12h)
                isPrayer: modelData.isPrayer
                rowState: root.stateFor(modelData)
                foreground: panel.fg
                fontFamily: panel.fontName
              }
            }
          }
        }

        PanelSeparator { foreground: panel.fg }

        // ---- Location
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "LOCATION"
            foreground: panel.fg
            fontFamily: panel.fontName
          }

          ButtonGroup {
            options: [
              { value: "auto", label: "Automatic" },
              { value: "manual", label: "Manual" }
            ]
            value: root.locationMode
            foreground: panel.fg
            fontFamily: panel.fontName
            focusable: false
            onChanged: function(value) { root.setMode(value) }
          }

          // Current location, click to change (manual) or refresh (auto)
          Item {
            visible: !root.editingLocation
            width: parent.width
            implicitHeight: Math.max(locationLabel.implicitHeight, locationAction.implicitHeight)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                text: ""  // nf-fa-map_marker
                color: Qt.darker(panel.fg, 1.4)
                font.family: panel.fontName
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                id: locationLabel
                textFormat: Text.PlainText
                text: root.location
                  ? root.locationName.toUpperCase()
                  : (ipProc.running ? "DETECTING…" : "NO LOCATION")
                color: Qt.darker(panel.fg, 1.4)
                font.family: panel.fontName
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelActionButton {
              id: locationAction
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.locationMode === "auto" ? "󰑐" : "󰏫"   // refresh / pencil
              tooltipText: root.locationMode === "auto" ? "Detect again" : "Change city"
              foreground: panel.fg
              fontFamily: panel.fontName
              onClicked: root.locationMode === "auto" ? root.detectLocation() : root.startEditingLocation()
            }
          }

          TextField {
            id: locationField
            visible: root.editingLocation
            width: parent.width
            placeholderText: "Search city…"
            foreground: panel.fg
            font.family: panel.fontName

            onTextChanged: if (root.editingLocation) geocodeDebounce.restart()

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.cancelEditingLocation()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                if (root.suggestionIndex > 0) root.suggestionIndex--
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.pickSuggestion(root.locationSuggestions[root.suggestionIndex])
                event.accepted = true
              }
            }
          }

          Column {
            visible: root.editingLocation && root.locationSuggestions.length > 0
            width: parent.width
            spacing: 0

            Repeater {
              model: root.locationSuggestions

              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: suggestionRow.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: index === root.suggestionIndex ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent"

                Row {
                  id: suggestionRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: index === root.suggestionIndex ? Style.hoverStateColor(panel.fg, Color.accent) : panel.fg
                    font.family: panel.fontName
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: modelData.description
                    color: Qt.darker(panel.fg, 1.5)
                    font.family: panel.fontName
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.pickSuggestion(modelData)
                }
              }
            }
          }
        }

        PanelSeparator { foreground: panel.fg }

        // ---- Alerts
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "ALERTS"
            foreground: panel.fg
            fontFamily: panel.fontName
          }

          Toggle {
            width: parent.width
            label: "Azan sound"
            description: root.azanSound === ""
              ? "No sound file set — add one in plugin settings"
              : "Play the azan at prayer time"
            checked: root.soundEnabled
            foreground: panel.fg
            fontFamily: panel.fontName
            onClicked: {
              if (checked) root.stopAzan()
              root.mergeState({ soundEnabled: !checked })
            }
          }

          Toggle {
            width: parent.width
            label: "Reminder"
            description: root.reminderMinutes > 0
              ? "Notify " + root.reminderMinutes + " minutes before each azan"
              : "Set reminder minutes in plugin settings"
            checked: root.reminderEnabled && root.reminderMinutes > 0
            foreground: panel.fg
            fontFamily: panel.fontName
            onClicked: root.mergeState({ reminderEnabled: !root.reminderEnabled })
          }

          Row {
            spacing: Style.spacing.md

            Button {
              text: root.playing ? "Stop azan" : "Test azan"
              iconText: root.playing ? "󰓛" : "󰐊"   // stop / play
              foreground: panel.fg
              fontFamily: panel.fontName
              bordered: true
              onClicked: root.playing ? root.stopAzan() : root.testAzan()
            }
          }
        }
      }
    }
  }
}
