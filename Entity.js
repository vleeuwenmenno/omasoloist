.pragma library

// Helpers for Soloist's entity shape (see the WebSocket API reference):
// { uri, entity_type, decorations: { identity, visual_identity, parent, creators, playback } }

function name(entity) {
    return entity && entity.decorations && entity.decorations.identity
        ? (entity.decorations.identity.name || "") : "";
}

function creators(entity) {
    if (!entity || !entity.decorations || !entity.decorations.creators) return "";
    return entity.decorations.creators.map(function(c) { return name(c.entity); })
        .filter(function(n) { return n !== ""; }).join(", ");
}

function cover(entity, size) {
    var covers = entity && entity.decorations && entity.decorations.visual_identity
        ? (entity.decorations.visual_identity.cover || []) : [];
    for (var i = 0; i < covers.length; i++) if (covers[i].size === size) return covers[i].url;
    return covers.length > 0 ? covers[covers.length - 1].url : "";
}

function duration(entity) {
    return entity && entity.decorations && entity.decorations.playback
        ? (entity.decorations.playback.duration_ms || 0) : 0;
}

// Build an entity from the helper's flat Web API track
// ({uri, name, artists, album, cover, cover_small, duration_ms}).
function fromTrack(track) {
    if (!track || !track.uri) return null;
    var covers = [];
    if (track.cover_small) covers.push({ url: track.cover_small, size: "small" });
    if (track.cover) covers.push({ url: track.cover, size: track.cover_small ? "large" : "small" });
    return {
        uri: track.uri,
        entity_type: "track",
        decorations: {
            identity: { name: track.name || "" },
            visual_identity: { cover: covers },
            parent: { entity: { uri: track.album_uri || "", decorations: { identity: { name: track.album || "" } } } },
            creators: (track.artists ? [{ entity: { uri: track.artist_uri || "", decorations: { identity: { name: track.artists } } } }] : []),
            playback: { duration_ms: track.duration_ms || 0 }
        }
    };
}

// URI of the first credited artist, e.g. "spotify:artist:…".
function artistUri(entity) {
    var creators = entity && entity.decorations ? entity.decorations.creators || [] : [];
    return creators.length > 0 && creators[0].entity ? (creators[0].entity.uri || "") : "";
}

// First credited artist's name (creators() joins all of them).
function firstArtist(entity) {
    var creators = entity && entity.decorations ? entity.decorations.creators || [] : [];
    return creators.length > 0 ? name(creators[0].entity) : "";
}

// URI of the album a track belongs to.
function albumUri(entity) {
    var parent = entity && entity.decorations ? entity.decorations.parent : null;
    return parent && parent.entity ? (parent.entity.uri || "") : "";
}
