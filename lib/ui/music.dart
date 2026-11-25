import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/models.dart';
import '../core/music_engine.dart';

export '../core/music_engine.dart' show MusicState;
import '../core/providers.dart';
import 'theme.dart';
import 'widgets.dart';

/// media_kit behind the engine's [TrackPlayer]. The mpv player is only
/// created when music first plays (not at startup, and never on a TV that
/// plays none).
class MediaKitTrackPlayer implements TrackPlayer {
  Player? _p;
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];

  Player get _player {
    final existing = _p;
    if (existing != null) return existing;
    final p = Player(configuration: const PlayerConfiguration(title: 'Marquee'));
    _subs.addAll([
      p.stream.playing.listen(_playing.add),
      p.stream.buffering.listen(_buffering.add),
      p.stream.position.listen(_position.add),
      p.stream.duration.listen(_duration.add),
      p.stream.completed.where((done) => done).listen((_) => _completed.add(null)),
      p.stream.error.listen(_error.add),
    ]);
    return _p = p;
  }

  @override
  Future<void> open(String url, Map<String, String> headers) =>
      _player.open(Media(url, httpHeaders: headers), play: false);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() async => _p?.pause();
  @override
  Future<void> stop() async => _p?.stop();
  @override
  Future<void> seek(Duration to) async => _p?.seek(to);
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<String> get error => _error.stream;

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _p?.dispose();
  }
}

/// Makes the player music plays through (tests swap in a fake).
final trackPlayerFactoryProvider =
    Provider<TrackPlayer Function()>((_) => MediaKitTrackPlayer.new);

/// Asked before music starts (audio focus on phones, set up in main);
/// null = always allowed.
final musicFocusProvider = Provider<Future<bool> Function()?>((_) => null);

/// The one music engine: the app, the lock screen and the car share it.
final musicEngineProvider = Provider<MusicEngine>((ref) {
  final engine = MusicEngine(
    player: ref.watch(trackPlayerFactoryProvider)(),
    // Read at each use: a reconnect recreates the server's backend.
    backendFor: (id) => ref.read(backendsProvider)[id],
    reconnect: (id) => ref.read(serversProvider.notifier).revalidate(id),
    describeError: friendlyError,
    beforePlay: ref.watch(musicFocusProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// App-wide music playback with a queue. Lives outside any screen so music
/// keeps going while you browse; the work is done by [MusicEngine].
class MusicController extends Notifier<MusicState> {
  MusicEngine get _engine => ref.read(musicEngineProvider);

  @override
  MusicState build() {
    final engine = ref.watch(musicEngineProvider);
    final sub = engine.states.listen((s) => state = s);
    ref.onDispose(sub.cancel);
    return engine.state;
  }

  Future<void> playQueue(List<MediaItem> tracks, int startIndex) =>
      _engine.playQueue(tracks, startIndex);
  void toggle() => _engine.toggle();
  void pause() => _engine.pause();
  void next() => _engine.next();
  void previous() => _engine.previous();
  void jump(int index) => _engine.jump(index);
  void seek(Duration to) => _engine.seek(to);
  Future<void> shuffleQueue() => _engine.shuffleQueue();
  Future<void> stop() => _engine.stop();

  /// Pauses music while a video plays and keeps anything (headset button,
  /// lock screen, car) from starting it until the video closes.
  void holdForVideo(bool hold) {
    _engine.holdForVideo(hold);
    // While held, music never switched the screen lock off (the video owned
    // it). A video that never started never took the lock either, so it
    // won't release it on close: apply music's own wish now (TV only).
    if (!hold && ref.read(tvProvider) && !state.playing) {
      _keepScreenOn(false);
    }
  }
}

final musicProvider =
    NotifierProvider<MusicController, MusicState>(MusicController.new);

/// Keeps the screen on (or lets it sleep). Swappable for tests.
Future<void> Function(bool on) keepScreenOn =
    (on) => WakelockPlus.toggle(enable: on);

/// Whether music should hold the screen on: only on a TV, and only while it
/// plays. A TV has no media session, so its screen saver starts after the
/// idle time even with music playing (video holds the screen through
/// media_kit_video). Phones keep their normal screen timeout.
final musicKeepsScreenOnProvider = Provider<bool>((ref) =>
    ref.watch(tvProvider) && ref.watch(musicProvider.select((s) => s.playing)));

/// Applies [musicKeepsScreenOnProvider] whenever it changes (from the app
/// root, which lives as long as the app).
void watchMusicScreen(WidgetRef ref) {
  ref.listen<bool>(musicKeepsScreenOnProvider, (was, on) {
    if (was == on) return;
    // While a video holds music the video's own lock owns the screen (and
    // turns it off when the video closes): never switch it off under it.
    if (!on && ref.read(musicEngineProvider).held) return;
    _keepScreenOn(on);
  });
}

void _keepScreenOn(bool on) => keepScreenOn(on).catchError((Object e) {
      debugPrint('keep screen on ($on) failed: $e');
    });

/// Whether the music queue plays anything from [serverIds]: after a Plex
/// profile switch those streams still carry the old profile's token.
bool musicFromServers(List<MediaItem> queue, Set<String> serverIds) =>
    queue.any((t) => serverIds.contains(t.serverId));

/// Slim bar above the navigation while music is queued.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(musicProvider.select((s) => s.current));
    if (track == null) return const SizedBox.shrink();
    final playing = ref.watch(musicProvider.select((s) => s.playing));
    final ctl = ref.read(musicProvider.notifier);
    return Material(
      color: Palette.surfaceHigh,
      child: InkWell(
        // The theme's faint focus tint is hard to see on a TV across the room.
        focusColor: Palette.accent.withValues(alpha: 0.28),
        onTap: () => showPanel<void>(context,
            builder: (_) => const NowPlayingPanel()),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Consumer(builder: (context, ref, _) {
              final s = ref.watch(musicProvider);
              final total = s.duration.inMilliseconds;
              return ProgressLine(
                total <= 0 ? 0 : s.position.inMilliseconds / total,
                height: 2,
              );
            }),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: Artwork(
                        image: track.poster,
                        aspect: 1,
                        icon: Icons.music_note,
                        seed: track.title,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                          track.grandparentTitle ?? track.parentTitle ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Palette.muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: playing ? 'Pause' : 'Play',
                    onPressed: ctl.toggle,
                    icon: Icon(playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                    iconSize: 30,
                  ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: ctl.next,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                  IconButton(
                    tooltip: 'Stop',
                    onPressed: ctl.stop,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NowPlayingPanel extends ConsumerWidget {
  const NowPlayingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(musicProvider);
    final ctl = ref.read(musicProvider.notifier);
    final track = s.current;
    if (track == null) {
      return const SizedBox(
          height: 160, child: Center(child: Text('Nothing playing')));
    }
    final total = s.duration.inMilliseconds.toDouble();
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Artwork(
                  image: track.poster,
                  aspect: 1,
                  icon: Icons.music_note,
                  seed: track.title,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(track.title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(
          [?track.grandparentTitle, ?track.parentTitle].join(' — '),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Palette.muted),
        ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(s.error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 8),
        Slider(
          value: total <= 0
              ? 0
              : s.position.inMilliseconds.toDouble().clamp(0, total),
          max: total <= 0 ? 1 : total,
          onChanged: total <= 0
              ? null
              : (v) => ctl.seek(Duration(milliseconds: v.round())),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatClock(s.position),
                  style: const TextStyle(fontSize: 12, color: Palette.muted)),
              Text(formatClock(s.duration),
                  style: const TextStyle(fontSize: 12, color: Palette.muted)),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (s.queue.length > 1) ...[
              IconButton(
                tooltip: 'Shuffle',
                onPressed: ctl.shuffleQueue,
                icon: const Icon(Icons.shuffle_rounded),
              ),
              const SizedBox(width: 8),
            ],
            IconButton(
              tooltip: 'Previous',
              iconSize: 36,
              onPressed: ctl.previous,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              tooltip: s.playing ? 'Pause' : 'Play',
              autofocus: true,
              iconSize: 40,
              onPressed: ctl.toggle,
              icon: Icon(
                  s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Next',
              iconSize: 36,
              onPressed: s.hasNext ? ctl.next : null,
              icon: const Icon(Icons.skip_next_rounded),
            ),
            if (s.queue.length > 1) const SizedBox(width: 48),
          ],
        ),
        const SizedBox(height: 16),
        Text('Queue', style: Theme.of(context).textTheme.titleMedium),
        for (var i = 0; i < s.queue.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            selected: i == s.index,
            selectedColor: Palette.accent,
            leading: SizedBox(
              width: 28,
              child: Center(
                child: i == s.index
                    ? const Icon(Icons.equalizer_rounded,
                        size: 18, color: Palette.accent)
                    : Text('${i + 1}',
                        style: const TextStyle(color: Palette.muted)),
              ),
            ),
            title: Text(s.queue[i].title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: s.queue[i].duration == null
                ? null
                : Text(formatClock(s.queue[i].duration!),
                    style:
                        const TextStyle(fontSize: 12, color: Palette.muted)),
            onTap: () => ctl.jump(i),
          ),
      ],
    );
  }
}
