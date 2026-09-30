pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// Listening history, like open.spotify.com/recents: plays by day, grouped by
// what they were played from. A group expands to its songs. Spotify only
// keeps 50 plays; older ones come from the log bin/spotify.py keeps on disk,
// a page at a time as you scroll.
Flickable {
    id: root

    required property var app

    property var days: []
    property bool loading: false
    property bool loaded: false
    property string error: ""
    property int revision: 0
    property real loadedAt: 0
    property string pendingUri: ""
    // Paging cursor from the helper: 0 when there's nothing older.
    property real next: 0
    property bool loadingMore: false
    // "<date>/<group index>" -> true for the expanded groups.
    property var expanded: ({})

    readonly property var player: app.service.player

    function load(reset) {
        if (reset) { revision++; loading = false; loadingMore = false; days = []; next = 0; loaded = false; error = ""; }
        if (loading || !app.service.api.signedIn) return;
        loading = true;
        var requestedRevision = revision;
        app.service.api.call(["history"], function(result) {
            if (requestedRevision !== root.revision) return;
            root.loading = false;
            if (!result.ok) { root.error = result.error; return; }
            root.error = "";
            root.days = result.days;
            root.next = result.next || 0;
            root.queryLikes(result.days);
            root.loaded = true;
            root.loadedAt = Date.now();
        });
    }

    function loadMore() {
        if (loadingMore || loading || !next) return;
        loadingMore = true;
        var requestedRevision = revision;
        app.service.api.call(["history", String(next)], function(result) {
            if (requestedRevision !== root.revision) return;
            root.loadingMore = false;
            if (!result.ok) { root.error = result.error; return; }
            root.days = root.days.concat(result.days);
            root.next = result.next || 0;
            root.queryLikes(result.days);
        });
    }

    function queryLikes(days) {
        var uris = [];
        days.forEach(function(d) { d.groups.forEach(function(g) { g.tracks.forEach(function(t) { uris.push(t.uri); }); }); });
        app.service.likes.query(uris);
    }

    // Fetch the next page before the end comes into view.
    function nearEnd() { if (visible && loaded && next && contentY + height > contentHeight - 800) loadMore(); }
    onContentYChanged: nearEnd()
    onContentHeightChanged: nearEnd()

    function toggle(key) {
        var next = Object.assign({}, expanded);
        if (next[key]) delete next[key];
        else next[key] = true;
        expanded = next;
    }

    function dayTitle(iso) {
        var parts = iso.split("-");
        var date = new Date(+parts[0], +parts[1] - 1, +parts[2]);
        var today = new Date();
        today.setHours(0, 0, 0, 0);
        var days = Math.round((today.getTime() - date.getTime()) / 86400000);
        if (days === 0) return "Today";
        if (days === 1) return "Yesterday";
        return Qt.formatDate(date, days < 7 ? "dddd" : "dddd d MMMM");
    }

    function groupSubtitle(group) {
        var count = group.tracks.length;
        var played = count + (count === 1 ? " song played" : " songs played");
        var item = group.item;
        if (!item) return "";
        if (item.kind === "artist") return "Artist • " + played;
        if (item.kind === "album") return ["Album", item.owner, played].filter(function(x) { return x; }).join(" • ");
        return [played, "Playlist", item.owner].filter(function(x) { return x; }).join(" • ");
    }

    function playTrack(tracks, index) {
        pendingUri = tracks[index].uri;
        app.service.api.play(player.deviceName, { uris: tracks.slice(index).map(function(t) { return t.uri; }) },
                             function() { root.pendingUri = ""; });
    }

    onVisibleChanged: if (visible && (!loaded || Date.now() - loadedAt > 2 * 60 * 1000)) load()

    Connections {
        target: root.app.service.api
        function onSessionReset() { root.load(true); }
        function onSignedInChanged() { if (root.visible && root.app.service.api.signedIn) root.load(); }
        function onCacheCleared(group) { if (group !== "lyrics" && root.visible) root.load(true); }
    }

    clip: true
    contentHeight: content.implicitHeight + 48
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    Column {
        id: content
        x: Math.max(20, (root.width - 760) / 2)
        y: 28
        width: Math.min(760, root.width - 40)
        spacing: 8

        Text {
            bottomPadding: 8
            text: "Recents"
            color: root.app.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
            font.bold: true
        }

        Text {
            visible: !root.app.service.api.signedIn
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Sign in with Spotify in Settings to see what you played."
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

        Text {
            visible: root.loading && !root.loaded
            text: "Loading…"
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Text {
            visible: root.loaded && root.days.length === 0
            text: "Nothing played yet."
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }

        Repeater {
            model: root.days

            Column {
                id: day
                required property var modelData
                width: content.width
                topPadding: 16
                spacing: 4

                Text {
                    bottomPadding: 8
                    text: root.dayTitle(day.modelData.date)
                    color: root.app.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    font.bold: true
                }

                Repeater {
                    model: day.modelData.groups

                    Column {
                        id: group
                        required property var modelData
                        required property int index
                        readonly property string key: day.modelData.date + "/" + index
                        readonly property bool open: !!root.expanded[key]
                        readonly property var item: modelData.item
                        width: day.width

                        Rectangle {
                            id: groupRow
                            width: parent.width
                            height: 72
                            radius: 4
                            color: rowHover.hovered ? Qt.rgba(root.app.fg.r, root.app.fg.g, root.app.fg.b, 0.08) : "transparent"

                            HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: group.item ? root.app.openItem(group.item) : root.toggle(group.key)
                            }
                            TapHandler {
                                acceptedButtons: Qt.RightButton
                                enabled: group.item !== null
                                onTapped: function(point) { root.app.showMenu(group.item, groupRow, point.position.x, point.position.y); }
                            }

                            Cover {
                                id: groupArt
                                x: 4
                                anchors.verticalCenter: parent.verticalCenter
                                width: 64
                                height: 64
                                source: group.item && group.item.cover ? group.item.cover : group.modelData.tracks[0].cover_large || ""
                                kind: group.item ? group.item.kind : "album"
                                foreground: root.app.fg
                            }

                            Column {
                                anchors.left: groupArt.right
                                anchors.leftMargin: 12
                                anchors.right: chevron.left
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: group.item ? group.item.name
                                        : group.modelData.tracks.length + (group.modelData.tracks.length === 1 ? " song played" : " songs played")
                                    color: group.item && root.app.isPlayingUri(root.app.resolveUri(group.item)) ? root.app.accent : root.app.fg
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.body
                                }

                                Text {
                                    visible: text !== ""
                                    width: parent.width
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: root.groupSubtitle(group.modelData)
                                    color: root.app.dim
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall
                                }
                            }

                            Text {
                                id: chevron
                                anchors.right: parent.right
                                anchors.rightMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                text: group.open ? "󰅃" : "󰅀"
                                color: chevronMouse.containsMouse ? root.app.fg : root.app.dim
                                font.family: Style.font.family
                                font.pixelSize: 22

                                MouseArea {
                                    id: chevronMouse
                                    anchors.fill: parent
                                    anchors.margins: -10
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggle(group.key)
                                }
                            }
                        }

                        Repeater {
                            model: group.open ? group.modelData.tracks : []

                            TrackRow {
                                required property var modelData
                                required property int index
                                x: 4
                                width: group.width - 8
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
                                onActivated: current ? root.player.togglePlay() : root.playTrack(group.modelData.tracks, index)
                            }
                        }
                    }
                }
            }
        }

        Text {
            visible: root.loaded && root.days.length > 0
            topPadding: 24
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.loadingMore ? "Loading…"
                : root.next ? ""
                : "That's everything. Spotify keeps only your last 50 plays; older ones are from the history this app saves while it runs."
            color: root.app.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
    }
}
