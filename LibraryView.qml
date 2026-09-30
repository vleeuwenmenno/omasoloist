pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui as Ui

// "Your Library": Liked Songs first, then the user's playlists, saved albums
// and followed artists, with Spotify's Playlists / Artists / Albums filter
// chips. Selecting an entry opens it in `openCollection`; the play button
// starts it directly.
Item {
    id: root

    required property QtObject bar
    required property var api
    required property var controller
    property color foreground: Color.foreground
    property string glyph: ""

    // The app window embeds these views without the popup's back button.
    property bool showBack: true

    signal back()
    signal openCollection(var collection)
    signal rowMenuRequested(var entry, var source, real x, real y)

    readonly property color dim: Qt.darker(foreground, 1.45)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    // Each kind pages on its own; "All" walks them in this order.
    readonly property var kinds: ["playlist", "album", "artist"]
    property var sources: emptySources()
    property bool loading: false
    property string error: ""
    property int retries: 0
    property int revision: 0
    property bool initialized: false
    property bool freshPages: false
    // "" (all), "playlist", "album" or "artist".
    property string filter: ""
    onFilterChanged: { list.positionViewAtBeginning(); load(false); }

    readonly property var playlists: sources.playlist.items
    readonly property bool loadedAll: kinds.every(function(k) { return root.sources[k].done; })

    function emptySources() {
        return { playlist: { items: [], done: false, cursor: "" },
                 album: { items: [], done: false, cursor: "" },
                 artist: { items: [], done: false, cursor: "" } };
    }

    Timer {
        id: retryTimer
        interval: 3000
        onTriggered: root.load(true)
    }

    readonly property var likedSongs: ({
        kind: "liked", name: "Liked Songs", uri: root.controller.likedSongsUri,
        owner: "Playlist", cover: "", count: -1
    })
    readonly property var rows: filter === "album" ? sources.album.items
        : filter === "artist" ? sources.artist.items
        : filter === "playlist" ? [likedSongs].concat(sources.playlist.items)
        : [likedSongs].concat(sources.playlist.items, sources.album.items, sources.artist.items)

    // The kind the next page comes from: the filtered one, or in "All" the
    // first that isn't complete.
    function nextKind() {
        if (filter !== "") return sources[filter].done ? "" : filter;
        for (var i = 0; i < kinds.length; i++) if (!sources[kinds[i]].done) return kinds[i];
        return "";
    }

    function load(reset, fresh) {
        if (reset) {
            revision++;
            loading = false;
            initialized = false;
            sources = emptySources();
            error = "";
            freshPages = !!fresh;
            retryTimer.stop();
        }
        if (!api || !api.signedIn) return;
        var kind = nextKind();
        if (loading || kind === "") return;
        var source = sources[kind];
        var args = kind === "playlist" ? ["playlists", String(source.items.length)]
            : kind === "album" ? ["saved-albums", String(source.items.length)]
            : ["followed-artists", source.cursor];
        loading = true;
        initialized = true;
        var requestedRevision = revision;
        error = "";
        api.call((freshPages ? ["--fresh"] : []).concat(args), function(result) {
            // The view may be gone by now (shell reload, popup rebuilt).
            if (!root || requestedRevision !== root.revision) return;
            root.loading = false;
            if (!result.ok) {
                root.error = result.error;
                if (!result.rateLimited && !result.cancelled && kind === "playlist" && root.playlists.length === 0 && root.retries < 3) { root.retries++; retryTimer.restart(); }
                return;
            }
            root.retries = 0;
            var next = Object.assign({}, root.sources);
            next[kind] = {
                items: source.items.concat(result.items.map(function(p) { return Object.assign({ kind: kind }, p); })),
                done: !result.next,
                cursor: result.cursor || ""
            };
            root.sources = next;
            // Keep filling until the list can scroll, so "All" reaches albums
            // and artists without a scroll past a short playlist list.
            Qt.callLater(function() { if (root && requestedRevision === root.revision && list.contentHeight <= list.height) root.load(false); });
        });
    }

    // The app window creates this view already visible, so load on
    // completion too; the popup loads when it is first opened.
    // Load as soon as sign-in is known, visible or not: the app window
    // builds this view hidden at shell start, often before the sign-in
    // check finishes, and a hidden item may never see a visibility change.
    // Answers are cached, so an early load costs nothing.
    onVisibleChanged: ensureLoaded()
    Component.onCompleted: ensureLoaded()
    function ensureLoaded() { if (!initialized && !loading) load(true); }

    function subtitle(entry) {
        if (entry.kind === "liked") return "Playlist";
        if (entry.kind === "artist") return "Artist";
        if (entry.kind === "album") return "Album · " + (entry.owner || "");
        return "Playlist · " + entry.owner + (entry.count > 0 ? " · " + entry.count + " songs" : "");
    }
    Connections {
        target: root.api
        function onSignedInChanged() { if (root.api.signedIn) root.load(true); }
        function onCheckedChanged() { root.ensureLoaded(); }
        function onSessionReset() { root.load(true); }
        function onCacheCleared(group) { if (group === "api" || group === "all" || group === "images") root.load(true); }
        function onLibraryChanged(uri) {
            if (uri.indexOf("spotify:track:") !== 0 && uri.indexOf("spotify:episode:") !== 0) root.load(true);
        }
    }

    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        height: backButton.implicitHeight

        Ui.Button {
            id: backButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showBack
            width: visible ? implicitWidth : 0
            iconText: "󰁍"
            foreground: root.foreground
            tooltipText: "Back to player"
            onClicked: root.back()
        }

        Text {
            anchors.left: backButton.right
            anchors.leftMargin: root.showBack ? Style.space(6) : Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Your Library"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
        }

        // Reload, skipping the on-disk cache (new playlists from other apps).
        Ui.Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.api && root.api.signedIn
            iconText: "󰑐"
            iconSpinning: root.loading
            foreground: root.dim
            tooltipText: "Refresh library"
            onClicked: root.load(true, true)
        }
    }

    Ui.PanelSeparator {
        id: separator
        anchors.top: header.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.foreground
    }

    // Filter chips, like Spotify's: pick one to show only that kind; the ×
    // goes back to everything.
    Row {
        id: chips
        visible: root.api.signedIn
        anchors.top: separator.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        height: visible ? Style.space(30) : 0
        spacing: Style.space(6)

        Rectangle {
            visible: root.filter !== ""
            width: height
            height: parent.height
            radius: height / 2
            color: clearHover.hovered ? Style.selectedFillFor(root.foreground, Color.accent)
                : Style.normalFillFor(root.foreground, Color.accent)

            Text {
                anchors.centerIn: parent
                text: "󰅖"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
            HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.filter = "" }
        }

        Repeater {
            model: [{ id: "playlist", label: "Playlists" }, { id: "artist", label: "Artists" }, { id: "album", label: "Albums" }]

            Rectangle {
                id: chip
                required property var modelData
                readonly property bool selected: root.filter === modelData.id
                visible: root.filter === "" || selected
                width: chipLabel.implicitWidth + Style.space(24)
                height: chips.height
                radius: height / 2
                color: selected ? root.foreground
                    : chipHover.hovered ? Style.selectedFillFor(root.foreground, Color.accent)
                    : Style.normalFillFor(root.foreground, Color.accent)

                Text {
                    id: chipLabel
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: chip.modelData.label
                    color: chip.selected ? Color.background : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: chip.selected
                }
                HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.filter = chip.selected ? "" : chip.modelData.id }
            }
        }
    }

    // Web API sign-in
    Column {
        visible: !root.api.signedIn
        anchors.top: separator.bottom
        anchors.topMargin: Style.space(24)
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "Connect your Spotify account"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: !root.api.hasClientId
                ? "Browsing your library needs a Spotify app Client ID. Add {\"clientId\": \"…\"} to "
                  + root.api.configFile + " (redirect URI " + root.api.redirectUri + ")."
                : root.api.signingIn ? "Finish signing in in your browser…"
                : "Sign in once to browse your playlists and Liked Songs."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
        }

        Ui.Button {
            visible: root.api.hasClientId
            anchors.horizontalCenter: parent.horizontalCenter
            bordered: true
            enabled: !root.api.signingIn
            iconText: "󰍂"
            text: root.api.signingIn ? "Waiting for browser…" : "Sign in with Spotify"
            foreground: root.foreground
            horizontalPadding: Style.spacing.panelGap
            onClicked: root.api.login()
        }

        Text {
            visible: root.api.error !== ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.api.error
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
    }

    ListView {
        id: list
        visible: root.api.signedIn
        anchors.top: chips.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows

        onAtYEndChanged: if (atYEnd && contentHeight > height) root.load(false)

        Controls.ScrollBar.vertical: Controls.ScrollBar {
            policy: list.contentHeight > list.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
        }

        delegate: Rectangle {
            id: row
            required property var modelData
            // Delegates can briefly outlive their row while the list rebinds.
            readonly property var entry: modelData || ({})
            readonly property bool playingThis: !!root.controller && !!root.controller.context
                && root.controller.context.uri === entry.uri

            width: list.width
            height: Style.space(56)
            radius: Style.spacing.labelGap
            color: hover.hovered ? Style.normalFillFor(root.foreground, Color.accent) : "transparent"

            HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.openCollection(row.entry) }
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: function(point) { root.rowMenuRequested(row.entry, row, point.position.x, point.position.y); }
            }

            Rectangle {
                id: art
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                height: width
                radius: row.entry.kind === "artist" ? width / 2 : Style.space(3)
                clip: true
                // Liked Songs gets Spotify's purple-to-blue tile.
                gradient: row.entry.kind === "liked" ? likedGradient : null
                color: Style.normalFillFor(root.foreground, Color.accent)

                Gradient {
                    id: likedGradient
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "#450af5" }
                    GradientStop { position: 1; color: "#8e8ee5" }
                }

                Image {
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 128
                    sourceSize.height: 128
                    source: row.entry.cover || ""
                    visible: status === Image.Ready
                }

                Text {
                    anchors.centerIn: parent
                    visible: !row.entry.cover
                    text: row.entry.kind === "liked" ? "󰋑" : row.entry.kind === "artist" ? "󰀄"
                        : row.entry.kind === "album" ? "󰀥" : "󰲸"
                    color: row.entry.kind === "liked" ? "white" : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }
            }

            Ui.Button {
                id: playButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                visible: hover.hovered || row.playingThis
                iconText: row.playingThis && root.controller.playing ? "󰝚" : "󰐊"
                foreground: row.playingThis ? Color.accent : root.foreground
                tooltipText: "Play"
                onClicked: root.controller.play(row.entry.uri)
            }

            Column {
                anchors.left: art.right
                anchors.leftMargin: Style.space(10)
                anchors.right: playButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: row.entry.name || ""
                    color: row.playingThis ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: row.playingThis
                }

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.subtitle(row.entry)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }
            }
        }

        // Wrapped in an Item: sizing a Text footer by its own visibility loops.
        footer: Item {
            width: list.width
            height: footerNote.visible ? footerNote.implicitHeight : 0

            Text {
                id: footerNote
                width: parent.width
                visible: root.loading || root.error !== ""
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(10)
                bottomPadding: Style.space(10)
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.error !== "" ? root.error : "Loading…"
                color: root.error !== "" ? Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }
}
