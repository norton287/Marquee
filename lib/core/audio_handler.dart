import 'dart:async';

import 'package:audio_service/audio_service.dart' as as_;

import 'car_library.dart';
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

class MarqueeAudioHandler extends as_.BaseAudioHandler {
  MarqueeAudioHandler(this.engine, this.library,
      {this.notifyChanged,
      this.localArt,
      this.carArt,
      this.artDeadline = const Duration(seconds: 2),
      this.keepFreshFor = const Duration(minutes: 1),
      this.answerWithin = const Duration(seconds: 8)}) {
    _sub = engine.states.listen(_publish);
    _publish(engine.state);
  }

  final MusicEngine engine;
  final CarLibrary library;

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

  /// A first load that takes longer answers empty (a car that waits too
  /// long says "Could not browse selection") and fills the list in when it
  /// arrives.
  final Duration answerWithin;

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

  void _keep(String id, List<as_.MediaItem> list, int epoch) {
    if (list.isEmpty || epoch != _epoch) return;
    _kept.remove(id);
    _kept[id] = list;
    _keptAt[id] = DateTime.now();
    while (_kept.length > _keepAtMost) {
      final oldest = _kept.keys.first;
      _kept.remove(oldest);
      _keptAt.remove(oldest);
    }
  }

  static bool _same(List<as_.MediaItem> a, List<as_.MediaItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].title != b[i].title ||
          a[i].artist != b[i].artist ||
          a[i].artUri != b[i].artUri) {
        return false;
      }
    }
    return true;
  }

  Future<List<as_.MediaItem>> _load(String parentId) async =>
      _withArt(await library.children(parentId));

  Future<void> _refresh(String id) => _refreshing[id] ??= () async {
        final epoch = _epoch;
        try {
          final fresh = await _load(id);
          final old = _kept[id];
          if (fresh.isEmpty || epoch != _epoch) return;
          _keep(id, fresh, epoch);
          if (old == null || !_same(old, fresh)) await notifyChanged?.call(id);
        } catch (_) {
          // Keep showing what was there.
        } finally {
          _refreshing.remove(id);
        }
      }();

  late final StreamSubscription<MusicState> _sub;
  List<MediaItem>? _lastQueue;

  // -- browsing --------------------------------------------------------------

  static as_.MediaItem _fromNode(CarNode n, Uri? art) => as_.MediaItem(
        id: n.id,
        title: n.title,
        artist: n.subtitle,
        artUri: art,
        playable: n.playable,
      );

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
    // Android's media resumption ("recent" root): what's playing / last played.
    if (parentMediaId == as_.AudioService.recentRootId) {
      final now = mediaItem.value;
      return now == null ? const [] : [_shareable(now).copyWith(playable: true)];
    }
    final kept = _kept[parentMediaId];
    if (kept != null) {
      // Most recently used last (the cap drops the oldest).
      _kept
        ..remove(parentMediaId)
        ..[parentMediaId] = kept;
      if (DateTime.now().difference(_keptAt[parentMediaId]!) >= keepFreshFor) {
        unawaited(_refresh(parentMediaId));
      }
      return kept;
    }
    // Two car requests for the same new list share one load.
    return _firstLoads[parentMediaId] ??= () async {
      final epoch = _epoch;
      final load = _load(parentMediaId);
      try {
        final fresh = await load.timeout(answerWithin);
        _keep(parentMediaId, fresh, epoch);
        return fresh;
      } on TimeoutException {
        unawaited(load.then((fresh) async {
          if (fresh.isEmpty || epoch != _epoch) return;
          _keep(parentMediaId, fresh, epoch);
          await notifyChanged?.call(parentMediaId);
        }, onError: (Object _) {}));
        return const <as_.MediaItem>[];
      } catch (_) {
        // A failure goes back to the car as "Could not browse selection":
        // an empty list (or the next look) is better.
        return const <as_.MediaItem>[];
      } finally {
        _firstLoads.remove(parentMediaId);
      }
    }();
  }

  /// Without links only this app can open (now playing art is a private
  /// file; Android Auto and the system run elsewhere).
  static as_.MediaItem _shareable(as_.MediaItem m) =>
      m.artUri?.scheme == 'file' ? m.copyWith(artUri: null) : m;

  /// The car asking what an item is (e.g. the one playing).
  @override
  Future<as_.MediaItem?> getMediaItem(String mediaId) async {
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
    try {
      return _lastSearch = await _withArt(await library.search(query));
    } catch (_) {
      return const []; // never an error back to the car
    }
  }

  /// A car that asked for the menu before the app was ready got an empty
  /// one (cold start); this makes it ask again.
  Future<void> refreshRoot() async => notifyChanged?.call('root');

  /// Servers, libraries or the profile changed: every list may differ.
  /// [clear]: what was kept no longer applies (the car's library changed).
  Future<void> refreshAll({bool clear = false}) async {
    // Lists the car may be showing below the tabs (an A–Z folder, an album).
    final shown = clear ? [..._kept.keys] : const <String>[];
    if (clear) {
      _epoch++;
      _kept.clear();
      _keptAt.clear();
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
        await notifyChanged?.call(id);
      }
    }
    for (final id in shown) {
      if (!const ['root', 'tab:recent', 'tab:playlists', 'tab:library', 'tab:tracks']
          .contains(id)) {
        await notifyChanged?.call(id);
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

  Future<void> _play((List<MediaItem>, int)? queue, {String? tapped}) async {
    if (queue == null) return;
    _tappedQueue = tapped == null ? null : queue.$1;
    _tappedId = tapped;
    _tappedIndex = queue.$2;
    final at = tapped?.indexOf('@') ?? -1;
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
    _tapError = null;
    final tapped = await getMediaItem(mediaId);
    if (tapped != null) mediaItem.add(tapped);
    playbackState.add(playbackState.value.copyWith(
        processingState: as_.AudioProcessingState.loading, errorMessage: null));
    final queue = await library.resolve(mediaId);
    if (queue == null) {
      _tapError = "Couldn't play that. Check the connection to your server.";
      _publish(engine.state);
      return;
    }
    await _play(queue, tapped: mediaId);
  }

  /// "Hey Google, play … on Marquee". Nothing named → shuffle everything.
  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    if (query.trim().isEmpty) return _play(await library.resolve('shuffle:all'));
    final hits = await library.search(query);
    for (final h in hits) {
      final queue = await library.resolve(h.id);
      if (queue != null) return _play(queue, tapped: h.id);
    }
  }

  @override
  Future<void> play() async => engine.play();
  @override
  Future<void> pause() async => engine.pause();
  @override
  Future<void> stop() async {
    await engine.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async => engine.next();
  @override
  Future<void> skipToPrevious() async => engine.previous();
  @override
  Future<void> skipToQueueItem(int index) async => engine.jump(index);
  @override
  Future<void> seek(Duration position) async => engine.seek(position);

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

  /// Local art per track id, once fetched.
  final _art = <String, Uri>{};
  String? _artFor;

  void _fetchArt(MediaItem t) {
    final remote = CarLibrary.artOf(t);
    if (remote == null || localArt == null || _artFor == t.id) return;
    _artFor = t.id;
    localArt!(remote).then((file) {
      if (file == null) return;
      _art[t.id] = file;
      if (engine.state.current?.id == t.id) _publish(engine.state);
    }, onError: (Object _) {});
  }

  void _publish(MusicState s) {
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
    playbackState.add(as_.PlaybackState(
      controls: [
        as_.MediaControl.skipToPrevious,
        if (s.playing) as_.MediaControl.pause else as_.MediaControl.play,
        as_.MediaControl.skipToNext,
        // Closes the notification after a drive (it stays while paused).
        as_.MediaControl.stop,
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
    ));
  }

  Future<void> dispose() => _sub.cancel();
}
