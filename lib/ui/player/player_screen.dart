import 'dart:async';

import 'package:floating/floating.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/backend.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../music.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';
import 'player_widgets.dart';

bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get _isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

bool _real(String id) => id != 'auto' && id != 'no';

/// Full-screen video playback: direct play first, transcode on request or as
/// a fallback, with resume, tracks, chapters, intro skipping, up-next and
/// picture in picture.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.args});
  final PlayerArgs args;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final Player _player;
  late final VideoController _video;
  late final ProviderContainer _container;
  late final bool _tv;
  final Floating? _floating = _isAndroid ? Floating() : null;

  final _subs = <StreamSubscription<dynamic>>[];
  final _rootFocus = FocusNode(debugLabel: 'player');
  final _playFocus = FocusNode(debugLabel: 'play-pause');
  final _position = ValueNotifier(Duration.zero);
  final _buffer = ValueNotifier(Duration.zero);

  // What is playing.
  late MediaItem _item;
  late List<MediaItem> _queue;
  int _queueIndex = -1;
  PlaybackSource? _source;
  Object? _error;
  bool _loading = true;
  bool _detailLoaded = false;
  bool _firstLoad = true;
  bool _fallbackTried = false;

  /// Transcode even if the file fits under [_maxBitrate]: direct play
  /// failed, or the user pressed "Try transcoding".
  bool _forceTranscode = false;

  /// An audio/subtitle, quality or chapter panel is up. The controls stay put
  /// meanwhile: hiding them pulls focus back to the player, which would take
  /// it out of the panel and leave the remote seeking the video instead.
  bool _panelOpen = false;
  bool _defaultsApplied = false;
  int _generation = 0;

  // Player state.
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  Tracks _tracks = const Tracks();
  Track _track = const Track();
  double _volume = 100;

  // User choices for this session.
  int? _maxBitrate;
  String? _versionId;
  String? _audioId;
  String? _subtitleId;
  double _rate = 1;
  BoxFit _fit = BoxFit.contain;

  // Overlays.
  bool _controls = true;
  bool _peek = false;
  Timer? _hideTimer;
  Timer? _peekTimer;
  Timer? _reportTimer;
  Timer? _countdownTimer;
  Timer? _flashTimer;
  Timer? _failTimer;
  String? _flash;
  MediaItem? _next;
  List<Marker> _markers = const [];
  Marker? _intro;
  final _skippedIntros = <Marker>{};
  bool _upNext = false;
  bool _upNextDismissed = false;
  int _countdown = 0;

  // Window modes.
  bool _pipAvailable = false;
  bool _fullscreen = false;
  bool _mini = false;
  Rect? _restoreBounds;

  MediaBackend? get _backend =>
      _container.read(backendsProvider)[_item.serverId];

  @override
  void initState() {
    super.initState();
    _item = widget.args.item;
    _queue = widget.args.queue;
    _queueIndex = _queue.indexWhere(
        (i) => i.id == _item.id && i.serverId == _item.serverId);
    _versionId = widget.args.versionId;
    _container = ProviderScope.containerOf(context, listen: false);
    // Home or away maximum, by how this server is reached.
    _maxBitrate = ref
        .read(settingsProvider)
        .maxBitrateFor(local: _backend?.isLocal ?? true);
    _tv = ref.read(tvProvider);
    _player = Player(
      configuration: const PlayerConfiguration(
        title: ClientInfo.product,
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _video = VideoController(_player);
    _listen();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    ref.read(musicProvider.notifier).pause();
    if (_isMobile) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
      if (!_tv && MediaQuery.sizeOf(context).shortestSide < 600) {
        unawaited(SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]));
      }
    }
    if (_floating != null && !_tv) {
      try {
        final ok = await _floating.isPipAvailable;
        if (mounted) setState(() => _pipAvailable = ok);
      } catch (_) {}
    }
    await _load();
  }

  void _listen() {
    final s = _player.stream;
    _subs.addAll([
      s.position.listen((p) {
        // While (re)opening, mpv reports zero; keep showing the resume point.
        if (_loading && p == Duration.zero) return;
        _position.value = p;
        _tick(p);
      }),
      s.buffer.listen((b) => _buffer.value = b),
      s.duration.listen((d) {
        if (mounted && d > Duration.zero) setState(() => _duration = d);
      }),
      s.playing.listen((v) {
        if (!mounted || v == _playing) return;
        setState(() => _playing = v);
        if (_source != null && !_loading) {
          _report(v ? PlayState.playing : PlayState.paused);
        }
        _armPip();
        v ? _armHide() : _hideTimer?.cancel();
      }),
      s.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }),
      s.volume.listen((v) => _volume = v),
      s.tracks.listen((t) {
        if (!mounted) return;
        setState(() => _tracks = t);
        _applyDefaults();
      }),
      s.track.listen((t) {
        if (mounted) setState(() => _track = t);
      }),
      s.completed.listen((done) {
        if (done) _onCompleted();
      }),
      s.error.listen(_onPlayerError),
    ]);
  }

  // -- loading --------------------------------------------------------------

  MediaVersion? get _version =>
      _item.versions.where((v) => v.id == _versionId).firstOrNull ??
      _item.versions.firstOrNull;

  Future<void> _load({Duration? at}) async {
    final gen = ++_generation;
    final backend = _backend;
    _reportTimer?.cancel();
    _failTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _defaultsApplied = false;
      _duration = Duration.zero;
    });
    try {
      if (backend == null) throw StateError('That server was removed');
      if (!_detailLoaded) {
        try {
          // Fresh copy: current resume point, every stream and chapter.
          _item = await backend.item(_item.id, kind: _item.kind);
        } catch (_) {}
        _detailLoaded = true;
        unawaited(_loadExtras(backend, _item));
      }
      final settings = ref.read(settingsProvider);
      // A limit or a forced transcode means the server may pick the tracks;
      // apply the language preferences up front so nothing unwanted gets
      // burned in. (A file that fits still direct plays; then the player
      // applies them instead.)
      final transcoding = _maxBitrate != null || _forceTranscode;
      final v = _version;
      final audioId = _audioId ??
          (transcoding && settings.audioLanguage != null
              ? v?.audio
                  .where((s) =>
                      languageMatches(settings.audioLanguage!, s.language))
                  .map((s) => s.id)
                  .firstOrNull
              : null);
      final subtitleId = _subtitleId ??
          (transcoding
              ? (settings.subtitleLanguage == null
                  ? ''
                  : (v?.subtitles
                          .where((s) => languageMatches(
                              settings.subtitleLanguage!, s.language))
                          .map((s) => s.id)
                          .firstOrNull ??
                      ''))
              : null);
      final source = await backend.playback(
        _item,
        PlaybackRequest(
          versionId: _versionId,
          maxBitrateKbps: _maxBitrate,
          audioStreamId: audioId,
          subtitleStreamId: subtitleId,
          forceTranscode: _forceTranscode,
          sdrOnly: !settings.allowHdr,
        ),
      );
      if (!mounted || gen != _generation) return;

      var start = at;
      if (start == null) {
        start = _firstLoad && widget.args.startOver
            ? Duration.zero
            : _item.viewOffset;
        final total = _item.duration ?? Duration.zero;
        final nearEnd = total > Duration.zero &&
            start.inSeconds > total.inSeconds * 0.97;
        if (nearEnd || start < const Duration(seconds: 5)) {
          start = Duration.zero;
        }
      }
      _firstLoad = false;
      _source = source;
      _audioId = audioId;
      _subtitleId = subtitleId;
      _position.value = start;
      await _player.open(Media(
        source.url,
        httpHeaders: source.headers.isEmpty ? null : source.headers,
        start: start > Duration.zero ? start : null,
      ));
      await _player.setRate(_rate);
      if (!mounted || gen != _generation) return;
      setState(() => _loading = false);
      _report(PlayState.started);
      _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (_playing) _report(PlayState.playing);
      });
      _armHide();
    } catch (e) {
      if (mounted && gen == _generation) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadExtras(MediaBackend backend, MediaItem item) async {
    MediaItem? next;
    if (_queueIndex >= 0 && _queueIndex + 1 < _queue.length) {
      next = _queue[_queueIndex + 1];
    } else if (_queue.isEmpty) {
      try {
        next = await backend.nextEpisode(item);
      } catch (_) {}
    }
    var markers = item.markers;
    try {
      if (markers.isEmpty) markers = await backend.markers(item);
    } catch (_) {}
    if (!mounted || _item.id != item.id) return;
    setState(() {
      _next = next;
      _markers = markers;
    });
  }

  void _onPlayerError(String message) {
    if (!mounted) return;
    debugPrint('player: $message');
    // mpv reports recoverable hiccups here too (a missing audio device, one
    // undecodable track). Give the file a few seconds to start before
    // deciding it really failed.
    if (_duration > Duration.zero) return;
    final gen = _generation;
    _failTimer?.cancel();
    _failTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && gen == _generation && _duration == Duration.zero) {
        _onPlaybackFailed(message);
      }
    });
  }

  void _onPlaybackFailed(String message) {
    final source = _source;
    if (source != null &&
        source.method == PlayMethod.directPlay &&
        !_forceTranscode &&
        !_fallbackTried) {
      _fallbackTried = true;
      // Keep the quality limit; a file under it would just direct play
      // (and fail) again, so the transcode has to be forced.
      _forceTranscode = true;
      _showFlash('Direct play failed — transcoding instead');
      _load(at: _position.value);
    } else {
      setState(() => _error = StateError(message));
    }
  }

  /// Without transcoding, the player chooses tracks; apply the saved
  /// language preferences once the file's tracks are known.
  void _applyDefaults() {
    final source = _source;
    if (_defaultsApplied || source == null) return;
    final audio = _tracks.audio.where((t) => _real(t.id)).toList();
    final subs = _tracks.subtitle.where((t) => _real(t.id)).toList();
    if (audio.isEmpty && subs.isEmpty) return;
    _defaultsApplied = true;
    final settings = ref.read(settingsProvider);

    if (source.method == PlayMethod.transcode) {
      // A text subtitle the server delivers next to the transcoded video.
      final chosen = source.subtitleStreams
          .where((s) => s.id == _subtitleId && s.url != null)
          .firstOrNull;
      if (chosen != null) {
        _player.setSubtitleTrack(SubtitleTrack.uri(chosen.url!,
            title: chosen.title, language: chosen.language));
      }
      return;
    }
    final audioLang = settings.audioLanguage;
    if (audioLang != null) {
      final match =
          audio.where((t) => languageMatches(audioLang, t.language)).firstOrNull;
      if (match != null) _player.setAudioTrack(match);
    }
    final subLang = settings.subtitleLanguage;
    if (subLang == null) {
      // "Off" still honours forced tracks (signs, foreign dialogue).
      final forced = subs
          .where((t) => (t.title ?? '').toLowerCase().contains('forced'))
          .firstOrNull;
      _player.setSubtitleTrack(forced ?? SubtitleTrack.no());
    } else {
      final match =
          subs.where((t) => languageMatches(subLang, t.language)).firstOrNull;
      if (match != null) {
        _player.setSubtitleTrack(match);
      } else {
        final sidecar = source.subtitleStreams
            .where((s) =>
                s.isExternal &&
                s.url != null &&
                languageMatches(subLang, s.language))
            .firstOrNull;
        _player.setSubtitleTrack(sidecar == null
            ? SubtitleTrack.no()
            : SubtitleTrack.uri(sidecar.url!,
                title: sidecar.title, language: sidecar.language));
      }
    }
  }

  // -- progress, markers, up next -------------------------------------------

  void _report(PlayState state) {
    final source = _source;
    final backend = _backend;
    if (source == null || backend == null) return;
    backend
        .reportProgress(_item, source, _position.value, state)
        .then<void>((_) {}, onError: (Object _) {});
  }

  void _tick(Duration p) {
    if (!mounted || _loading) return;
    Marker? intro;
    Marker? credits;
    for (final m in _markers) {
      if (m.type == MarkerType.intro &&
          p >= m.start &&
          p < m.end - const Duration(seconds: 1)) {
        intro = m;
      }
      if (m.type == MarkerType.credits) credits = m;
    }
    if (intro != null &&
        ref.read(settingsProvider).autoSkipIntro &&
        _skippedIntros.add(intro)) {
      _player.seek(intro.end);
      _showFlash('Skipped intro');
      intro = null;
    }
    if (intro != _intro) setState(() => _intro = intro);

    final total = _duration;
    if (_next == null || total == Duration.zero) return;
    final trigger = credits != null && credits.start > total * 0.5
        ? credits.start
        : total - const Duration(seconds: 25);
    if (_upNext) {
      // Seeking back out of the ending withdraws the offer and its countdown.
      if (p < trigger - const Duration(seconds: 1)) {
        _countdownTimer?.cancel();
        setState(() => _upNext = false);
      }
    } else if (!_upNextDismissed &&
        p >= trigger &&
        total - p > const Duration(seconds: 2)) {
      _startUpNext();
    }
  }

  void _startUpNext() {
    final auto = ref.read(settingsProvider).autoPlayNext;
    setState(() {
      _upNext = true;
      _countdown = auto ? 12 : 0;
    });
    _countdownTimer?.cancel();
    if (!auto) return;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_upNext) return t.cancel();
      if (!_playing) return; // Paused: hold the countdown.
      if (_countdown <= 1) {
        t.cancel();
        _playNext();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  void _dismissUpNext() {
    _countdownTimer?.cancel();
    setState(() {
      _upNext = false;
      _upNextDismissed = true;
    });
  }

  void _onCompleted() {
    if (!mounted || _loading) return;
    // Reopening a stream (quality or track change) ends the old one, which
    // also reports "completed". Only the real end of the file counts.
    final remaining = _duration - _position.value;
    if (_duration == Duration.zero || remaining > const Duration(seconds: 5)) {
      return;
    }
    if (_next != null && ref.read(settingsProvider).autoPlayNext) {
      _playNext();
    } else {
      _close();
    }
  }

  void _playNext() {
    final next = _next;
    if (next == null) return;
    _countdownTimer?.cancel();
    // Close out the episode that just ended so it is marked watched.
    final source = _source;
    final finished = _item;
    final backend = _backend;
    final end = _duration > Duration.zero ? _duration : _position.value;
    if (source != null && backend != null) {
      backend
          .reportProgress(finished, source, end, PlayState.stopped)
          .then<void>((_) {}, onError: (Object _) {});
    }
    setState(() {
      if (_queueIndex >= 0 && _queueIndex + 1 < _queue.length) {
        _queueIndex++;
      }
      _item = next;
      _source = null;
      _detailLoaded = false;
      _next = null;
      _markers = const [];
      _intro = null;
      _skippedIntros.clear();
      _upNext = false;
      _upNextDismissed = false;
      _versionId = null;
      _audioId = null;
      _subtitleId = null;
      _fallbackTried = false;
    });
    _position.value = Duration.zero;
    _load(at: Duration.zero);
  }

  // -- transport ------------------------------------------------------------

  void _togglePlay() => _player.playOrPause();

  void _seekTo(Duration to) {
    final max = _duration > Duration.zero ? _duration : to;
    final clamped =
        to < Duration.zero ? Duration.zero : (to > max ? max : to);
    _position.value = clamped;
    _player.seek(clamped);
  }

  void _seekBy(Duration delta) => _seekTo(_position.value + delta);

  /// Skip lengths from Settings, read at the moment of the skip.
  int get _backSeconds => ref.read(settingsProvider).skipBackSeconds;
  int get _forwardSeconds => ref.read(settingsProvider).skipForwardSeconds;
  void _skipBack() => _seekBy(Duration(seconds: -_backSeconds));
  void _skipForward() => _seekBy(Duration(seconds: _forwardSeconds));

  int get _chapterIndex {
    var index = -1;
    for (var i = 0; i < _item.chapters.length; i++) {
      if (_position.value >= _item.chapters[i].start) index = i;
    }
    return index;
  }

  void _chapter(int delta) {
    final chapters = _item.chapters;
    if (chapters.isEmpty) return;
    var target = _chapterIndex + delta;
    // "Previous" first returns to the start of the current chapter.
    if (delta < 0 &&
        _chapterIndex >= 0 &&
        _position.value - chapters[_chapterIndex].start >
            const Duration(seconds: 3)) {
      target = _chapterIndex;
    }
    target = target.clamp(0, chapters.length - 1);
    _seekTo(chapters[target].start);
    _showFlash(chapters[target].title);
  }

  void _setVolume(double v) {
    final next = v.clamp(0.0, 100.0);
    _player.setVolume(next);
    _showFlash('Volume ${next.round()}%');
  }

  // -- overlays -------------------------------------------------------------

  void _armHide() {
    _hideTimer?.cancel();
    if (!_playing || _panelOpen) return;
    _hideTimer = Timer(const Duration(seconds: 4), _hideControls);
  }

  void _showControls({bool focusPlay = false}) {
    if (!mounted) return;
    if (!_controls) setState(() => _controls = true);
    if (focusPlay) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _playFocus.requestFocus());
    }
    _armHide();
  }

  void _hideControls() {
    if (!mounted || !_controls || _panelOpen) return;
    setState(() => _controls = false);
    _rootFocus.requestFocus();
  }

  /// Shows just the scrubber for a moment (seeking with the controls hidden).
  void _peekBar() {
    _peekTimer?.cancel();
    if (!_peek) setState(() => _peek = true);
    _peekTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _peek = false);
    });
  }

  void _showFlash(String text) {
    _flashTimer?.cancel();
    setState(() => _flash = text);
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;

    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (!repeat) _togglePlay();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      _player.play();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      _player.pause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaStop) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _skipForward();
      _peekBar();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _skipBack();
      _peekBar();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext && _next != null) {
      if (!repeat) _playNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _toggleFullscreen();
      } else {
        _close();
      }
      return KeyEventResult.handled;
    }
    if (_isDesktop && !repeat) {
      if (key == LogicalKeyboardKey.keyF) {
        _toggleFullscreen();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyM) {
        _setVolume(_volume > 0 ? 0 : 100);
        return KeyEventResult.handled;
      }
    }

    if (_controls) {
      // Let focus traversal and the focused button have the key.
      _armHide();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _skipBack();
      _peekBar();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _skipForward();
      _peekBar();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (_isDesktop) {
        _setVolume(_volume + (key == LogicalKeyboardKey.arrowUp ? 5 : -5));
      } else {
        _showControls(focusPlay: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (repeat) return KeyEventResult.handled;
      // One press does the obvious thing for what is on screen.
      if (_intro != null) {
        _seekTo(_intro!.end);
      } else if (_upNext) {
        _playNext();
      } else {
        _togglePlay();
        _showControls(focusPlay: true);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -- window modes ---------------------------------------------------------

  void _armPip() {
    final f = _floating;
    if (f == null || !_pipAvailable) return;
    // Leaving the app while playing drops into picture in picture.
    (_playing ? f.enable(const OnLeavePiP()) : f.cancelOnLeavePiP())
        .then<void>((_) {}, onError: (Object _) {});
  }

  Future<void> _enterPip() async {
    try {
      await _floating?.enable(const ImmediatePiP());
    } catch (e) {
      _showFlash('Picture in picture isn\'t available');
    }
  }

  Future<void> _toggleFullscreen() async {
    if (!_isDesktop || _mini) return;
    final next = !_fullscreen;
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _fullscreen = next);
  }

  /// Desktop stand-in for picture in picture: a small always-on-top window.
  Future<void> _toggleMini() async {
    if (!_isDesktop) return;
    if (!_mini) {
      if (_fullscreen) {
        await windowManager.setFullScreen(false);
        _fullscreen = false;
      }
      _restoreBounds = await windowManager.getBounds();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(480, 270));
      await windowManager.setAlignment(Alignment.bottomRight);
    } else {
      await windowManager.setAlwaysOnTop(false);
      final bounds = _restoreBounds;
      if (bounds != null) await windowManager.setBounds(bounds);
    }
    if (mounted) setState(() => _mini = !_mini);
  }

  void _close() {
    if (!mounted) return;
    context.canPop() ? context.pop() : context.go('/home');
  }

  @override
  void dispose() {
    _generation++;
    for (final t in [
      _hideTimer, _peekTimer, _reportTimer, _countdownTimer, _flashTimer,
      _failTimer,
    ]) {
      t?.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    // Final position, then refresh everything that shows watch state.
    final source = _source;
    final item = _item;
    final position = _position.value;
    final backend = _backend;
    final container = _container;
    () async {
      try {
        if (source != null && backend != null) {
          await backend.reportProgress(
              item, source, position, PlayState.stopped);
        }
      } catch (_) {}
      try {
        container.invalidate(continueWatchingProvider);
        container.invalidate(nextUpProvider);
        container.invalidate(itemProvider(item.ref));
        container.invalidate(childrenProvider);
      } catch (_) {}
    }();
    if (_isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const []);
    }
    _floating?.cancelOnLeavePiP().then<void>((_) {}, onError: (Object _) {});
    if (_isDesktop) {
      if (_mini) {
        windowManager.setAlwaysOnTop(false);
        final bounds = _restoreBounds;
        if (bounds != null) windowManager.setBounds(bounds);
      }
      if (_fullscreen) windowManager.setFullScreen(false);
    }
    _player.dispose();
    _position.dispose();
    _buffer.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  // -- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final video = Video(
      controller: _video,
      controls: NoVideoControls,
      fit: _fit,
      fill: Colors.black,
    );
    final full = PopScope(
      // On a TV, Back first puts the controls away.
      canPop: !(_tv && _controls && _playing),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hideControls();
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: _controls || !_playing
              ? SystemMouseCursors.basic
              : SystemMouseCursors.none,
          onHover: (_) => _showControls(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              video,
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _controls ? _hideControls() : _showControls(),
                onDoubleTapDown: _isMobile
                    ? (d) {
                        final left = d.localPosition.dx <
                            MediaQuery.sizeOf(context).width / 2;
                        left ? _skipBack() : _skipForward();
                        _showFlash(left
                            ? '−$_backSeconds s'
                            : '+$_forwardSeconds s');
                      }
                    : null,
                onDoubleTap: _isMobile
                    ? () {}
                    : (_isDesktop ? _toggleFullscreen : null),
              ),
              if ((_loading || _buffering) && _error == null)
                const IgnorePointer(child: Loading()),
              if (_flash != null)
                Align(
                  alignment: const Alignment(0, -0.62),
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(_flash!,
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              if (_error != null)
                _errorView()
              else if (_mini)
                _miniOverlay()
              else ...[
                _overlay(),
                _prompts(),
              ],
            ],
          ),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: _floating != null
          ? PiPSwitcher(
              floating: _floating,
              childWhenDisabled: full,
              childWhenEnabled: video,
            )
          : full,
    );
  }

  Widget _errorView() {
    final direct =
        !_forceTranscode && _source?.method != PlayMethod.transcode;
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded,
                    size: 44, color: Palette.muted),
                const SizedBox(height: 14),
                Text('Can\'t play this',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(friendlyError(_error!),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Palette.muted)),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton(
                      autofocus: true,
                      onPressed: () => _load(at: _position.value),
                      child: const Text('Try again'),
                    ),
                    if (direct)
                      OutlinedButton(
                        onPressed: () {
                          _forceTranscode = true;
                          _load(at: _position.value);
                        },
                        child: const Text('Try transcoding'),
                      ),
                    OutlinedButton(
                        onPressed: _close, child: const Text('Back')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniOverlay() {
    return AnimatedOpacity(
      opacity: _controls ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: IgnorePointer(
        ignoring: !_controls,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlayerButton(
                icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                tooltip: _playing ? 'Pause' : 'Play',
                filled: true,
                size: 34,
                onPressed: _togglePlay,
              ),
              const SizedBox(width: 12),
              PlayerButton(
                icon: Icons.open_in_full_rounded,
                tooltip: 'Restore window',
                filled: true,
                onPressed: _toggleMini,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Skip intro / up next. Shown whether or not the controls are.
  Widget _prompts() {
    final next = _next;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      right: 24,
      bottom: _controls ? 132 : 36,
      child: SafeArea(
        child: _upNext && next != null
            ? _UpNextCard(
                next: next,
                countdown: _countdown,
                onPlay: _playNext,
                onDismiss: _dismissUpNext,
              )
            : (_intro != null
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => _seekTo(_intro!.end),
                    icon: const Icon(Icons.fast_forward_rounded, size: 20),
                    label: const Text('Skip intro'),
                  )
                : const SizedBox.shrink()),
      ),
    );
  }

  Widget _overlay() {
    // Watched so the buttons relabel if Settings change mid-playback.
    final skip = ref.watch(settingsProvider.select(
        (s) => (back: s.skipBackSeconds, forward: s.skipForwardSeconds)));
    final source = _source;
    final chapters = _item.chapters;
    final bottomBar = Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SeekBar(
            position: _position,
            buffer: _buffer,
            duration: _duration,
            chapters: [for (final c in chapters) c.start],
            onSeek: _seekTo,
            onInteract: _armHide,
            step: Duration(seconds: skip.forward),
            backStep: Duration(seconds: skip.back),
          ),
          if (_controls)
            Row(
              children: [
                ValueListenableBuilder(
                  valueListenable: _position,
                  builder: (context, p, _) => Text(
                    '${formatClock(p)} / ${formatClock(_duration)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: [
                        if (chapters.isNotEmpty) ...[
                          PlayerButton(
                            icon: Icons.skip_previous_rounded,
                            tooltip: 'Previous chapter',
                            onPressed: () => _chapter(-1),
                          ),
                          PlayerButton(
                            icon: Icons.skip_next_rounded,
                            tooltip: 'Next chapter',
                            onPressed: () => _chapter(1),
                          ),
                          PlayerButton(
                            icon: Icons.format_list_bulleted_rounded,
                            tooltip: 'Chapters',
                            onPressed: _openChapters,
                          ),
                        ],
                        PlayerButton(
                          icon: Icons.subtitles_outlined,
                          tooltip: 'Audio and subtitles',
                          onPressed: _openTracks,
                        ),
                        PlayerButton(
                          icon: Icons.tune_rounded,
                          tooltip: 'Quality and playback',
                          onPressed: _openSettings,
                        ),
                        if (_next != null)
                          PlayerButton(
                            icon: Icons.fast_forward_rounded,
                            tooltip: 'Next episode',
                            onPressed: _playNext,
                          ),
                        if (_isDesktop)
                          PlayerButton(
                            icon: _fullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                            tooltip:
                                _fullscreen ? 'Exit full screen' : 'Full screen',
                            onPressed: _toggleFullscreen,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrubber alone while seeking with the controls hidden.
        if (_peek && !_controls)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: ExcludeFocus(child: bottomBar),
            ),
          ),
        AnimatedOpacity(
          opacity: _controls ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: IgnorePointer(
            ignoring: !_controls,
            child: ExcludeFocus(
              excluding: !_controls,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Two scrims keep the middle of the picture untouched.
                  const IgnorePointer(
                    child: Column(
                      children: [
                        _Scrim(height: 120, top: true),
                        Spacer(),
                        _Scrim(height: 190, top: false),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
                        child: Row(
                          children: [
                            PlayerButton(
                              icon: Icons.arrow_back_rounded,
                              tooltip: 'Back',
                              onPressed: _close,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _item.cardTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700),
                                  ),
                                  if (_item.kind == MediaKind.episode)
                                    Text(
                                      _item.cardSubtitle ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: Colors.white70),
                                    ),
                                ],
                              ),
                            ),
                            if (source != null) ...[
                              const SizedBox(width: 10),
                              Tag(source.method.label.toUpperCase()),
                            ],
                            if (_pipAvailable)
                              PlayerButton(
                                icon: Icons.picture_in_picture_alt_rounded,
                                tooltip: 'Picture in picture',
                                onPressed: _enterPip,
                              ),
                            if (_isDesktop)
                              PlayerButton(
                                icon: Icons.picture_in_picture_alt_rounded,
                                tooltip: 'Mini player',
                                onPressed: _toggleMini,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PlayerButton(
                          icon: Icons.replay_rounded,
                          iconWidget: SkipIcon(
                              seconds: skip.back, forward: false, size: 34),
                          tooltip: 'Back ${skip.back} seconds',
                          size: 34,
                          onPressed: _skipBack,
                        ),
                        const SizedBox(width: 28),
                        PlayerButton(
                          focusNode: _playFocus,
                          icon: _playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          tooltip: _playing ? 'Pause' : 'Play',
                          size: 50,
                          filled: true,
                          onPressed: _togglePlay,
                        ),
                        const SizedBox(width: 28),
                        PlayerButton(
                          icon: Icons.replay_rounded,
                          iconWidget: SkipIcon(
                              seconds: skip.forward, forward: true, size: 34),
                          tooltip: 'Forward ${skip.forward} seconds',
                          size: 34,
                          onPressed: _skipForward,
                        ),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(top: false, child: bottomBar),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // -- panels ---------------------------------------------------------------

  String _trackLabel(String? title, String? language, String id) {
    final parts = [
      if ((language ?? '').isNotEmpty) language!.toUpperCase(),
      if ((title ?? '').isNotEmpty) title!,
    ];
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }

  void _pick(VoidCallback action) {
    Navigator.of(context, rootNavigator: true).pop();
    action();
  }

  Future<void> _openPanel(WidgetBuilder builder) async {
    _hideTimer?.cancel();
    _panelOpen = true;
    try {
      await showPanel<void>(context, builder: builder);
    } finally {
      _panelOpen = false;
      // Closing the panel hands focus back to the button that opened it.
      _showControls();
    }
  }

  void _openTracks() {
    final source = _source;
    if (source == null) return;
    final transcoding = source.method == PlayMethod.transcode;
    final audio = _tracks.audio.where((t) => _real(t.id)).toList();
    final subs = _tracks.subtitle.where((t) => _real(t.id)).toList();
    final sidecars = source.subtitleStreams
        .where((s) => s.isExternal && s.url != null)
        .toList();
    // Start the remote on the subtitle in use; "Off" when there isn't one.
    final subtitleOn = transcoding
        ? source.subtitleStreams.any((s) => s.id == _subtitleId)
        : subs.any((t) => t.id == _track.subtitle.id) ||
            sidecars.any((s) => s.url == _track.subtitle.id);
    _openPanel(
      (_) => OptionPanel(
        title: 'Audio and subtitles',
        children: [
          const OptionHeading('Audio'),
          if (transcoding)
            for (final s in source.audioStreams)
              OptionTile(
                label: s.title,
                selected: s.id == _audioId ||
                    (_audioId == null && (s.selected || s.isDefault)),
                onTap: () => _pick(() {
                  _audioId = s.id;
                  _load(at: _position.value);
                }),
              )
          else
            for (final t in audio)
              OptionTile(
                label: _trackLabel(t.title, t.language, t.id),
                detail: [
                  ?t.codec?.toUpperCase(),
                  if ((t.audiochannels ?? t.channelscount) != null)
                    '${t.audiochannels ?? t.channelscount} ch',
                ].join(' · '),
                selected: _track.audio.id == t.id ||
                    (_track.audio.id == 'auto' && t == audio.first),
                onTap: () => _pick(() => _player.setAudioTrack(t)),
              ),
          const OptionHeading('Subtitles'),
          if (transcoding) ...[
            OptionTile(
              label: 'Off',
              autofocus: !subtitleOn,
              selected: (_subtitleId ?? '').isEmpty,
              onTap: () => _pick(() {
                _subtitleId = '';
                _player.setSubtitleTrack(SubtitleTrack.no());
                _load(at: _position.value);
              }),
            ),
            for (final s in source.subtitleStreams)
              OptionTile(
                label: s.title,
                autofocus: s.id == _subtitleId,
                selected: s.id == _subtitleId,
                onTap: () => _pick(() {
                  _subtitleId = s.id;
                  _load(at: _position.value);
                }),
              ),
          ] else ...[
            OptionTile(
              label: 'Off',
              autofocus: !subtitleOn,
              selected: _track.subtitle.id == 'no',
              onTap: () =>
                  _pick(() => _player.setSubtitleTrack(SubtitleTrack.no())),
            ),
            for (final t in subs)
              OptionTile(
                label: _trackLabel(t.title, t.language, t.id),
                detail: t.codec?.toUpperCase(),
                autofocus: _track.subtitle.id == t.id,
                selected: _track.subtitle.id == t.id,
                onTap: () => _pick(() => _player.setSubtitleTrack(t)),
              ),
            for (final s in sidecars)
              OptionTile(
                label: s.title,
                detail: 'External',
                autofocus: _track.subtitle.id == s.url,
                selected: _track.subtitle.id == s.url,
                onTap: () => _pick(() => _player.setSubtitleTrack(
                    SubtitleTrack.uri(s.url!,
                        title: s.title, language: s.language))),
              ),
          ],
        ],
      ),
    );
  }

  void _openSettings() {
    final source = _source;
    final v = source?.version ?? _version;
    final sourceKbps = _version?.bitrateKbps;
    _openPanel(
      (_) => OptionPanel(
        title: 'Quality and playback',
        children: [
          if (source != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                [source.method.label, if (v != null && v.label.isNotEmpty) v.label]
                    .join(' — '),
                style: const TextStyle(color: Palette.muted, fontSize: 13),
              ),
            ),
          const OptionHeading('Quality'),
          for (final q in QualityOption.all)
            // Offering a bitrate above the file's own would only waste CPU.
            if (q.kbps == null || sourceKbps == null || q.kbps! < sourceKbps)
              OptionTile(
                label: q.label,
                detail: q.kbps == null ? 'Direct play' : 'Transcode',
                autofocus: q.kbps == _maxBitrate,
                selected: q.kbps == _maxBitrate,
                onTap: () => _pick(() {
                  if (q.kbps == _maxBitrate) return;
                  _maxBitrate = q.kbps;
                  _forceTranscode = false;
                  _fallbackTried = q.kbps != null;
                  _load(at: _position.value);
                }),
              ),
          const OptionHeading('Speed'),
          for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
            OptionTile(
              label: r == 1.0 ? 'Normal' : '$r×',
              selected: _rate == r,
              onTap: () => _pick(() {
                _rate = r;
                _player.setRate(r);
              }),
            ),
          const OptionHeading('Picture'),
          for (final (fit, label) in const [
            (BoxFit.contain, 'Fit to screen'),
            (BoxFit.cover, 'Fill screen (crop)'),
            (BoxFit.fill, 'Stretch'),
          ])
            OptionTile(
              label: label,
              selected: _fit == fit,
              onTap: () => _pick(() => setState(() => _fit = fit)),
            ),
        ],
      ),
    );
  }

  void _openChapters() {
    final current = _chapterIndex;
    final chapters = _item.chapters;
    _openPanel(
      (_) => OptionPanel(
        title: 'Chapters',
        children: [
          for (var i = 0; i < chapters.length; i++)
            OptionTile(
              label: chapters[i].title,
              detail: formatClock(chapters[i].start),
              autofocus: i == (current < 0 ? 0 : current),
              selected: i == current,
              onTap: () => _pick(() => _seekTo(chapters[i].start)),
            ),
        ],
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim({required this.height, required this.top});
  final double height;
  final bool top;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: const [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
    );
  }
}

class _UpNextCard extends StatelessWidget {
  const _UpNextCard({
    required this.next,
    required this.countdown,
    required this.onPlay,
    required this.onDismiss,
  });
  final MediaItem next;
  final int countdown;
  final VoidCallback onPlay;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Palette.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 112,
                  height: 63,
                  child: Artwork(
                    image: next.thumb ?? next.backdrop ?? next.poster,
                    aspect: 16 / 9,
                    icon: kindIcon(next.kind),
                    seed: next.title,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      countdown > 0 ? 'UP NEXT IN $countdown' : 'UP NEXT',
                      style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.3,
                        fontWeight: FontWeight.w800,
                        color: Palette.accent,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      next.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (next.episodeCode != null)
                      Text(next.episodeCode!,
                          style: const TextStyle(
                              fontSize: 12.5, color: Palette.muted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: onPlay,
                  child: const Text('Play now'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: onDismiss, child: const Text('Dismiss')),
            ],
          ),
        ],
      ),
    );
  }
}
