pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Search, laid out like Spotify's: filter chips, a wide top-result banner,
// "Featuring …" playlists, songs, then shelves. A chip other than "All"
// switches to a paged list (songs) or grid (artists, albums, playlists).
Flickable {
    id: root

    required property var app
    property string query: ""
    property string filter: "all"

    property var results: null
    property var filtered: []
    property bool filteredNext: false
    property bool loading: false
    property string error: ""
    property string pendingUri: ""
    property string lastKey: ""
    property int revision: 0

    readonly property var player: app.service.player

    function uris(list) { return (list || []).map(function(t) { return t.uri; }); }
    onResultsChanged: if (results) app.service.likes.query(uris(results.tracks))
    onFilteredChanged: if (filter === "track") app.service.likes.query(uris(filtered))
    readonly property var filters: [
        { id: "all", label: "All" },
        { id: "track", label: "Songs" },
        { id: "album", label: "Albums" },
        { id: "playlist", label: "Playlists" },
        { id: "artist", label: "Artists" }
    ]
    readonly property var resultKey: ({ track: "tracks", album: "albums", playlist: "playlists", artist: "artists" })

    onQueryChanged: debounce.restart()
    onFilterChanged: { contentY = 0; search(); }

    Timer {
        id: debounce
        interval: 350
        onTriggered: root.search()
    }

    function search() {
        if (!app.service.api.signedIn) return;
        var q = query.trim();
        var key = q + "\u0000" + filter;
        if (key === lastKey) return;
        lastKey = key;
        error = "";
        if (q === "") { results = null; filtered = []; return; }
        loading = true;
        var requestedRevision = revision;
        var args = filter === "all" ? ["search", q] : ["search", q, filter, "0"];
        app.service.api.call(args, function(result) {
            if (requestedRevision !== root.revision || key !== root.lastKey) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            if (root.filter === "all") {
                root.results = result;
            } else {
                root.filtered = result[root.resultKey[root.filter]];
                root.filteredNext = !!result.next;
            }
        });
    }

    function loadMore() {
        if (filter === "all" || loading || !filteredNext) return;
        loading = true;
        var key = lastKey;
        var requestedRevision = revision;
        app.service.api.call(["search", query.trim(), filter, String(filtered.length)], function(result) {
            if (requestedRevision !== root.revision || key !== root.lastKey) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            root.filtered = root.filtered.concat(result[root.resultKey[root.filter]]);
            root.filteredNext = !!result.next;
        });
    }

    function reset() {
        revision++;
        lastKey = "";
        results = null;
        filtered = [];
        filteredNext = false;
        loading = false;
        error = "";
    }

    Connections {
        target: root.app.service.api
        function onSessionReset() { root.reset(); }
        function onSignedInChanged() { if (root.app.service.api.signedIn) root.search(); }
        function onCacheCleared(group) {
            if (group !== "lyrics") { root.reset(); root.search(); }
        }
    }

    function playTracks(list, index) {
        pendingUri = list[index].uri;
        var uris = list.slice(index).map(function(t) { return t.uri; });
        app.service.api.play(player.deviceName, { uris: uris }, function() { root.pendingUri = ""; });
    }

    // Spotify prefers the artist when the query names one.
    readonly property var topResult: !results ? null
        : results.artists.length > 0 ? results.artists[0]
        : results.albums.length > 0 ? results.albums[0]
        : results.playlists.length > 0 ? results.playlists[0] : null
    readonly property bool topIsArtist: topResult !== null && topResult.kind === "artist"

    clip: true
    contentHeight: content.implicitHeight + 48
    boundsBehavior: Flickable.StopAtBounds
    onContentYChanged: if (contentY + height > contentHeight - 400) loadMore()
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    component Heading: Text {
        leftPadding: 4
        topPadding: 8
        bottomPadding: 8
        textFormat: Text.PlainText
        color: root.app.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
    }

    Column {
        id: content
        x: 24
        y: 16
        width: root.width - 48
        spacing: 24

        // Filter chips
        Row {
            visible: root.query.trim() !== ""
            spacing: 8

            Repeater {
                model: root.filters

                Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool selected: root.filter === modelData.id
                    width: chipText.implicitWidth + 24
                    height: 32
                    radius: 16
                    color: selected ? root.app.fg
                        : Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, chipMouse.containsMouse ? 0.16 : 0.08)

                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: chip.modelData.label
                        color: chip.selected ? root.app.bg : root.app.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                    }

                    MouseArea {
                        id: chipMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.filter = chip.modelData.id
                    }
                }
            }
        }

        Text {
            visible: root.query.trim() === "" || (root.loading && root.results === null && root.filtered.length === 0)
            leftPadding: 4
            text: root.query.trim() === "" ? "Search for songs, artists, albums or playlists." : "Searching…"
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            visible: root.error !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.error
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }

        // ---------------------------------------------------------- "All"
        Column {
            visible: root.filter === "all" && root.results !== null && root.query.trim() !== ""
            width: parent.width
            spacing: 32

            // Top result banner
            Rectangle {
                id: banner
                visible: root.topResult !== null
                width: parent.width
                height: 96
                radius: 8
                color: Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, bannerHover.hovered ? 0.12 : 0.06)

                HoverHandler { id: bannerHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.app.openItem(root.topResult) }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: function(point) { root.app.showMenu(root.topResult, banner, point.position.x, point.position.y); }
                }

                Cover {
                    id: bannerArt
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    width: 64
                    height: 64
                    source: root.topResult ? root.topResult.cover || "" : ""
                    kind: root.topResult ? root.topResult.kind : ""
                    foreground: root.app.fg
                }

                Column {
                    anchors.left: bannerArt.right
                    anchors.leftMargin: 20
                    anchors.right: bannerPlay.left
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.topResult ? root.topResult.name : ""
                        color: root.app.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.display
                        font.bold: true
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: !root.topResult ? "" : root.topIsArtist ? "Artist"
                            : (root.topResult.kind === "album" ? "Album" : "Playlist")
                              + (root.topResult.owner ? " • " + root.topResult.owner : "")
                        color: root.app.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                    }
                }

                PlayCircle {
                    id: bannerPlay
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    width: 48
                    accent: root.app.accent
                    glyphColor: root.app.bg
                    playing: root.topResult !== null && root.app.isPlayingUri(root.topResult.uri) && root.player.playing
                    onClicked: root.app.playItem(root.topResult)
                }
            }

            Shelf {
                width: parent.width
                app: root.app
                title: root.topIsArtist ? "Featuring " + root.topResult.name : "Playlists"
                items: root.results ? root.results.playlists : []
            }

            Column {
                width: parent.width
                visible: root.results !== null && root.results.tracks.length > 0

                Heading { text: "Songs" }

                Repeater {
                    model: root.results ? root.results.tracks.slice(0, 5) : []

                    TrackRow {
                        required property var modelData
                        required property int index
                        width: parent.width
                        track: modelData
                        number: index + 1
                        tag: "Song"
                        showAlbum: false
                        showAdded: false
                        current: root.player.item && root.player.item.uri === modelData.uri
                        playing: root.player.playing
                        pending: root.pendingUri === modelData.uri
                        foreground: root.app.fg
                        accent: root.app.accent
                        likeable: root.app.service.api.signedIn
                        liked: root.app.service.likes.isLiked(modelData.uri)
                        onLikeToggled: root.app.service.likes.toggle(modelData.uri)
                        onMenuRequested: function(source, x, y) { root.app.showMenu(modelData, source, x, y); }
                        onActivated: current ? root.player.togglePlay() : root.playTracks(root.results.tracks, index)
                    }
                }

                Text {
                    visible: root.results !== null && root.results.tracks.length > 5
                    leftPadding: 16
                    topPadding: 8
                    text: "Show all songs"
                    color: root.app.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.filter = "track"
                    }
                }
            }

            Shelf {
                width: parent.width
                app: root.app
                title: "Artists"
                items: root.results ? root.results.artists.slice(root.topIsArtist ? 1 : 0) : []
            }

            Shelf {
                width: parent.width
                app: root.app
                title: "Albums"
                items: root.results ? root.results.albums : []
            }
        }

        // ------------------------------------------------------ Songs chip
        Column {
            visible: root.filter === "track" && root.query.trim() !== ""
            width: parent.width

            Repeater {
                model: root.filter === "track" ? root.filtered : []

                TrackRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    track: modelData
                    number: index + 1
                    showAdded: false
                    current: root.player.item && root.player.item.uri === modelData.uri
                    playing: root.player.playing
                    pending: root.pendingUri === modelData.uri
                    foreground: root.app.fg
                    accent: root.app.accent
                    likeable: root.app.service.api.signedIn
                    liked: root.app.service.likes.isLiked(modelData.uri)
                    onLikeToggled: root.app.service.likes.toggle(modelData.uri)
                    onMenuRequested: function(source, x, y) { root.app.showMenu(modelData, source, x, y); }
                    onActivated: current ? root.player.togglePlay() : root.playTracks(root.filtered, index)
                }
            }
        }

        // ------------------------------------- Artists / Albums / Playlists
        Flow {
            id: grid
            visible: root.filter !== "all" && root.filter !== "track" && root.query.trim() !== ""
            width: parent.width
            readonly property int columns: Math.max(2, Math.floor(width / 168))
            readonly property real cellWidth: width / columns

            Repeater {
                model: grid.visible ? root.filtered : []

                Card {
                    required property var modelData
                    width: grid.cellWidth
                    item: modelData
                    foreground: root.app.fg
                    accent: root.app.accent
                    playingThis: root.app.isPlayingUri(modelData.uri)
                    playing: root.player.playing
                    onOpened: root.app.openItem(modelData)
                    onPlayed: root.app.playItem(modelData)
                    onMenuRequested: function(source, x, y) { root.app.showMenu(modelData, source, x, y); }
                }
            }
        }

        Text {
            visible: root.loading && root.filter !== "all" && root.filtered.length > 0
            leftPadding: 4
            text: "Loading more…"
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
    }
}
