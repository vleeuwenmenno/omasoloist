pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Spotify-style right-click menu, drawn with the theme tokens. `entries`
// is a list of {label, icon, action, enabled, separator, submenu, checked,
// external, header, note}: `header` is a small section title ("Sort by"), `note` a
// line of explanatory text, `checked` marks the current choice. An entry
// with `submenu` (a list of the same shape, or a function returning one)
// opens a second menu beside it.
Controls.Popup {
    id: root

    required property var app
    property var entries: []
    property var submenuEntries: []
    property real submenuY: 0
    property int submenuIndex: -1

    function show(list, x, y) {
        entries = list;
        submenuEntries = [];
        sub.close();
        // Keep the menu inside the window.
        var w = implicitWidth, h = implicitHeight;
        root.x = Math.max(8, Math.min(x, parent.width - w - 8));
        root.y = Math.max(8, Math.min(y, parent.height - h - 8));
        open();
    }

    function run(entry) {
        if (!entry || entry.enabled === false || entry.separator || entry.header || entry.note) return;
        if (entry.submenu) return;
        close();
        if (entry.action) entry.action();
    }

    padding: 4
    width: 280
    modal: false
    focus: true
    closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
    onClosed: sub.close()

    background: Rectangle {
        radius: 6
        color: Qt.lighter(root.app.bg, 1.35)
        border.width: 1
        border.color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.08)
    }

    component MenuRow: Rectangle {
        id: menuRow
        required property var entry
        property bool open: false
        signal activated()
        signal hoveredRow()

        readonly property bool passive: !!entry.separator || !!entry.header || !!entry.note

        width: parent ? parent.width : 0
        height: entry.separator ? 9 : entry.header ? 30 : entry.note ? noteText.implicitHeight + 12 : 40
        radius: 3
        color: !passive && (rowMouse.containsMouse || open) && entry.enabled !== false
            ? Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.1) : "transparent"

        Rectangle {
            visible: !!menuRow.entry.separator
            anchors.centerIn: parent
            width: parent.width - 8
            height: 1
            color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.1)
        }

        Text {
            visible: !!menuRow.entry.header
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            text: menuRow.entry.header || ""
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
        }

        Text {
            id: noteText
            visible: !!menuRow.entry.note
            x: 12
            y: 6
            width: parent.width - 24
            wrapMode: Text.WordWrap
            text: menuRow.entry.note || ""
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }

        Text {
            id: rowIcon
            visible: !menuRow.passive
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            horizontalAlignment: Text.AlignHCenter
            text: menuRow.entry.icon || ""
            color: menuRow.entry.accent ? root.app.accent : root.app.dim
            font.family: Style.font.family
            font.pixelSize: 16
        }

        Text {
            visible: !menuRow.passive
            anchors.left: rowIcon.right
            anchors.leftMargin: 12
            anchors.right: arrow.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: menuRow.entry.label || ""
            color: menuRow.entry.enabled === false ? root.app.dim : menuRow.entry.checked ? root.app.accent : root.app.fg
            opacity: menuRow.entry.enabled === false ? 0.5 : 1
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            id: arrow
            visible: !!menuRow.entry.submenu || !!menuRow.entry.checked || !!menuRow.entry.external
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            // ✓ current choice, ↗ opens the browser, › submenu.
            text: menuRow.entry.checked ? "󰄬" : menuRow.entry.external ? "󰏌" : "󰍟"
            color: menuRow.entry.checked ? root.app.accent : root.app.dim
            font.family: Style.font.family
            font.pixelSize: 14
        }

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: !menuRow.passive
            hoverEnabled: true
            cursorShape: menuRow.entry.enabled === false ? Qt.ArrowCursor : Qt.PointingHandCursor
            onEntered: menuRow.hoveredRow()
            onClicked: menuRow.activated()
        }
    }

    contentItem: Column {
        id: column

        Repeater {
            model: root.entries

            MenuRow {
                id: row
                required property var modelData
                required property int index
                entry: modelData
                open: sub.opened && root.submenuIndex === index
                onHoveredRow: {
                    if (!modelData.submenu) { sub.close(); return; }
                    if (sub.opened && root.submenuIndex === index) return;
                    root.submenuEntries = typeof modelData.submenu === "function" ? modelData.submenu() : modelData.submenu;
                    root.submenuIndex = index;
                    root.submenuY = row.y;
                    sub.open();
                }
                onActivated: {
                    if (modelData.submenu) onHoveredRow();
                    else root.run(modelData);
                }
            }
        }
    }

    // Submenu, opened to the right (or left when there's no room).
    Controls.Popup {
        id: sub
        padding: 4
        width: 260
        height: Math.min(implicitHeight, 360)
        x: root.x + root.width + 260 < root.parent.width ? root.width - 4 : -width + 4
        y: root.submenuY
        closePolicy: Controls.Popup.NoAutoClose

        background: Rectangle {
            radius: 6
            color: Qt.lighter(root.app.bg, 1.35)
            border.width: 1
            border.color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.08)
        }

        contentItem: Flickable {
            implicitHeight: subColumn.implicitHeight
            contentHeight: subColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: subColumn
                width: parent.width

                Repeater {
                    model: root.submenuEntries

                    MenuRow {
                        required property var modelData
                        entry: modelData
                        onActivated: root.run(modelData)
                    }
                }
            }
        }
    }
}
