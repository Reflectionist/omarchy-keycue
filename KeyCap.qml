import QtQuick
import qs.Commons

// One key, drawn in the configured key style:
//   outlined  tinted outline; `held` (header modifiers) is filled
//   filled    solid key colour
//   plain     just the label in the key colour
//   brackets  "[label]" in the key colour
Rectangle {
  id: cap

  property string label: ""
  property bool held: false
  property string keyStyle: "outlined"
  property color keyColor: Color.accent
  // Text drawn on a filled key.
  property color onKeyColor: Color.background
  property font capFont
  property int padX: 6
  property int padY: 2
  property int keyRadius: 0

  readonly property bool boxed: cap.keyStyle === "outlined" || cap.keyStyle === "filled"
  readonly property bool solid: cap.keyStyle === "filled" || (cap.keyStyle === "outlined" && cap.held)

  implicitHeight: Math.ceil(metrics.height) + 2 * cap.padY
  implicitWidth: cap.boxed
    ? Math.max(cap.implicitHeight, Math.ceil(capText.implicitWidth) + 2 * cap.padX)
    : Math.ceil(capText.implicitWidth)
  radius: cap.keyRadius
  color: cap.solid ? cap.keyColor : (cap.boxed ? Util.alpha(cap.keyColor, 0.12) : "transparent")
  border.width: cap.boxed && !cap.solid ? 1 : 0
  border.color: Util.alpha(cap.keyColor, 0.4)

  FontMetrics {
    id: metrics
    font: cap.capFont
  }

  Text {
    id: capText
    anchors.centerIn: parent
    text: cap.keyStyle === "brackets" ? "[" + cap.label + "]" : cap.label
    textFormat: Text.PlainText
    color: cap.solid ? cap.onKeyColor : cap.keyColor
    font: cap.capFont
  }
}
