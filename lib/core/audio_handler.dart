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
      this.artDeadline = const Duration(seconds: 2)}) {
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
          [Map<String, dynamic>? options]) async =>
      _withArt(await library.children(parentMediaId));

  @override
  Future<List<as_.MediaItem>> search(String query,
          [Map<String, dynamic>? extras]) async =>
      _withArt(await library.search(query));

  /// A car that asked for the menu before the app was ready got an empty
  /// one (cold start); this makes it ask again.
  Future<void> refreshRoot() async => notifyChanged?.call('root');

  /// Servers, libraries or the profile changed: every list may differ.
  Future<void> refreshAll() async {
    for (final id in const [
      'root', 'tab:recent', 'tab:playlists', 'tab:artists', 'tab:albums',
    ]) {
      await notifyChanged?.call(id);
    }
  }

  // -- playing -----------------------------------------------------------------

  Future<void> _play((List<MediaItem>, int)? queue) async {
    if (queue == null) return;
    await engine.playQueue(queue.$1, queue.$2);
  }

  @override
  Future<void> playFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) async =>
      _play(await library.resolve(mediaId));

  /// "Hey Google, play … on Marquee". Nothing named → shuffle everything.
  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    if (query.trim().isEmpty) return _play(await library.resolve('shuffle:all'));
    final hits = await library.search(query);
    for (final h in hits) {
      final queue = await library.resolve(h.id);
      if (queue != null) return _play(queue);
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

  static as_.MediaItem _fromTrack(MediaItem t, {Duration? duration, Uri? art}) =>
      as_.MediaItem(
        id: 'track:${t.serverId}:${t.id}',
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
    if (!identical(s.queue, _lastQueue)) {
      _lastQueue = s.queue;
      queue.add([for (final t in s.queue) _fromTrack(t)]);
    }
    final current = s.current;
    if (current != null) _fetchArt(current);
    final shown = current == null
        ? null
        : _fromTrack(current,
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
      processingState: current == null
          ? as_.AudioProcessingState.idle
          : as_.AudioProcessingState.ready,
      playing: s.playing,
      updatePosition: s.position,
      queueIndex: current == null ? null : s.index,
      // The app says why a track was skipped; a car may show an error as an
      // error screen, so only while nothing plays.
      errorMessage: s.playing ? null : s.error,
    ));
  }

  Future<void> dispose() => _sub.cancel();
}
