import QtQuick
import qs.Commons
import qs.Ui

// The suggestion card: held modifiers, the rows that finish a binding, and
// the modifiers that lead deeper. Service.qml feeds it the level and the
// resolved look; every size here is already multiplied by the scale.
BorderSurface {
  id: box

  property var level: ({ held: [], rows: [], deeper: [] })
  property real availableHeight: 800
  property int maxColumns: 0
  property bool showHeader: true
  property bool showFooter: true
  property string emptyText: ""

  property int pad: 14
  property int rowGap: 4
  property int columnGap: 22
  property int keyGap: 10
  property int maxDescWidth: 300
  property int sectionGap: 10
  property int capPadX: 6
  property int capPadY: 2
  property int keyRadius: 0

  property color textColor: Color.popups.text
  property color mutedColor: Util.alpha(Color.popups.text, 0.6)
  property color keyColor: Color.accent
  property color onKeyColor: Color.background
  property string keyStyle: "outlined"
  property font descFont
  property font keyFont

  readonly property var rows: box.level ? box.level.rows : []
  readonly property var held: box.level ? box.level.held : []
  readonly property var deeper: box.level ? box.level.deeper : []

  readonly property bool boxedKeys: box.keyStyle === "outlined" || box.keyStyle === "filled"
  readonly property int capHeight: Math.ceil(keyMetrics.height) + 2 * box.capPadY
  readonly property int rowHeight: Math.max(box.capHeight, Math.ceil(descMetrics.height))

  readonly property int keyColumnWidth: {
    var widest = 0
    for (var i = 0; i < box.rows.length; i++) {
      var label = box.keyStyle === "brackets" ? "[" + box.rows[i].label + "]" : box.rows[i].label
      widest = Math.max(widest, keyMetrics.advanceWidth(label))
    }
    return Math.ceil(widest) + (box.boxedKeys ? 2 * box.capPadX : 0)
  }

  // Height left for rows once the header, footer and padding are taken.
  readonly property int bodyHeight: {
    var chrome = box.borderTop + box.borderBottom + 2 * box.pad
    if (header.visible) chrome += header.implicitHeight + rule.height + 2 * box.sectionGap
    if (footer.visible) chrome += footer.implicitHeight + box.sectionGap
    return Math.max(box.rowHeight, box.availableHeight - chrome)
  }
  readonly property int rowsPerColumn: {
    var n = box.rows.length
    if (n === 0) return 1
    var fit = Math.max(1, Math.floor((box.bodyHeight + box.rowGap) / (box.rowHeight + box.rowGap)))
    var columns = Math.ceil(n / fit)
    if (box.maxColumns > 0) columns = Math.min(columns, box.maxColumns)
    return Math.ceil(n / columns)
  }

  width: box.borderLeft + box.pad + content.implicitWidth + box.pad + box.borderRight
  height: box.borderTop + box.pad + content.implicitHeight + box.pad + box.borderBottom

  FontMetrics { id: keyMetrics; font: box.keyFont }
  FontMetrics { id: descMetrics; font: box.descFont }

  Column {
    id: content
    x: box.borderLeft + box.pad
    y: box.borderTop + box.pad
    spacing: box.sectionGap

    // Held chord: [❖ Super] + [⇧ Shift] + …
    Row {
      id: header
      visible: box.showHeader
      spacing: Math.round(box.sectionGap * 0.6)
      Repeater {
        model: box.held
        delegate: Row {
          required property var modelData
          spacing: header.spacing
          KeyCap {
            anchors.verticalCenter: parent.verticalCenter
            held: true
            label: modelData.label
            keyStyle: box.keyStyle
            keyColor: box.keyColor
            onKeyColor: box.onKeyColor
            capFont: box.keyFont
            padX: box.capPadX
            padY: box.capPadY
            keyRadius: box.keyRadius
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "+"
            color: box.mutedColor
            font: box.descFont
          }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "…"
        color: box.mutedColor
        font: box.descFont
      }
    }

    Rectangle {
      id: rule
      visible: header.visible
      width: Math.max(bodyGrid.width, emptyLabel.visible ? emptyLabel.implicitWidth : 0, footer.visible ? footer.implicitWidth : 0, header.implicitWidth)
      height: Math.max(1, Math.round(box.pad / 14))
      color: Util.alpha(box.mutedColor, 0.25)
    }

    Text {
      id: emptyLabel
      visible: box.rows.length === 0
      text: box.emptyText
      textFormat: Text.PlainText
      color: box.mutedColor
      font: box.descFont
    }

    Grid {
      id: bodyGrid
      visible: box.rows.length > 0
      flow: Grid.TopToBottom
      rows: box.rowsPerColumn
      rowSpacing: box.rowGap
      columnSpacing: box.columnGap

      Repeater {
        model: box.rows
        delegate: Item {
          id: row
          required property var modelData
          implicitWidth: box.keyColumnWidth + box.keyGap + desc.width
          implicitHeight: box.rowHeight

          KeyCap {
            anchors.verticalCenter: parent.verticalCenter
            label: row.modelData.label
            keyStyle: box.keyStyle
            keyColor: box.keyColor
            onKeyColor: box.onKeyColor
            capFont: box.keyFont
            padX: box.capPadX
            padY: box.capPadY
            keyRadius: box.keyRadius
          }
          Text {
            id: desc
            x: box.keyColumnWidth + box.keyGap
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(Math.ceil(implicitWidth), box.maxDescWidth)
            text: row.modelData.desc
            textFormat: Text.PlainText
            elide: Text.ElideRight
            maximumLineCount: 1
            color: box.textColor
            font: box.descFont
          }
        }
      }
    }

    // Modifiers that lead deeper. A count of 0 means only deeper combos
    // follow, drawn as "…"; no count at all when footerCount is "none".
    Row {
      id: footer
      visible: box.showFooter && box.deeper.length > 0
      spacing: Math.round(box.sectionGap * 1.4)
      Repeater {
        model: box.deeper
        delegate: Row {
          required property var modelData
          spacing: Math.round(box.sectionGap * 0.6)
          KeyCap {
            anchors.verticalCenter: parent.verticalCenter
            label: modelData.label
            keyStyle: box.keyStyle
            keyColor: box.keyColor
            onKeyColor: box.onKeyColor
            capFont: box.keyFont
            padX: box.capPadX
            padY: box.capPadY
            keyRadius: box.keyRadius
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: modelData.count !== null && modelData.count !== undefined
            text: modelData.count > 0 ? String(modelData.count) : "…"
            color: box.mutedColor
            font: box.descFont
          }
        }
      }
    }
  }
}
