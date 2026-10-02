pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import ".."

// Playlist / album / Liked Songs page: tinted header with big artwork and
// title, a play button, then the track table. Everything scrolls together.
Item {
    id: root

    required property var app
    readonly property bool active: visible && app.showsWindow
    property var collection: null
    // Track to scroll to and flash once it's loaded (from "Playing from…").
    property string highlightUri: ""
    property string flashUri: ""
    property int highlightPages: 0

    // Title/art may be missing when the page was opened from a bare URI.
    readonly property var meta: tracks.meta
    function field(name) {
        var value = collection ? collection[name] : "";
        return value ? value : (meta && meta[name] ? meta[name] : "");
    }

    function escapeHtml(text) {
        return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }
    function link(uri, name) { return uri ? '<a href="' + escapeHtml(uri) + '">' + escapeHtml(name) + '</a>' : escapeHtml(name); }
    // Older cached album answers only carry the first artist's URI.
    readonly property string ownerMarkup: {
        var artists = field("artists");
        if (Array.isArray(artists) && artists.length > 0)
            return artists.map(function(a) { return root.link(a.uri, a.name); }).join(", ");
        var owner = field("owner");
        var uri = field("artist_uri");
        return uri && owner.indexOf(",") < 0 ? link(uri, owner) : escapeHtml(owner);
    }

    // Find the highlighted track, loading more pages (up to 20, 1000 songs)
    // until it shows up.
    function tryHighlight() {
        if (highlightUri === "" || !collection) return;
        var index = -1;
        for (var i = 0; i < tracks.tracks.length; i++) if (tracks.tracks[i].uri === highlightUri) { index = i; break; }
        if (index >= 0) {
            list.positionViewAtIndex(index, ListView.Center);
            flashUri = highlightUri;
            flashTimer.restart();
            highlightUri = "";
        } else if (!tracks.loadedAll && !tracks.loading && highlightPages < 20) {
            highlightPages++;
            tracks.load(false);
        }
    }
    onHighlightUriChanged: { highlightPages = 0; Qt.callLater(tryHighlight); }

    Timer {
        id: flashTimer
        interval: 2500
        onTriggered: root.flashUri = ""
    }

    readonly property var player: app.service.player
    readonly property color fg: app.fg
    readonly property color dim: app.dim

    CollectionModel {
        id: tracks
        api: root.app.service.api
        active: root.active
        collection: root.collection
        wantAll: root.reordered
        onTracksChanged: {
            var uris = tracks.tracks.map(function(t) { return t.uri; });
            if (tracks.isLiked) root.app.service.likes.markLiked(uris);
            else visibleLikes.restart();
            Qt.callLater(root.tryHighlight);
        }
    }

    // Sorting can load thousands of tracks. Only check hearts near the
    // viewport, in one batch after scrolling or page loading settles.
    function queryVisibleLikes() {
        if (!active || tracks.isLiked) return;
        var uris = [];
        var rowHeight = viewMode === "compact" ? 36 : 56;
        for (var y = list.contentY; y < list.contentY + list.height + rowHeight; y += rowHeight) {
            var index = list.indexAt(20, y);
            if (index >= 0 && index < displayed.length) uris.push(displayed[index].uri);
        }
        app.service.likes.query(uris);
    }
    Timer { id: visibleLikes; interval: 150; onTriggered: root.queryVisibleLikes() }
    onActiveChanged: if (active) visibleLikes.restart()
    onDisplayedChanged: visibleLikes.restart()
    onViewModeChanged: visibleLikes.restart()

    readonly property bool playingThis: collection !== null && player.context
        && player.context.uri === collection.uri
    // --------------------------------------------- sort, view and filter
    // "custom" keeps Spotify's order; anything else (or a filter) reorders
    // locally, which needs every page loaded first.
    property string sortKey: "custom"
    property string viewMode: "list"
    property string filterText: ""
    property bool searchOpen: false
    readonly property bool isAlbum: collection !== null && collection.kind === "album"
    readonly property bool reordered: sortKey !== "custom" || filterText.trim() !== ""
    readonly property var sortLabels: ({
        custom: isAlbum ? "Album order" : "Custom order", title: "Title", artist: "Artist", album: "Album",
        added: "Recently added", release: "Release date", duration: "Duration"
    })

    readonly property var displayed: {
        var list = tracks.tracks;
        var q = filterText.trim().toLowerCase();
        if (q !== "") list = list.filter(function(t) {
            return (t.name + " " + t.artists + " " + t.album).toLowerCase().indexOf(q) >= 0;
        });
        if (sortKey === "custom") return list;
        var by = {
            title: function(a, b) { return a.name.localeCompare(b.name); },
            artist: function(a, b) { return a.artists.localeCompare(b.artists) || a.album.localeCompare(b.album); },
            album: function(a, b) { return a.album.localeCompare(b.album); },
            added: function(a, b) { return (b.added_at || "").localeCompare(a.added_at || ""); },
            release: function(a, b) { return (b.release_date || "").localeCompare(a.release_date || ""); },
            duration: function(a, b) { return (a.duration_ms || 0) - (b.duration_ms || 0); }
        }[sortKey];
        return list.slice().sort(by);
    }

    // Remember sort/view per collection for this session, like Spotify.
    onCollectionChanged: {
        var saved = collection ? app.collectionPrefs[collection.uri] : null;
        sortKey = saved ? saved.sort : "custom";
        viewMode = saved ? saved.view : "list";
        filterText = "";
        searchOpen = false;
    }
    function savePrefs() {
        if (!collection) return;
        var prefs = Object.assign({}, app.collectionPrefs);
        prefs[collection.uri] = { sort: sortKey, view: viewMode };
        app.collectionPrefs = prefs;
    }

    function formatTotal(ms) {
        var minutes = Math.round(ms / 60000);
        var hours = Math.floor(minutes / 60);
        return hours > 0 ? hours + " hr " + (minutes % 60) + " min" : minutes + " min";
    }

    function playRow(track, index) {
        // Radio lists are our own mix, not a Spotify context: always a track list.
        if (!reordered && !isRadio) { tracks.playFrom(player, track, tracks.tracks.indexOf(track)); return; }
        // A local order can't be a Spotify context; play it as a track list.
        tracks.pendingUri = track.uri;
        var uris = displayed.slice(index, index + 100).map(function(t) { return t.uri; });
        app.service.api.play(player.deviceName, { uris: uris }, function() { tracks.pendingUri = ""; });
    }

    function shuffleMenu() {
        var p = root.player;
        return [
            { label: "Shuffle", icon: "󰒝", checked: p.shuffle && !p.smartShuffle,
              action: function() { p.setShuffle(!(p.shuffle && !p.smartShuffle)); } },
            { label: "Smart Shuffle", icon: "󱐋", checked: p.smartShuffle, enabled: false },
            { note: p.smartShuffle
                ? "Smart Shuffle is on: recommendations are mixed into your queue. Turn it off from another Spotify app."
                : "Smart Shuffle adds recommendations to your queue. Soloist can't switch it on; start it from the Spotify app on your phone and it shows here." }
        ];
    }

    function sortMenu() {
        var entries = [{ header: "Sort by" }];
        var keys = isAlbum ? ["custom", "title", "duration"]
            : ["custom", "title", "artist", "album", "added", "release", "duration"];
        keys.forEach(function(k) {
            entries.push({ label: root.sortLabels[k], checked: root.sortKey === k,
                           action: function() { root.sortKey = k; root.savePrefs(); } });
        });
        entries.push({ separator: true }, { header: "View as" });
        entries.push({ label: "Compact", icon: "󰈆", checked: viewMode === "compact",
                       action: function() { root.viewMode = "compact"; root.savePrefs(); } });
        entries.push({ label: "List", icon: "󰷐", checked: viewMode === "list",
                       action: function() { root.viewMode = "list"; root.savePrefs(); } });
        return entries;
    }

    readonly property bool isRadio: collection !== null && collection.kind === "radio"
    readonly property bool showAdded: collection !== null && collection.kind !== "album" && !isRadio && list.width - 32 > 860
    readonly property string kindLabel: !collection ? ""
        : collection.kind === "album" ? "Album" : isRadio ? "Radio" : "Playlist"

    ListView {
        id: list
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.displayed
        cacheBuffer: 800
        onContentYChanged: visibleLikes.restart()
        onHeightChanged: visibleLikes.restart()
        onContentHeightChanged: visibleLikes.restart()
        onAtYEndChanged: if (atYEnd && contentHeight > height) tracks.load(false)

        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        header: Column {
            width: list.width

            // Hero
            Rectangle {
                width: parent.width
                height: 320
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(root.app.accent.r, root.app.accent.g, root.app.accent.b, 0.45) }
                    GradientStop { position: 1; color: Qt.rgba(root.app.accent.r, root.app.accent.g, root.app.accent.b, 0.12) }
                }

                Cover {
                    id: heroArt
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 24
                    width: 232
                    height: 232
                    source: root.field("cover")
                    kind: root.collection ? root.collection.kind : ""
                    foreground: root.fg
                }

                Column {
                    anchors.left: heroArt.right
                    anchors.leftMargin: 24
                    anchors.right: parent.right
                    anchors.rightMargin: 24
                    anchors.bottom: heroArt.bottom
                    spacing: 8

                    Text {
                        text: root.kindLabel
                        color: root.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WordWrap
                        textFormat: Text.PlainText
                        text: root.field("name")
                        color: root.fg
                        font.family: Style.font.family
                        font.pixelSize: text.length > 24 ? 40 : 64
                        font.bold: true
                    }

                    Text {
                        visible: text !== ""
                        width: parent.width
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WordWrap
                        textFormat: Text.PlainText
                        text: root.field("description")
                        color: root.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                    }

                    // An album's artists link to their pages.
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.StyledText
                        linkColor: root.fg
                        text: [root.ownerMarkup, root.escapeHtml(root.field("year")),
                               tracks.total > 0 ? tracks.total + " songs" + (tracks.loadedAll ? ", " + root.formatTotal(tracks.totalMs) : "") : ""]
                            .filter(function(x) { return x; }).join(" • ")
                        onLinkActivated: function(link) { root.app.openUri(link, ""); }
                        HoverHandler { cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
                        color: root.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                    }
                }
            }

            // Actions
            Item {
                width: parent.width
                height: 104

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0; color: Qt.rgba(root.app.accent.r, root.app.accent.g, root.app.accent.b, 0.12) }
                        GradientStop { position: 1; color: "transparent" }
                    }
                }

                PlayCircle {
                    id: bigPlay
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    width: 56
                    accent: root.app.accent
                    glyphColor: root.app.bg
                    playing: root.playingThis && root.player.playing
                    onClicked: {
                        if (root.playingThis) root.player.togglePlay();
                        else if (root.isRadio) { if (root.displayed.length > 0) root.playRow(root.displayed[0], 0); }
                        else root.player.play(root.collection.uri);
                    }
                }

                Row {
                    anchors.left: bigPlay.right
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 20

                    // Shuffle: click opens Shuffle / Smart Shuffle, like Spotify.
                    Item {
                        id: shuffleButton
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        height: 36

                        Text {
                            anchors.centerIn: parent
                            text: "󰒝"
                            color: root.player.shuffle || root.player.smartShuffle ? root.app.accent
                                : shuffleMouse.containsMouse ? root.fg : root.dim
                            font.family: Style.font.family
                            font.pixelSize: 28
                        }

                        // Sparkle marks Smart Shuffle.
                        Text {
                            visible: root.player.smartShuffle
                            anchors.right: parent.right
                            anchors.top: parent.top
                            text: "✦"
                            color: root.app.accent
                            font.pixelSize: 11
                        }

                        Rectangle {
                            visible: root.player.shuffle || root.player.smartShuffle
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            width: 4
                            height: 4
                            radius: 2
                            color: root.app.accent
                        }

                        MouseArea {
                            id: shuffleMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.app.showEntries(root.shuffleMenu(), shuffleButton, 0, shuffleButton.height + 4)
                        }
                    }

                    Text {
                        id: moreButton
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰇘"
                        color: moreMouse.containsMouse ? root.fg : root.dim
                        font.family: Style.font.family
                        font.pixelSize: 28

                        MouseArea {
                            id: moreMouse
                            anchors.fill: parent
                            anchors.margins: -8
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.app.showMenu(root.collection, moreButton, 0, moreButton.height + 4)
                        }
                    }

                    // Spotify's own endless station for this radio.
                    Rectangle {
                        visible: root.isRadio
                        anchors.verticalCenter: parent.verticalCenter
                        width: endlessText.implicitWidth + 32
                        height: 32
                        radius: 16
                        color: "transparent"
                        border.width: 1
                        border.color: endlessMouse.containsMouse ? root.fg : root.dim

                        Text {
                            id: endlessText
                            anchors.centerIn: parent
                            text: "󰐹  Endless radio"
                            color: root.fg
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                        }

                        MouseArea {
                            id: endlessMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.app.service.startRadio(root.collection.uri, root.field("name"))
                        }
                    }
                }

                // Right side: search in this list, sort / view
                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 16

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.searchOpen ? 220 : 32
                        height: 32
                        radius: 4
                        color: root.searchOpen ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1) : "transparent"
                        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                        Text {
                            id: findIcon
                            x: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰍉"
                            color: root.searchOpen ? root.fg : findMouse.containsMouse ? root.fg : root.dim
                            font.family: Style.font.family
                            font.pixelSize: 18

                            MouseArea {
                                id: findMouse
                                anchors.fill: parent
                                anchors.margins: -6
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.searchOpen = !root.searchOpen;
                                    if (root.searchOpen) findInput.forceActiveFocus();
                                    else root.filterText = "";
                                }
                            }
                        }

                        TextInput {
                            id: findInput
                            visible: root.searchOpen
                            anchors.left: findIcon.right
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            clip: true
                            text: root.filterText
                            color: root.fg
                            selectionColor: root.app.accent
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            onTextEdited: root.filterText = text
                            Keys.onEscapePressed: { root.filterText = ""; root.searchOpen = false; }

                            Text {
                                visible: findInput.text === ""
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.isAlbum ? "Search in album" : "Search in playlist"
                                color: root.dim
                                font: findInput.font
                            }
                        }
                    }

                    Item {
                        id: sortButton
                        anchors.verticalCenter: parent.verticalCenter
                        width: sortRow.implicitWidth
                        height: sortRow.implicitHeight

                        Row {
                            id: sortRow
                            spacing: 8

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.sortLabels[root.sortKey]
                                color: sortMouse.containsMouse ? root.fg : root.dim
                                font.family: Style.font.family
                                font.pixelSize: Style.font.bodySmall
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.viewMode === "compact" ? "󰈆" : "󰷐"
                                color: sortMouse.containsMouse ? root.fg : root.dim
                                font.family: Style.font.family
                                font.pixelSize: 18
                            }
                        }

                        MouseArea {
                            id: sortMouse
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.app.showEntries(root.sortMenu(), sortButton, 0, sortButton.height + 8)
                        }
                    }
                }
            }

            // Column headings
            Item {
                width: parent.width
                height: 36

                Text {
                    x: 40
                    anchors.verticalCenter: parent.verticalCenter
                    text: "#"
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Text {
                    x: 96
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Title"
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                // Mirrors TrackRow's column geometry.
                readonly property real rowWidth: list.width - 32
                readonly property real addedRight: rowWidth - 24 - 48 - (root.app.service.api.signedIn ? 12 + 24 : 0) - 24
                readonly property real albumRight: addedRight - (root.showAdded ? 130 : 0) - 24
                readonly property real albumWidth: Math.round((rowWidth - 180) * 0.3)

                Text {
                    visible: parent.rowWidth > 640
                    x: 16 + parent.albumRight - parent.albumWidth
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Album"
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Text {
                    visible: root.showAdded
                    x: 16 + parent.addedRight - 130
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Date added"
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }

                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 16 + 24
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰥔"
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    x: 16
                    width: parent.width - 32
                    height: 1
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
                }
            }

            Item { width: 1; height: 8 }
        }

        delegate: TrackRow {
            required property var modelData
            required property int index
            x: 16
            width: list.width - 32
            track: modelData
            number: index + 1
            current: root.player.item && root.player.item.uri === modelData.uri
            playing: root.player.playing
            pending: tracks.pendingUri === modelData.uri
            showAdded: root.showAdded
            flash: root.flashUri === modelData.uri
            foreground: root.fg
            accent: root.app.accent
            likeable: root.app.service.api.signedIn
            liked: root.app.service.likes.isLiked(modelData.uri)
            onLikeToggled: root.app.service.likes.toggle(modelData.uri)
            onMenuRequested: function(source, x, y) { root.app.showMenu(modelData, source, x, y); }
            compact: root.viewMode === "compact"
            onActivated: {
                if (current) root.player.togglePlay();
                else root.playRow(modelData, index);
            }
        }

        footer: Item {
            width: list.width
            height: 96

            Text {
                anchors.centerIn: parent
                visible: tracks.loading || tracks.error !== ""
                width: parent.width - 48
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: tracks.error !== "" ? tracks.error
                    : root.reordered ? "Loading all " + tracks.total + " songs… (" + tracks.tracks.length + ")"
                    : "Loading…"
                color: tracks.error !== "" ? Color.urgent : root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
        }
    }
}
