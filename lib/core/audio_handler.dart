import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart' as as_;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'car_library.dart';
import 'car_log.dart';
import 'models.dart';
import 'music_engine.dart';

/// Android's media session for music: the car (Android Auto), the lock
/// screen, the notification and headset buttons all talk to this, and it
/// passes everything to the shared [MusicEngine] and [CarLibrary].
///
/// No QueueHandler/SeekHandler mixins: they edit a queue kept on the handler,
/// while the engine owns the queue.
/// How a car list row gets its art.
enum CarArtMode {
  /// Fetched before the list is answered.
  wait,

  /// Fetched in the background, shown next time.
  background,

  /// Only if fetched before: a long list mustn't start hundreds of downloads.
  cachedOnly,
}

/// Artwork in the car's lists.
abstract final class CarArt {
  /// Rows waited for: about what a car screen shows.
  static const waitFor = 40;

  /// Rows fetched at all (the rest show art once fetched some other way).
  static const prefetchTo = 120;

  static CarArtMode modeFor(int row) => row < waitFor
      ? CarArtMode.wait
      : row < prefetchTo
          ? CarArtMode.background
          : CarArtMode.cachedOnly;
}

/// A car art file's name: a 64-bit FNV-1a hash of the image link, so it is
/// the same every time, can't be guessed by other apps (the link holds the
/// server token), and says nothing about the server.
String carArtName(String url) {
  var h = -3750763034362895579; // 0xcbf29ce484222325
  for (final c in url.codeUnits) {
    h ^= c;
    h *= 0x100000001b3;
  }
  // Two 32-bit halves: a Dart int can't show 64 bits unsigned.
  String half(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '${half(h >> 32)}${half(h)}.jpg';
}

/// Tells Android Auto that a list changed, so it asks for it again.
///
/// audio_service's own `AudioServiceBackground.notifyChildrenChanged` sends
/// no options, its native side passes them on as null, and androidx's
/// `MediaBrowserServiceCompat.notifyChildrenChanged(id, options)` throws
/// "options cannot be null": no redraw ever reached the car. This is the
/// same call on the plugin's own channel (audio_service 0.18.19), with
/// empty options. (`subscribeToChildren` only covers lists the car has
/// already opened: the cold-start root redraw needs this.)
Future<void> notifyCarListChanged(String parentId,
        {MethodChannel channel =
            const MethodChannel('com.ryanheise.audio_service.handler.methods')}) =>
    channel.invokeMethod<void>('notifyChildrenChanged',
        {'parentMediaId': parentId, 'options': <String, dynamic>{}});

class MarqueeAudioHandler extends as_.BaseAudioHandler {
  MarqueeAudioHandler(this.engine, this.library,
      {this.notifyChanged,
      this.localArt,
      this.carArt,
      this.artDeadline = const Duration(seconds: 2),
      this.keepFreshFor = const Duration(minutes: 1),
      this.partialFreshFor = const Duration(seconds: 15),
      this.answerWithin = const Duration(seconds: 8),
      this.log,
      this.remember,
      this.rememberKey,
      this.rememberAfter = const Duration(seconds: 2),
      DateTime Function()? clock})
      : _now = clock ?? DateTime.now {
    _sub = engine.states.listen(_publish);
    _publish(engine.state);
  }

  final MusicEngine engine;
  final CarLibrary library;

  /// The time a play state is stamped with (a fake clock in tests).
  final DateTime Function() _now;

  /// Tells the car a list changed (`AudioService.notifyChildrenChanged` in
  /// the app; recorded in tests).
  final Future<void> Function(String parentId)? notifyChanged;

  /// A local file of a remote image (audio_service's cache in the app).
  /// Artwork links carry the server token (Plex) and a home address, and the
  /// media session is readable by other apps, so only local files go out;
  /// browse rows and the queue get no art.
  final Future<Uri?> Function(Uri remote)? localArt;

  /// A `content://` link to the app's own copy of a remote image, served by
  /// its read-only provider (the car can't use server links, and they carry
  /// the token); null while it isn't there yet (see [CarArtMode]).
  final Future<Uri?> Function(Uri remote, {required CarArtMode mode})? carArt;

  /// The most a car list waits for its artwork.
  final Duration artDeadline;

  /// A kept car list is refreshed in the background at most this often.
  final Duration keepFreshFor;

  /// The same for a list missing a server's part (it timed out or failed):
  /// read again sooner, but not on every look (a server down for good would
  /// be asked, and its address re-checked, each time).
  final Duration partialFreshFor;

  /// A first load that takes longer answers empty (a car that waits too
  /// long says "Could not browse selection") and fills the list in when it
  /// arrives.
  final Duration answerWithin;

  /// What the car asked and what was answered (Settings → Car log).
  final CarLog? log;

  /// Saves the car's lists so they survive a restart: the car often starts
  /// the app itself, and lists that need the server came back empty at first.
  final Future<void> Function(String json)? remember;
  final Duration rememberAfter;

  /// What the remembered lists belong to (car library, servers, profiles):
  /// lists saved for something else aren't restored.
  final String Function()? rememberKey;

  @visibleForTesting
  void forgetTracksForTest() => library.forgetTracks();

  @visibleForTesting
  static String rememberJsonForTest(Map<String, List<as_.MediaItem>> lists, String key) =>
      _rememberJson(lists, key);

  /// Rows saved per list, and about the most saved in all (it lives in the
  /// app's preferences, read at every start).
  static const _rememberRows = 100;
  static const _rememberBytes = 300 * 1024;

  static String _rememberJson(Map<String, List<as_.MediaItem>> lists, String key) {
    final out = <String, Object>{};
    var size = 0;
    // Newest first, so the cap drops the oldest.
    for (final id in lists.keys.toList().reversed) {
      final rows = [for (final m in lists[id]!.take(_rememberRows)) _itemJson(m)];
      size += jsonEncode(rows).length;
      if (size > _rememberBytes) break;
      out[id] = rows;
    }
    return jsonEncode({'v': 1, 'key': key, 'lists': out});
  }

  String? _lastKey;
  Timer? _remembering;

  /// The lists remembered: the menu plus the most recently used ones.
  static const _rememberAtMost = 40;

  static List<Object?> _itemJson(as_.MediaItem m) => [
        m.id,
        m.title,
        m.artist,
        // Only links the car can open (art, app icons); a private file isn't one.
        m.artUri?.scheme == 'content' || m.artUri?.scheme == 'android.resource'
            ? '${m.artUri}'
            : null,
        m.playable ?? false,
        m.extras,
        m.displaySubtitle,
      ];

  void _scheduleRemember() {
    if (remember == null) return;
    _remembering?.cancel();
    _remembering = Timer(rememberAfter, _rememberNow);
  }

  void _rememberNow() {
    _remembering?.cancel();
    _remembering = null;
    final save = remember;
    if (save == null) return;
    final ids = _kept.keys.toList().reversed.take(_rememberAtMost).toList().reversed;
    final json = _rememberJson({for (final id in ids) id: _kept[id]!}, rememberKey?.call() ?? '');
    unawaited(Future(() => save(json)).catchError((Object _) {}));
  }

  /// Lists from the last run: shown at once, refreshed on first look.
  void restore(String? json) {
    if (json == null) return;
    _lastKey = rememberKey?.call();
    try {
      final saved = jsonDecode(json) as Map<String, dynamic>;
      // Saved for another car library, set of servers or profile: not ours.
      if (saved['v'] != 1 || saved['key'] != (rememberKey?.call() ?? '')) return;
      final map = saved['lists'] as Map<String, dynamic>;
      for (final e in map.entries) {
        final list = [
          for (final raw in e.value as List)
            as_.MediaItem(
              id: (raw as List)[0] as String,
              title: raw[1] as String,
              artist: raw[2] as String?,
              artUri: raw[3] == null ? null : Uri.parse(raw[3] as String),
              playable: raw[4] as bool,
              // Saved before looks were kept: none (refreshed when shown).
              extras: raw.length > 5 && raw[5] is Map
                  ? (raw[5] as Map).cast<String, dynamic>()
                  : null,
              // A genre song row's album (saved since 2026-11-23).
              displayTitle: raw.length > 6 && raw[6] != null ? raw[1] as String : null,
              displaySubtitle: raw.length > 6 ? raw[6] as String? : null,
            ),
        ];
        if (list.isEmpty) continue;
        _kept[e.key] = list;
        _keptAt[e.key] = DateTime(0); // stale: refreshed when next shown
      }
    } catch (_) {
      // A bad save: start without it.
    }
  }

  /// Never throws: a failed redraw only means the car shows the old list
  /// (and in main() a throw here once skipped the rest of the session's
  /// start-up). Logged, since every redraw used to fail unseen.
  Future<void> _notify(String id) async {
    log?.add('redraw $id');
    try {
      await notifyChanged?.call(id);
    } catch (e) {
      log?.add('redraw $id failed: $e');
    }
  }

  /// Car lists kept while the app runs (never empty ones: those may be a
  /// dead spot): reopening answers at once, and a background refresh
  /// redraws the car only if something changed. When a track starts, the
  /// car reloads the list it came from while the song starts streaming; a
  /// slow answer then showed as "can't browse".
  final _kept = <String, List<as_.MediaItem>>{};
  final _keptAt = <String, DateTime>{};
  final _refreshing = <String, Future<void>>{};
  final _firstLoads = <String, Future<List<as_.MediaItem>>>{};

  /// Bumped when the kept lists no longer apply, so loads that were already
  /// running don't put old lists back.
  int _epoch = 0;

  int get keptLists => _kept.length;

  /// The most recently used lists kept (a long drive opens many albums).
  static const _keepAtMost = 150;

  void _keep(String id, List<as_.MediaItem> list, int epoch,
      {bool partial = false}) {
    if (list.isEmpty || epoch != _epoch) return;
    _kept.remove(id);
    _kept[id] = list;
    _keptAt[id] = DateTime.now();
    // Missing a server's part: shown, and read again after partialFreshFor.
    partial ? _partial.add(id) : _partial.remove(id);
    _scheduleRemember();
    while (_kept.length > _keepAtMost) {
      final oldest = _kept.keys.first;
      _kept.remove(oldest);
      _keptAt.remove(oldest);
      _partial.remove(oldest);
    }
  }

  static bool _same(List<as_.MediaItem> a, List<as_.MediaItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].title != b[i].title ||
          a[i].artist != b[i].artist ||
          a[i].displayTitle != b[i].displayTitle ||
          a[i].displaySubtitle != b[i].displaySubtitle ||
          a[i].artUri != b[i].artUri ||
          !mapEquals(a[i].extras, b[i].extras)) {
        return false;
      }
    }
    return true;
  }

  /// Kept lists that miss a server's part (it timed out or failed).
  final _partial = <String>{};

  /// A list, and whether a server's part is missing from it (logged).
  Future<(List<as_.MediaItem>, bool)> _load(String parentId) async {
    final (nodes, misses) = await library.childrenNoting(parentId);
    for (final m in misses) {
      log?.add('list $parentId: $m');
    }
    return (await _withArt(nodes), misses.isNotEmpty);
  }

  Future<void> _refresh(String id) => _refreshing[id] ??= () async {
        final epoch = _epoch;
        try {
          final (fresh, partial) = await _load(id);
          final old = _kept[id];
          if (fresh.isEmpty || epoch != _epoch) return;
          // Missing a server's part replaces a complete list too: while that
          // server is out, its rows wouldn't play anyway.
          _keep(id, fresh, epoch, partial: partial);
          if (old == null || !_same(old, fresh)) await _notify(id);
        } catch (_) {
          // Keep showing what was there.
        } finally {
          _refreshing.remove(id);
        }
      }();

  late final StreamSubscription<MusicState> _sub;
  List<MediaItem>? _lastQueue;

  // -- browsing --------------------------------------------------------------

  /// Android Auto's description extras for looks (content styles, headings).
  static const browsableHint = 'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
  static const playableHint = 'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
  static const groupHint = 'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';

  /// The car's root extras (AudioServiceConfig.androidBrowsableRootExtras):
  /// search button; rows by default (tabs and folders set tiles where art
  /// fills them).
  static const rootExtras = <String, dynamic>{
    'android.media.browse.SEARCH_SUPPORTED': true,
    // Older Android Auto versions only read the style hints with this.
    'android.media.browse.CONTENT_STYLE_SUPPORTED': true,
    browsableHint: 1,
    playableHint: 1,
  };

  /// An app icon the car can load (no network, no token; kept in release
  /// builds by res/raw/keep.xml).
  static Uri iconUri(String name) =>
      Uri.parse('android.resource://app.marquee.marquee/drawable/$name');

  static as_.MediaItem _fromNode(CarNode n, Uri? art) {
    final extras = <String, dynamic>{
      if (n.browsableStyle != null) browsableHint: n.browsableStyle!.value,
      if (n.playableStyle != null) playableHint: n.playableStyle!.value,
      if (n.group != null) groupHint: n.group,
    };
    return as_.MediaItem(
      id: n.id,
      title: n.title,
      // A row whose second line isn't its artist (a genre's songs: the
      // album) shows it as display text; the artist stays the artist.
      artist: n.artist ?? n.subtitle,
      // Android uses the display texts only when a display title is set.
      displayTitle: n.artist == null ? null : n.title,
      displaySubtitle: n.artist == null ? null : n.subtitle,
      artUri: art ?? (n.icon == null ? null : iconUri(n.icon!)),
      playable: n.playable,
      extras: extras.isEmpty ? null : extras,
    );
  }

  Future<List<as_.MediaItem>> _withArt(List<CarNode> nodes) async {
    final fetch = carArt;
    Future<Uri?> artOf(int i) async {
      final remote = nodes[i].art;
      if (fetch == null || remote == null) return null;
      try {
        return await fetch(remote, mode: CarArt.modeFor(i))
            .timeout(artDeadline, onTimeout: () => null);
      } catch (_) {
        return null;
      }
    }

    final art = await Future.wait([for (var i = 0; i < nodes.length; i++) artOf(i)]);
    return [for (var i = 0; i < nodes.length; i++) _fromNode(nodes[i], art[i])];
  }

  @override
  Future<List<as_.MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    final took = Stopwatch()..start();
    var how = 'loaded';
    final list = await _children(parentMediaId, (h) => how = h);
    log?.add('list $parentMediaId: ${list.length} rows ($how) in ${took.elapsedMilliseconds} ms');
    return list;
  }

  Future<List<as_.MediaItem>> _children(
      String parentMediaId, void Function(String how) note) async {
    // Android's media resumption ("recent" root): what's playing / last played.
    if (parentMediaId == as_.AudioService.recentRootId) {
      final now = mediaItem.value;
      note('resume card');
      return now == null ? const [] : [_shareable(now).copyWith(playable: true)];
    }
    final kept = _kept[parentMediaId];
    if (kept != null) {
      note('from memory');
      // Most recently used last (the cap drops the oldest).
      _kept
        ..remove(parentMediaId)
        ..[parentMediaId] = kept;
      final freshFor = _partial.contains(parentMediaId) ? partialFreshFor : keepFreshFor;
      if (DateTime.now().difference(_keptAt[parentMediaId]!) >= freshFor) {
        unawaited(_refresh(parentMediaId));
      }
      return kept;
    }
    // Two car requests for the same new list share one load.
    return _firstLoads[parentMediaId] ??= () async {
      final epoch = _epoch;
      final load = _load(parentMediaId);
      try {
        final (fresh, partial) = await load.timeout(answerWithin);
        _keep(parentMediaId, fresh, epoch, partial: partial);
        return fresh;
      } on TimeoutException {
        note('slow: answered empty, fills in later');
        unawaited(load.then((loaded) async {
          final (fresh, partial) = loaded;
          if (fresh.isEmpty || epoch != _epoch) return;
          _keep(parentMediaId, fresh, epoch, partial: partial);
          await _notify(parentMediaId);
        }, onError: (Object _) {}));
        return const <as_.MediaItem>[];
      } catch (e) {
        note('failed: $e');
        // A failure goes back to the car as "Could not browse selection":
        // an empty list (or the next look) is better.
        return const <as_.MediaItem>[];
      } finally {
        _firstLoads.remove(parentMediaId);
      }
    }();
  }

  /// Without links only this app can open (now playing art is a private
  /// file; Android Auto and the system run elsewhere), and without app icons
  /// (a Shuffle row's): as now-playing art audio_service would try to
  /// download `android.resource://` and log an error each time.
  ///
  /// And as itself, not as a row: a row's display text (a genre song's
  /// album) would show as now playing's artist line.
  static as_.MediaItem _shareable(as_.MediaItem m) {
    final noArt = m.artUri?.scheme == 'file' || m.artUri?.scheme == 'android.resource';
    if (!noArt && m.displayTitle == null && m.displaySubtitle == null) return m;
    return m.copyWith(
        artUri: noArt ? null : m.artUri, displayTitle: null, displaySubtitle: null);
  }

  /// The car asking what an item is (e.g. the one playing).
  @override
  Future<as_.MediaItem?> getMediaItem(String mediaId) async {
    final found = await _item(mediaId);
    log?.add('item? $mediaId → ${found == null ? 'not known' : found.title}');
    return found;
  }

  Future<as_.MediaItem?> _item(String mediaId) async {
    final now = mediaItem.value;
    if (now != null && now.id == mediaId) return _shareable(now);
    for (final list in [..._kept.values, _lastSearch, queue.value]) {
      for (final m in list) {
        if (m.id == mediaId) return _shareable(m);
      }
    }
    return null;
  }

  /// The last search's results, so a tap on one can be shown at once.
  List<as_.MediaItem> _lastSearch = const [];

  @override
  Future<List<as_.MediaItem>> search(String query,
      [Map<String, dynamic>? extras]) async {
    final took = Stopwatch()..start();
    try {
      final hits = _lastSearch = await _withArt(await library.search(query));
      log?.add('search "$query": ${hits.length} in ${took.elapsedMilliseconds} ms');
      return hits;
    } catch (e) {
      log?.add('search "$query" failed: $e');
      return const []; // never an error back to the car
    }
  }

  /// A car that asked for the menu before the app was ready got an empty
  /// one (cold start); this makes it ask again.
  Future<void> refreshRoot() async => _notify('root');

  /// Servers, libraries or the profile changed: every list may differ.
  /// [clear]: what was kept no longer applies (the car's library changed).
  Future<void> refreshAll({bool clear = false}) async {
    // Servers or the profile changed what the lists belong to: start over.
    final key = rememberKey?.call();
    if (key != null && _lastKey != null && key != _lastKey) clear = true;
    _lastKey = key;
    // Lists the car may be showing below the tabs (an A–Z folder, an album).
    final shown = clear ? [..._kept.keys] : const <String>[];
    if (clear) {
      _epoch++;
      _kept.clear();
      _keptAt.clear();
      _partial.clear();
      library.forgetTracks();
      _rememberNow(); // at once: the old lists mustn't come back after a restart
    } else {
      // Servers or the profile changed: everything kept is looked at again
      // when next shown, and the lists on screen are checked now (redrawn
      // only if they changed).
      _keptAt.updateAll((_, _) => DateTime(0));
    }
    for (final id in const [
      'root', 'tab:recent', 'tab:playlists', 'tab:library', 'tab:tracks',
    ]) {
      if (!clear && _kept.containsKey(id)) {
        unawaited(_refresh(id));
      } else {
        await _notify(id);
      }
    }
    for (final id in shown) {
      if (!const ['root', 'tab:recent', 'tab:playlists', 'tab:library', 'tab:tracks']
          .contains(id)) {
        await _notify(id);
      }
    }
  }

  // -- playing -----------------------------------------------------------------

  /// What the car tapped, and the queue it started: the session must report
  /// the playing item under the tapped id, or Android Auto decides the
  /// selection never loaded ("Could not load your selection", while the
  /// phone plays). Later tracks get ids like their rows in that list.
  String? _tappedId;
  int? _tappedIndex;
  String? _tappedList;
  List<MediaItem>? _tappedQueue;

  /// While a tap resolves, the old song's updates mustn't replace the tapped
  /// item (the car would see another id than it tapped).
  bool _holding = false;

  /// A "prepare" waiting for its "play" (prepare never starts music).
  ({String id, Future<(List<MediaItem>, int)?> queue})? _prepared;
  Timer? _preparedExpiry;
  DateTime? _startedAt;

  Future<void> _play((List<MediaItem>, int)? queue, {String? tapped}) async {
    _holding = false;
    if (queue == null) return;
    _startedAt = DateTime.now();
    _tappedQueue = tapped == null ? null : queue.$1;
    _tappedId = tapped;
    _tappedIndex = queue.$2;
    // Only a song's id says which list it's in (`track:<s>:<id>@<list>`); a
    // genre's name may hold '@' too (`shufflegenre:Hip@Hop`).
    final at = tapped != null && tapped.startsWith('track:') ? tapped.indexOf('@') : -1;
    _tappedList = at < 0 ? null : tapped!.substring(at + 1);
    await engine.playQueue(queue.$1, queue.$2);
  }

  /// The id the car knows a queue entry by.
  String _idFor(MusicState s, int i, MediaItem t) {
    if (identical(s.queue, _tappedQueue)) {
      if (i == _tappedIndex) return _tappedId!;
      if (_tappedList != null) return 'track:${t.serverId}:${t.id}@$_tappedList';
    }
    return 'track:${t.serverId}:${t.id}';
  }

  /// Why the last tap couldn't play (shown by the car until something plays).
  String? _tapError;

  /// The car switches to its now-playing screen on a tap and expects the
  /// tapped song, loading, at once: looking its queue up first left the old
  /// state showing for seconds on mobile data.
  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    // The play after a prepare of the same item: start what was prepared.
    if (_prepared?.id == mediaId) {
      log?.add('tap $mediaId (prepared)');
      return _playPrepared();
    }
    // The same tap again right after it started (prepare + play + play…).
    if (mediaId == _tappedId &&
        identical(engine.state.queue, _tappedQueue) &&
        engine.state.index == _tappedIndex && // still the song playing

        _startedAt != null &&
        DateTime.now().difference(_startedAt!) < const Duration(seconds: 10)) {
      log?.add('tap $mediaId (already started)');
      return;
    }
    _tapError = null;
    log?.add('tap $mediaId');
    final took = Stopwatch()..start();
    await _showTapped(mediaId);
    String? why;
    final queue = await library.resolve(mediaId, whyNot: (w) => why = w);
    log?.add(queue == null
        ? 'tap → nothing to play (${took.elapsedMilliseconds} ms): ${why ?? '?'}'
        : 'tap → ${queue.$1.length} tracks from #${queue.$2} (${took.elapsedMilliseconds} ms)');
    if (queue == null) return _cantPlay();
    await _play(queue, tapped: mediaId);
  }

  /// The tapped item, loading, at once (and held until it plays).
  Future<void> _showTapped(String mediaId) async {
    final tapped = await _item(mediaId);
    _holding = true;
    if (tapped != null) mediaItem.add(tapped);
    playbackState.add(playbackState.value.copyWith(
        processingState: as_.AudioProcessingState.loading, errorMessage: null));
    _logState();
  }

  void _cantPlay() {
    _holding = false;
    _tapError = "Couldn't play that. Check the connection to your server.";
    _publish(engine.state);
  }

  Future<void> _playPrepared() async {
    final p = _prepared!;
    _prepared = null;
    _preparedExpiry?.cancel();
    final queue = await p.queue;
    if (queue == null) return _cantPlay();
    await _play(queue, tapped: p.id);
  }

  /// Some Android Auto versions send "prepare" for a tap and "play" after;
  /// preparing the tapped item means starting it (play then just carries on).
  /// "Prepare" (Assistant, some cars and controllers): show the item and
  /// look its queue up, but start nothing until "play" (MediaSession's rule;
  /// a car may prepare on its own). Dropped if no play follows in 30 s.
  @override
  Future<void> prepareFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    log?.add('prepare $mediaId');
    _tapError = null;
    await _showTapped(mediaId);
    final queue = library.resolve(mediaId,
        whyNot: (why) => log?.add('prepare $mediaId → nothing to play: $why'));
    _prepared = (id: mediaId, queue: queue);
    _preparedExpiry?.cancel();
    _preparedExpiry = Timer(const Duration(seconds: 30), () {
      if (_prepared?.id != mediaId) return;
      _prepared = null;
      _holding = false;
      _publish(engine.state);
    });
    final q = await queue;
    if (_prepared?.id != mediaId) return; // played or replaced meanwhile
    if (q == null) {
      _prepared = null;
      return _cantPlay();
    }
    playbackState.add(playbackState.value.copyWith(
        processingState: as_.AudioProcessingState.ready, playing: false));
    _logState();
  }

  @override
  Future<void> prepareFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    log?.add('prepare search "$query"');
    final hit = query.trim().isEmpty
        ? 'shuffle:all'
        : (await library.search(query)).firstOrNull?.id;
    if (hit == null) return;
    await prepareFromMediaId(hit, extras);
  }

  /// On connect, with nothing named: nothing to start (no surprise music).
  @override
  Future<void> prepare() async => log?.add('prepare (nothing named)');

  @override
  Future<void> playFromUri(Uri uri, [Map<String, dynamic>? extras]) async =>
      log?.add('play from a link: not supported');

  @override
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]) async =>
      log?.add('play from a link: not supported');

  /// "Hey Google, play … on Marquee". Nothing named → shuffle everything.
  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    log?.add('voice "$query"');
    if (query.trim().isEmpty) return _play(await library.resolve('shuffle:all'));
    final hits = await library.search(query);
    for (final h in hits) {
      final queue = await library.resolve(h.id);
      if (queue != null) {
        log?.add('voice → ${h.title} (${queue.$1.length} tracks)');
        return _play(queue, tapped: h.id);
      }
    }
    log?.add('voice → nothing found to play (${hits.length} hits)');
  }

  @override
  Future<void> play() async {
    log?.add('control play');
    if (_prepared != null) return _playPrepared();
    engine.play();
  }

  @override
  Future<void> pause() async {
    log?.add('control pause');
    engine.pause();
  }
  @override
  Future<void> stop() async {
    log?.add('control stop');
    await engine.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    log?.add('control next');
    engine.next();
  }

  @override
  Future<void> skipToPrevious() async {
    log?.add('control previous');
    engine.previous();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    log?.add('control queue item #$index');
    engine.jump(index);
  }

  @override
  Future<void> seek(Duration position) async {
    log?.add('control seek ${position.inSeconds} s');
    engine.seek(position);
  }

  // -- what the car and lock screen show --------------------------------------

  static as_.MediaItem _fromTrack(MediaItem t,
          {required String id, Duration? duration, Uri? art}) =>
      as_.MediaItem(
        id: id,
        title: t.title,
        artist: t.grandparentTitle ?? t.parentTitle,
        album: t.parentTitle,
        duration: duration ?? t.duration,
        artUri: art,
      );

  /// The playing song's art per track id, once fetched.
  final _art = <String, Uri>{};
  String? _artFor;

  /// Prefers the car's own `content://` link (Android Auto's now-playing
  /// screen can't open a private `file://` one and showed no art); the lock
  /// screen and notification read either. Falls back to the private file.
  void _fetchArt(MediaItem t) {
    final remote = CarLibrary.artOf(t);
    final car = carArt;
    if (remote == null || (localArt == null && car == null) || _artFor == t.id) return;
    _artFor = t.id;
    final Future<Uri?> link = car != null
        ? car(remote, mode: CarArtMode.wait)
            .then<Uri?>((u) => u)
            .catchError((Object _) => null) // the copy failed: private file
            .then((u) async => u ?? await localArt?.call(remote))
        : localArt!(remote);
    link.then((file) {
      if (file == null) return;
      _art[t.id] = file;
      if (engine.state.current?.id == t.id) _publish(engine.state);
    }, onError: (Object _) {});
  }

  String? _lastSummary;

  void _logState() {
    final p = playbackState.value;
    final summary = 'state ${p.processingState.name} '
        '${p.playing ? 'playing' : 'paused'} item=${mediaItem.value?.id ?? '-'}'
        '${p.errorMessage == null ? '' : ' error="${p.errorMessage}"'}';
    if (summary != _lastSummary) {
      _lastSummary = summary;
      log?.add(summary);
    }
  }

  void _publish(MusicState s) {
    if (_holding) return; // a tap is loading: keep showing it
    if (s.playing) _tapError = null;
    if (!identical(s.queue, _lastQueue)) {
      _lastQueue = s.queue;
      queue.add([
        for (var i = 0; i < s.queue.length; i++)
          _fromTrack(s.queue[i], id: _idFor(s, i, s.queue[i])),
      ]);
    }
    final current = s.current;
    if (current != null) _fetchArt(current);
    final shown = current == null
        ? null
        : _fromTrack(current,
            id: _idFor(s, s.index, current),
            duration: s.duration > Duration.zero ? s.duration : null,
            art: _art[current.id]);
    // audio_service's MediaItem == compares ids only: a later length or art
    // must still reach the car.
    final was = mediaItem.value;
    if (shown?.id != was?.id ||
        shown?.duration != was?.duration ||
        shown?.artUri != was?.artUri) {
      mediaItem.add(shown);
    }
    final next = as_.PlaybackState(
      updateTime: _now(),
      controls: [
        as_.MediaControl.skipToPrevious,
        if (s.playing) as_.MediaControl.pause else as_.MediaControl.play,
        as_.MediaControl.skipToNext,
        // Closes the notification after a drive (it stays while paused).
        as_.MediaControl.stop,
        // The car's lists of songs A–Z can't hold a Shuffle row (Android
        // Auto re-sorts them), so the now-playing screen has a button.
        if (s.queue.length > 1) shuffleControl,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {as_.MediaAction.seek},
      // The car shows a spinner, not a running progress bar, while a track
      // is looked up, opened or buffering.
      processingState: _tapError != null || (s.failed && !s.playing)
          ? as_.AudioProcessingState.error
          : current == null
              ? as_.AudioProcessingState.idle
              : s.loading
                  ? as_.AudioProcessingState.buffering
                  : as_.AudioProcessingState.ready,
      playing: s.playing,
      updatePosition: s.position,
      queueIndex: current == null ? null : s.index,
      // The car shows any error message, even while music plays, so it only
      // gets one when nothing can play; the app says why a track was skipped.
      errorMessage: _tapError ?? (s.failed && !s.playing ? s.error : null),
    );
    if (!_sameState(playbackState.value, next)) playbackState.add(next);
    _logState();
  }

  /// Shuffles what's queued around the playing song (user's pick 2026-11-21);
  /// its icon is kept in release builds by res/raw/keep.xml (`car_*`).
  static final shuffleControl = as_.MediaControl.custom(
      androidIcon: 'drawable/car_action_shuffle', label: 'Shuffle', name: 'shuffle');

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    log?.add('control $name');
    if (name != 'shuffle') return;
    final before = engine.state.queue;
    final tapped = identical(before, _tappedQueue);
    final at = _tappedIndex;
    // The song the car tapped (it may not be the one playing any more).
    final tappedSong = tapped && at != null && at >= 0 && at < before.length ? before[at] : null;
    // Its new queue is set before its first await, and must be marked as
    // the tapped one before the engine's state arrives here: the car keeps
    // knowing the songs by the ids it tapped them under.
    final shuffling = engine.shuffleRest();
    final after = engine.state.queue;
    if (tapped && !identical(after, before)) {
      _tappedQueue = after;
      // Wherever the tapped song went (its id is the tapped one).
      _tappedIndex = tappedSong == null ? -1 : after.indexWhere((t) => identical(t, tappedSong));
    }
    await shuffling;
  }

  /// Whether [next] only says what the system already works out: Android
  /// moves a playing position on from the last state's time by itself, and
  /// Android Auto's queue screen jumps back to the playing song on every new
  /// state (one per position tick made it impossible to scroll, 2026-11-21).
  /// So a state goes out only when something changed, or the position is
  /// more than 2 s from where the last one would have it (a seek).
  static bool _sameState(as_.PlaybackState was, as_.PlaybackState next) {
    if (was.processingState != next.processingState ||
        was.playing != next.playing ||
        was.queueIndex != next.queueIndex ||
        was.errorMessage != next.errorMessage ||
        was.speed != next.speed ||
        !listEquals(was.controls, next.controls)) {
      return false;
    }
    final moving = was.playing && was.processingState == as_.AudioProcessingState.ready;
    final expected = moving
        ? was.updatePosition + next.updateTime.difference(was.updateTime) * was.speed
        : was.updatePosition;
    return (next.updatePosition - expected).abs() < const Duration(seconds: 2);
  }

  Future<void> dispose() async {
    _preparedExpiry?.cancel();
    if (_remembering != null) _rememberNow();
    await _sub.cancel();
  }
}
