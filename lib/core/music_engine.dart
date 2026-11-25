import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'models.dart';

@immutable
class MusicState {
  const MusicState({
    this.queue = const [],
    this.index = 0,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
    this.loading = false,
    this.failed = false,
  });
  final List<MediaItem> queue;
  final int index;
  final bool playing;
  final Duration position;
  final Duration duration;
  final String? error;

  /// A track is being looked up / opened, or its stream is buffering.
  final bool loading;

  /// Nothing could be played (the last track failed): the only state the
  /// car is told about as an error. A skipped track's [error] is for the app.
  final bool failed;

  MediaItem? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
  bool get hasNext => index + 1 < queue.length;

  MusicState copyWith({
    List<MediaItem>? queue,
    int? index,
    bool? playing,
    Duration? position,
    Duration? duration,
    String? error,
    bool? loading,
    bool? failed,
  }) =>
      MusicState(
        queue: queue ?? this.queue,
        index: index ?? this.index,
        playing: playing ?? this.playing,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        error: error,
        loading: loading ?? this.loading,
        failed: failed ?? this.failed,
      );
}

/// Plays one stream at a time. Implemented over media_kit in the app and by
/// a fake in tests.
abstract class TrackPlayer {
  Future<void> open(String url, Map<String, String> headers);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration to);
  Stream<bool> get playing;
  Stream<bool> get buffering;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<void> get completed;
  Stream<String> get error;
  Future<void> dispose();
}

/// The music queue, independent of any screen, the car or the lock screen.
///
/// - One track at a time: a track's stream is resolved when it starts and
///   the next one's once it plays, so a long album or "Shuffle all" starts at
///   once (resolving every track first took seconds).
/// - Plays are reported to the server: started, playing every [reportEvery],
///   paused, stopped (on track change, end or stop).
/// - A connection failure reconnects once (the phone may have left home
///   Wi-Fi) and retries the track; a second failure skips it.
class MusicEngine {
  MusicEngine({
    required this.player,
    required this.backendFor,
    this.reconnect,
    this.reportEvery = const Duration(seconds: 10),
    this.describeError = _describe,
    this.beforePlay,
  }) {
    _subs.addAll([
      player.playing.listen(_onPlaying),
      // A stream stalling mid-track shows as loading too.
      player.buffering.listen((b) {
        // "Stopped buffering" always counts, so a spinner never sticks.
        if ((_current != null || !b) && b != _state.loading) {
          _emit(_state.copyWith(loading: b, error: _state.error));
        }
      }),
      player.position.listen(_onPosition),
      player.duration.listen((d) => _emit(_state.copyWith(duration: d))),
      player.completed.listen((_) => _onCompleted()),
      player.error.listen((e) => _failed(e)),
    ]);
  }

  final TrackPlayer player;
  final MediaBackend? Function(String serverId) backendFor;
  final Future<void> Function(String serverId)? reconnect;
  final Duration reportEvery;
  final String Function(Object error) describeError;

  /// Asked before anything starts playing (audio focus in the app); false
  /// leaves the music paused.
  final Future<bool> Function()? beforePlay;

  /// While a video plays, nothing (a headset button, the car, a track that
  /// was still loading) may start the music under it.
  bool _held = false;

  /// Whether a video holds music (see [holdForVideo]).
  bool get held => _held;
  void holdForVideo(bool hold) {
    _held = hold;
    if (hold) pause();
  }

  Future<bool> _mayPlay() async {
    if (_held) return false;
    return await beforePlay?.call() ?? true;
  }

  static String _describe(Object e) => '$e';

  final _states = StreamController<MusicState>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];
  MusicState _state = const MusicState();

  /// Bumped whenever another track starts, so a slow answer for an older
  /// one is ignored.
  int _generation = 0;

  /// The track that's open and its source (null while resolving).
  (MediaItem, PlaybackSource)? _current;
  (int, Future<PlaybackSource?>)? _prefetch;
  bool _retried = false;

  /// The generation whose failure is being handled: libmpv reports one dead
  /// stream twice ("tcp: …", then "Failed to open …").
  int? _failedGeneration;

  /// Where a retried track picks up (a stream that dropped mid-track).
  Duration _resumeAt = Duration.zero;
  bool _reportedPause = false;
  Duration _position = Duration.zero;
  Timer? _reportTimer;

  MusicState get state => _state;
  Stream<MusicState> get states => _states.stream;

  void _emit(MusicState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  // -- reporting -------------------------------------------------------------

  void _report(PlayState s) {
    final cur = _current;
    if (cur == null) return;
    final backend = backendFor(cur.$1.serverId);
    if (backend == null) return;
    // A report that fails must never interrupt the music.
    unawaited(backend
        .reportProgress(cur.$1, cur.$2, _position, s)
        .catchError((Object _) {}));
  }

  /// Ends the open track's session on the server.
  void _endCurrent() {
    _reportTimer?.cancel();
    _report(PlayState.stopped);
    _current = null;
  }

  // -- starting tracks ---------------------------------------------------------

  Future<PlaybackSource> _resolve(MediaItem track) async {
    final backend = backendFor(track.serverId);
    if (backend == null) throw StateError('That server is no longer signed in.');
    return backend.playback(track, const PlaybackRequest());
  }

  Future<void> _start(int index, {bool retry = false}) async {
    if (index < 0 || index >= _state.queue.length) return;
    _endCurrent();
    final gen = ++_generation;
    if (!retry) {
      _retried = false;
      _resumeAt = Duration.zero;
    }
    _reportedPause = false;
    _position = Duration.zero;
    final track = _state.queue[index];
    _emit(_state.copyWith(
        index: index,
        playing: true,
        loading: true,
        failed: false,
        position: Duration.zero,
        duration: track.duration ?? Duration.zero));
    try {
      final pre = _prefetch;
      _prefetch = null;
      final source = (!retry && pre != null && pre.$1 == index
              ? await pre.$2
              : null) ??
          await _resolve(track);
      if (gen != _generation) return;
      await player.open(source.url, source.headers);
      if (gen != _generation) return;
      _current = (track, source);
      if (retry && _resumeAt > Duration.zero) {
        await player.seek(_resumeAt);
        _position = _resumeAt;
      }
      final play = await _mayPlay();
      if (gen != _generation) return;
      if (play) await player.play();
      if (gen != _generation) return;
      _report(PlayState.started);
      _emit(_state.copyWith(loading: false, playing: play));
      if (!play) {
        _reportedPause = true;
        _report(PlayState.paused);
      }
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(reportEvery, (_) {
        if (_state.playing) _report(PlayState.playing);
      });
      // The track's place now (a Shuffle while it loaded moved it to 0).
      _prefetchAfter(_state.index);
    } catch (e) {
      if (gen == _generation) await _failed(e);
    }
  }

  void _prefetchAfter(int index) {
    final next = index + 1;
    if (next >= _state.queue.length) return;
    _prefetch = (
      next,
      _resolve(_state.queue[next]).then<PlaybackSource?>((s) => s,
          onError: (Object _) => null),
    );
  }

  /// Player errors come as libmpv text; most are a stream that couldn't be
  /// reached.
  static bool _isConnection(Object e) => e is String || isConnectionError(e);

  /// The current track couldn't be opened or stopped playing with an error.
  Future<void> _failed(Object e) async {
    final track = _state.current;
    if (track == null) return;
    final gen = _generation;
    if (_failedGeneration == gen) return;
    _failedGeneration = gen;
    if (!_retried && _isConnection(e)) {
      _retried = true;
      _prefetch = null;
      _resumeAt = _position;
      try {
        await reconnect?.call(track.serverId);
      } catch (_) {}
      if (gen != _generation) return;
      return _start(_state.index, retry: true);
    }
    _endCurrent();
    _emit(_state.copyWith(error: describeError(e), loading: false));
    if (_state.hasNext) {
      final message = _state.error;
      await _start(_state.index + 1);
      // Keep saying why the last one was skipped.
      if (_state.error == null && message != null) {
        _emit(_state.copyWith(error: message));
      }
    } else {
      _emit(_state.copyWith(playing: false, error: _state.error, failed: true));
    }
  }

  // -- player events -----------------------------------------------------------

  void _onPlaying(bool playing) {
    if (_current == null) return;
    if (playing == _state.playing && !(playing && _reportedPause)) return;
    _emit(_state.copyWith(playing: playing, error: _state.error));
    if (!playing && !_reportedPause) {
      _reportedPause = true;
      _report(PlayState.paused);
    } else if (playing && _reportedPause) {
      _reportedPause = false;
      _report(PlayState.playing);
    }
  }

  void _onPosition(Duration p) {
    _position = p;
    // Once a second is plenty for a progress bar.
    if ((p - _state.position).inMilliseconds.abs() >= 900) {
      _emit(_state.copyWith(position: p, error: _state.error));
    }
  }

  void _onCompleted() {
    if (_current == null) return;
    _position = _state.duration;
    if (_state.hasNext) {
      unawaited(_start(_state.index + 1));
    } else {
      _endCurrent();
      _emit(_state.copyWith(playing: false, loading: false));
    }
  }

  // -- controls ----------------------------------------------------------------

  Future<void> playQueue(List<MediaItem> tracks, int startIndex) async {
    if (tracks.isEmpty) return;
    _endCurrent();
    _prefetch = null;
    _emit(MusicState(
        queue: tracks, index: startIndex, playing: true, loading: true));
    await _start(startIndex.clamp(0, tracks.length - 1));
  }

  void toggle() => _state.playing ? pause() : play();
  void pause() => unawaited(player.pause());
  void play() => unawaited(() async {
        if (await _mayPlay()) await player.play();
      }());
  void next() {
    if (_state.hasNext) unawaited(_start(_state.index + 1));
  }

  void previous() {
    if (_position > const Duration(seconds: 4) || _state.index == 0) {
      seek(Duration.zero);
    } else {
      unawaited(_start(_state.index - 1));
    }
  }

  void jump(int index) => unawaited(_start(index));

  void seek(Duration to) {
    _position = to;
    _emit(_state.copyWith(position: to, error: _state.error));
    unawaited(player.seek(to));
  }

  Future<void> shuffleQueue() async {
    if (_state.queue.length < 2) return;
    final shuffled = [..._state.queue]..shuffle();
    await playQueue(shuffled, 0);
  }

  /// Shuffles the queue around the playing track: it moves to the front and
  /// plays on, the rest follow in random order (the car's Shuffle button).
  /// Nothing playing: like [shuffleQueue].
  Future<void> shuffleRest() async {
    final q = _state.queue;
    final at = _state.index;
    if (q.length < 2) return;
    if (at < 0 || at >= q.length) return shuffleQueue();
    final rest = [...q]..removeAt(at);
    rest.shuffle();
    _prefetch = null; // the next one changed
    _emit(_state.copyWith(queue: [q[at], ...rest], index: 0, error: _state.error));
    if (!_state.loading) _prefetchAfter(0);
  }

  Future<void> stop() async {
    _generation++;
    _endCurrent();
    _prefetch = null;
    await player.stop();
    _emit(const MusicState());
  }

  Future<void> dispose() async {
    _generation++;
    _reportTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _states.close();
    await player.dispose();
  }
}
