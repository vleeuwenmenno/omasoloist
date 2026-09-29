import QtQuick
import QtQuick.Controls as Controls

// Spotify's "File quality" card, opened from the quality label under the
// playing track in the app window's player bar.
Controls.Popup {
    id: root

    required property var app

    // Bottom edge stays put, so the card grows upwards as details load.
    property real anchorBottom: 0
    y: anchorBottom - height

    padding: 0
    width: 360
    modal: false
    focus: true
    closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside

    background: Rectangle {
        radius: 8
        color: Qt.lighter(root.app.bg, 1.35)
        border.width: 1
        border.color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.08)
    }

    contentItem: QualityCard {
        app: root.app
        active: root.opened
        innerWidth: 324
        onSettingsRequested: {
            root.close();
            root.app.navigate({ kind: "settings" });
        }
    }
}
