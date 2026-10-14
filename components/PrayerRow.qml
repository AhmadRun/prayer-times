import QtQuick
import qs.Commons

// One line of the day's schedule: marker dot, prayer name, time.
// `rowState` is "next" (accent, highlighted), "current" (bold), "past" (dimmed)
// or "upcoming".
Rectangle {
  id: root

  property string name: ""
  property string time: ""
  property string rowState: "upcoming"
  property bool isPrayer: true
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property bool isNext: rowState === "next"
  readonly property color textColor: isNext
    ? Color.accent
    : (rowState === "past" || !isPrayer ? Qt.darker(foreground, 1.5) : foreground)

  width: parent ? parent.width : implicitWidth
  implicitHeight: Style.space(32)
  radius: Style.cornerRadius
  color: isNext ? Style.hoverFillFor(foreground, Color.accent) : "transparent"

  Rectangle {
    id: dot
    width: Style.space(6)
    height: width
    radius: width / 2
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    color: root.textColor
    opacity: root.isNext || root.rowState === "current" ? 1 : 0.35
  }

  Text {
    textFormat: Text.PlainText
    text: root.name
    anchors.left: dot.right
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    color: root.textColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: root.isNext || root.rowState === "current"
    font.italic: !root.isPrayer
  }

  Text {
    textFormat: Text.PlainText
    text: root.time
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    color: root.textColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: root.isNext || root.rowState === "current"
  }
}
