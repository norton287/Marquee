import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'models.dart';

/// One row in the car's media browser.
@immutable
class CarNode {
  const CarNode(this.id, this.title,
      {this.subtitle, this.art, this.playable = false, this.browsable = false});
  final String id;
  final String title;
  final String? subtitle;
  final Uri? art;
  final bool playable;
  final bool browsable;
}

/// What Android Auto shows: four tabs over every signed-in server's visible
/// music libraries, plus voice search. Pure Dart over [MediaBackend]s so it
/// can be tested without a car.
///
/// Ids (opaque to the car): `root`, `tab:recent|playlists|artists|albums`,
/// `shuffle:all`, `<kind>:<serverId>:<itemId>` for albums, artists,
/// playlists and tracks, `shuffle:<serverId>:<playlistId>`, and a track
/// inside something it plays from: `track:<s>:<id>@<album|playlist>:<id>`.
class CarLibrary {
  CarLibrary(this.backends, this.visibleLibraries,
      {this.reconnect,
      this.timeout = const Duration(seconds: 12),
      this.probeAfter = const Duration(milliseconds: 1500),
      this.only,
      this.isHidden});

  /// Whether the user hid a library (from settings: no network needed).
  final bool Function(String serverId, String libraryId)? isHidden;

  /// The one library the car uses (`<serverId>/<libraryId>`, Settings →
  /// Android Auto), or null for all. Other servers aren't contacted at all;
  /// if that server is gone or the library hidden, all are used.
  final String? Function()? only;

  /// The chosen library, when its server is signed in.
  (String, String)? get _chosen {
    final key = only?.call();
    final slash = key?.indexOf('/') ?? -1;
    if (key == null || slash < 0) return null;
    final server = key.substring(0, slash);
    return backends().containsKey(server)
        ? (server, key.substring(slash + 1))
        : null;
  }

  /// Which servers to ask, and (when one library is chosen) which library.
  /// Decided without the network: asking the server first stalled every tab
  /// on a stale address. A library deleted on the server just lists nothing.
  Future<(Iterable<String>, String?)> _scope() async {
    final all = backends().keys;
    final chosen = _chosen;
    if (chosen == null) return (all, null);
    if (isHidden?.call(chosen.$1, chosen.$2) ?? false) return (all, null);
    return ([chosen.$1], chosen.$2);
  }

  /// A server that hasn't answered by then has its addresses re-checked
  /// while the request carries on (the phone may have left home Wi-Fi: the
  /// saved home address then just hangs until the 10 s connect timeout).
  final Duration probeAfter;

  /// One address check per server at a time, shared by every tab.
  final _probing = <String, Future<void>>{};
  static final _probed = Object();

  Future<void> _probe(String id) {
    final reconnect = this.reconnect;
    if (reconnect == null) return Future.value();
    return _probing[id] ??= reconnect(id)
        .catchError((Object _) {})
        // A block, not `=>`: remove() returns this very future, and
        // whenComplete would wait for it (forever).
        .whenComplete(() {
          _probing.remove(id);
        });
  }

  /// Re-probes a server's addresses (the phone may have left home Wi-Fi).
  final Future<void> Function(String serverId)? reconnect;

  /// The most one server may take (the car shows a spinner meanwhile): a
  /// slow or offline one is then left out rather than holding up a tab.
  final Duration timeout;

  final Map<String, MediaBackend> Function() backends;
  final Future<List<Library>> Function(String serverId) visibleLibraries;

  static const listCap = 500;
  static const shuffleCap = 200;
  static const _recentCap = 50;
  static const _searchCap = 50;

  // -- reading across servers --------------------------------------------------

  /// [read] for every server, each one caught on its own: an offline server
  /// only leaves its own music out.
  Future<List<T>> _each<T>(
      Future<List<T>> Function(String serverId, MediaBackend b) read,
      {Iterable<String>? servers}) async {
    /// [read] at the server's current address. Never holds a server object
    /// across a wait: an address check replaces it and closes the old one's
    /// connection (and two checks can save in turn).
    Future<List<T>> one(String id) async {
      var probed = false;
      Future<void>? check;
      for (var tries = 0; tries < 4; tries++) {
        final b = backends()[id];
        if (b == null) return <T>[];
        final attempt = read(id, b);
        // If it's overtaken, its late error must go nowhere.
        unawaited(attempt.then((_) {}, onError: (Object _) {}));
        try {
          if (probed || reconnect == null) return await attempt;
          try {
            return await attempt.timeout(probeAfter);
          } on TimeoutException {
            // Slow or unreachable: check its addresses while it carries on.
            probed = true;
            check = _probe(id);
            final probe = check.then((_) => _probed);
            final first = await Future.any<Object?>([attempt, probe]);
            if (!identical(first, _probed)) return first as List<T>;
            // Same address: the running read is all there is.
            if (identical(backends()[id], b)) return await attempt;
            continue; // new address: read there
          }
        } catch (e) {
          if (!isConnectionError(e)) rethrow;
          // A check still running may be about to find the working address
          // (the home one failed before it finished): wait for it.
          await check;
          // The address changed meanwhile: try the current one.
          if (!identical(backends()[id], b)) continue;
          if (probed || reconnect == null) rethrow;
          probed = true;
          // Then once more, at the new address or (a passing glitch) the same.
          await (check = _probe(id));
        }
      }
      return <T>[];
    }

    final parts = await Future.wait([
      for (final id in [...(servers ?? (await _scope()).$1)])
        one(id)
            .timeout(timeout, onTimeout: () => <T>[])
            .catchError((Object _) => <T>[]),
    ]);
    return [for (final p in parts) ...p];
  }

  Future<List<T>> _eachMusicLibrary<T>(
      Future<List<T>> Function(MediaBackend b, Library l) read) async {
    final (servers, library) = await _scope();
    return _each(servers: servers, (id, b) async {
      // A lookup still running on an old address fails when that
      // connection is closed (the address just changed): ask once more.
      final libs = (await visibleLibraries(id)
              .catchError((Object _) => visibleLibraries(id)))
          .where((l) =>
              l.kind == LibraryKind.music && (library == null || l.id == library));
      final parts = await Future.wait([
        // A lost connection goes up to [_each] to reconnect; anything else
        // only drops this library.
        for (final l in libs)
          read(b, l).catchError((Object _) => <T>[],
              test: (e) => !isConnectionError(e)),
      ]);
      return [for (final p in parts) ...p];
    });
  }

  static MediaItem _ref(String serverId, String id, MediaKind kind) =>
      MediaItem(serverId: serverId, id: id, kind: kind, title: '');

  static int _byTitle(CarNode a, CarNode b) =>
      a.title.toLowerCase().compareTo(b.title.toLowerCase());

  // -- nodes ---------------------------------------------------------------------

  /// Square artwork for the car (album art for a track where the server has it).
  static Uri? artOf(MediaItem i) {
    final img = i.poster ?? i.thumb;
    return img == null ? null : Uri.tryParse(img.url(320, aspect: 1));
  }

  static CarNode _node(MediaItem i, {String? container, bool playable = false}) {
    final kind = switch (i.kind) {
      MediaKind.album => 'album',
      MediaKind.artist => 'artist',
      MediaKind.playlist => 'playlist',
      _ => 'track',
    };
    final isTrack = kind == 'track';
    return CarNode(
      '$kind:${i.serverId}:${i.id}${isTrack && container != null ? '@$container' : ''}',
      i.title,
      subtitle: switch (i.kind) {
        MediaKind.track => i.grandparentTitle ?? i.parentTitle,
        MediaKind.album => i.parentTitle,
        _ => null,
      },
      art: artOf(i),
      playable: isTrack || playable,
      browsable: !isTrack && !playable,
    );
  }

  static const _tabs = [
    CarNode('tab:recent', 'Recent', browsable: true),
    CarNode('tab:playlists', 'Playlists', browsable: true),
    CarNode('tab:artists', 'Artists', browsable: true),
    CarNode('tab:albums', 'Albums', browsable: true),
  ];

  Future<List<CarNode>> children(String parentId) async {
    switch (parentId) {
      case 'root':
        // The car just opened Marquee: check where each server answers now
        // (home Wi-Fi or Remote Access) before the tabs ask.
        final chosen = _chosen;
        for (final id in chosen == null ? backends().keys : [chosen.$1]) {
          unawaited(_probe(id));
        }
        // Android Auto shows a root of browsable items as tabs (up to four).
        return _tabs;
      case 'tab:recent':
        final albums = await _eachMusicLibrary(
            (b, l) => b.recentMusic(l, limit: 20));
        return [
          const CarNode('shuffle:all', 'Shuffle all', playable: true),
          // One tap plays a recent album.
          for (final a in albums.take(_recentCap)) _node(a, playable: true),
        ];
      case 'tab:playlists':
        final lists = await _each((_, b) => b.musicPlaylists());
        return [for (final p in lists.take(listCap)) _node(p)]..sort(_byTitle);
      case 'tab:artists':
        return _browse(LibraryView.artists);
      case 'tab:albums':
        return _browse(LibraryView.albums);
    }
    final parsed = _parse(parentId);
    if (parsed == null) return const [];
    final (kind, serverId, id, _) = parsed;
    final backend = backends()[serverId];
    if (backend == null) return const [];
    try {
      switch (kind) {
        case 'artist':
          final albums = await backend.children(_ref(serverId, id, MediaKind.artist));
          return [for (final a in albums.take(listCap)) _node(a)];
        case 'album':
          final tracks = await backend.children(_ref(serverId, id, MediaKind.album));
          return [
            for (final t in tracks.take(listCap)) _node(t, container: 'album:$id')
          ];
        case 'playlist':
          final tracks = await backend.playlistTracks(
              _ref(serverId, id, MediaKind.playlist),
              limit: listCap);
          return [
            CarNode('shuffle:$serverId:$id', 'Shuffle', playable: true),
            for (final t in tracks.where((t) => t.kind == MediaKind.track).take(listCap))
              _node(t, container: 'playlist:$id'),
          ];
      }
    } catch (_) {}
    return const [];
  }

  Future<List<CarNode>> _browse(LibraryView view) async {
    final items = await _eachMusicLibrary((b, l) async =>
        (await b.libraryItems(l, limit: listCap, query: LibraryQuery(view: view)))
            .items);
    final kind = view == LibraryView.artists ? MediaKind.artist : MediaKind.album;
    return ([
      for (final i in items)
        if (i.kind == kind) _node(i),
    ]..sort(_byTitle))
        .take(listCap)
        .toList();
  }

  // -- search ----------------------------------------------------------------------

  /// Voice search: tracks, albums and artists across servers; each plays.
  Future<List<CarNode>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final (servers, library) = await _scope();
    final hits = await _each(servers: servers, (_, b) => b.search(q));
    return [
      for (final h in hits)
        // Keep to the chosen library (items that don't say stay).
        if (library == null || h.libraryId == null || h.libraryId == library)
        if (h.kind == MediaKind.track)
          _node(h, container: h.parentId == null ? null : 'album:${h.parentId}')
        else if (h.kind == MediaKind.album || h.kind == MediaKind.artist)
          _node(h, playable: true),
    ].take(_searchCap).toList();
  }

  // -- playing -------------------------------------------------------------------

  /// (kind, serverId, id, container) from an item id.
  static (String, String, String, String?)? _parse(String id) {
    final at = id.indexOf('@');
    final head = at < 0 ? id : id.substring(0, at);
    final parts = head.split(':');
    if (parts.length < 3) return null;
    return (
      parts[0],
      parts[1],
      parts.sublist(2).join(':'),
      at < 0 ? null : id.substring(at + 1),
    );
  }

  /// The queue a tap on [id] plays, and where in it to start.
  Future<(List<MediaItem>, int)?> resolve(String id) async {
    if (id == 'shuffle:all') {
      final tracks = await _eachMusicLibrary(
          (b, l) => b.randomTracks(l, limit: shuffleCap));
      if (tracks.isEmpty) return null;
      return ((tracks..shuffle()).take(shuffleCap).toList(), 0);
    }
    final parsed = _parse(id);
    if (parsed == null) return null;
    final (kind, serverId, itemId, container) = parsed;
    final backend = backends()[serverId];
    if (backend == null) return null;
    // A playlist is read a page at a time: a smart one can match a whole
    // library. Every track the car shows is within that page.
    Future<List<MediaItem>> tracksOf(MediaKind k, String of) async => [
          for (final t in k == MediaKind.playlist
              ? await backend.playlistTracks(_ref(serverId, of, k), limit: listCap)
              : await backend.children(_ref(serverId, of, k)))
            if (t.kind == MediaKind.track) t,
        ];
    try {
      switch (kind) {
        case 'shuffle':
          final tracks = await tracksOf(MediaKind.playlist, itemId);
          return tracks.isEmpty
              ? null
              : ((tracks..shuffle()).take(shuffleCap).toList(), 0);
        case 'album' || 'playlist':
          final tracks = await tracksOf(
              kind == 'album' ? MediaKind.album : MediaKind.playlist, itemId);
          return tracks.isEmpty ? null : (tracks, 0);
        case 'artist':
          final albums =
              await backend.children(_ref(serverId, itemId, MediaKind.artist));
          // All albums at once: one after another made "play <artist>" slow.
          final parts = await Future.wait([
            for (final a in albums)
              tracksOf(MediaKind.album, a.id)
                  .catchError((Object _) => <MediaItem>[]),
          ]);
          final tracks = [for (final p in parts) ...p];
          return tracks.isEmpty ? null : (tracks.take(shuffleCap).toList(), 0);
        case 'track':
          if (container != null) {
            final c = container.split(':');
            final tracks = await tracksOf(
                c.first == 'playlist' ? MediaKind.playlist : MediaKind.album,
                c.sublist(1).join(':'));
            final at = tracks.indexWhere((t) => t.id == itemId);
            if (at >= 0) return (tracks, at);
          }
          final track = await backend.item(itemId, kind: MediaKind.track);
          return ([track], 0);
      }
    } catch (_) {}
    return null;
  }
}
