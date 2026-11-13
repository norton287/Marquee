import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'theme.dart';
import 'widgets.dart';

@immutable
class MusicState {
  const MusicState({
    this.queue = const [],
    this.index = 0,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
  });
  final List<MediaItem> queue;
  final int index;
  final bool playing;
  final Duration position;
  final Duration duration;
  final String? error;

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
  }) =>
      MusicState(
        queue: queue ?? this.queue,
        index: index ?? this.index,
        playing: playing ?? this.playing,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        error: error,
      );
}

/// App-wide music playback with a queue. Lives outside any screen so music
/// keeps going while you browse.
class MusicController extends Notifier<MusicState> {
  Player? _player;
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  MusicState build() {
    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
      _player?.dispose();
    });
    return const MusicState();
  }

  Player _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final p = Player(configuration: const PlayerConfiguration(title: 'Marquee'));
    _subs.addAll([
      p.stream.playing.listen((v) => state = state.copyWith(playing: v)),
      p.stream.duration.listen((v) => state = state.copyWith(duration: v)),
      p.stream.position.listen((v) {
        // Once a second is plenty for a progress bar.
        if ((v - state.position).inMilliseconds.abs() >= 900) {
          state = state.copyWith(position: v);
        }
      }),
      p.stream.playlist.listen((pl) {
        if (pl.index != state.index && pl.index < state.queue.length) {
          state = state.copyWith(index: pl.index, position: Duration.zero);
        }
      }),
      p.stream.error.listen((e) => state = state.copyWith(error: e)),
    ]);
    return _player = p;
  }

  Future<void> playQueue(List<MediaItem> tracks, int startIndex) async {
    if (tracks.isEmpty) return;
    state = MusicState(queue: tracks, index: startIndex, playing: true);
    try {
      final backends = ref.read(backendsProvider);
      final medias = <Media>[];
      for (final t in tracks) {
        final src = await backends[t.serverId]!
            .playback(t, const PlaybackRequest());
        medias.add(Media(src.url, httpHeaders: src.headers));
      }
      await _ensure().open(Playlist(medias, index: startIndex));
    } catch (e) {
      state = state.copyWith(playing: false, error: friendlyError(e));
    }
  }

  void toggle() => _player?.playOrPause();
  void pause() => _player?.pause();
  void next() => _player?.next();
  void previous() {
    if (state.position > const Duration(seconds: 4)) {
      seek(Duration.zero);
    } else {
      _player?.previous();
    }
  }

  void jump(int index) => _player?.jump(index);

  void seek(Duration to) {
    state = state.copyWith(position: to);
    _player?.seek(to);
  }

  Future<void> shuffleQueue() async {
    if (state.queue.length < 2) return;
    final shuffled = [...state.queue]..shuffle();
    await playQueue(shuffled, 0);
  }

  Future<void> stop() async {
    await _player?.stop();
    state = const MusicState();
  }
}

final musicProvider =
    NotifierProvider<MusicController, MusicState>(MusicController.new);

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
