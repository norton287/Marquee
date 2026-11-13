import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'libraries_screen.dart';
import 'manage.dart';
import 'nav.dart';
import 'theme.dart';
import 'widgets.dart';

/// Details for anything on a server: movie, show, season, episode, album,
/// artist, collection, playlist or folder.
class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({super.key, required this.itemRef});
  final ItemRef itemRef;

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  String? _versionId;
  String? _seasonId;
  bool _busy = false;
  bool _shuffling = false;

  void _toast(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }

  /// Play on a show, season, album, playlist or collection: find the right
  /// thing to start with, or shuffle all playable items when [shuffle] is true.
  Future<void> _playContainer(MediaItem item, {bool shuffle = false}) async {
    setState(() {
      _busy = true;
      _shuffling = shuffle;
    });
    try {
      final backend = ref.read(backendsProvider)[item.serverId]!;
      var leaves = <MediaItem>[];
      if (item.kind == MediaKind.show) {
        final seasons = await backend.children(item);
        // Regular seasons first; specials (season 0) only as a last resort.
        final regular = seasons.where((s) => (s.index ?? 1) > 0).toList();
        final ordered = [
          ...regular,
          ...seasons.where((s) => (s.index ?? 1) <= 0),
        ];
        if (shuffle) {
          final sourceSeasons = regular.isNotEmpty ? regular : ordered;
          final lists = await Future.wait(sourceSeasons.map(backend.children));
          leaves = lists.expand((l) => l).toList();
        } else {
          for (final s in ordered) {
            if (s.played) continue;
            leaves = await backend.children(s);
            if (leaves.any((e) => !e.played)) break;
          }
          if (leaves.isEmpty && ordered.isNotEmpty) {
            leaves = await backend.children(ordered.first);
          }
        }
      } else {
        leaves = await backend.children(item);
      }
      leaves = leaves.where((e) => e.kind.isPlayable).toList();
      if (leaves.isEmpty) throw StateError('Nothing to play here yet');
      final MediaItem target;
      if (shuffle) {
        leaves = [...leaves]..shuffle();
        target = leaves.first;
      } else {
        target = leaves.first.kind.isAudio
            ? leaves.first
            : leaves.firstWhere((e) => !e.played, orElse: () => leaves.first);
      }
      if (mounted) playItem(context, target, queue: leaves);
    } catch (e) {
      _toast(e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _shuffling = false;
        });
      }
    }
  }

  Future<void> _togglePlayed(MediaItem item) async {
    try {
      await ref
          .read(backendsProvider)[item.serverId]!
          .setPlayed(item, !item.played);
      refreshWatchState(ref, item);
    } catch (e) {
      _toast(e);
    }
  }

  Future<void> _toggleWatchlist(MediaItem item, bool current) async {
    final backend = ref.read(backendsProvider)[item.serverId]!;
    try {
      await backend.setWatchlisted(item, !current);
      ref.invalidate(itemProvider(item.ref));
      ref.invalidate(watchlistedProvider(item.ref));
      ref.invalidate(watchlistProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(current
              ? 'Removed from ${backend.watchlistName}'
              : 'Added to ${backend.watchlistName}'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      _toast(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(itemProvider(widget.itemRef));
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          async.when(
            loading: () => const Loading(),
            error: (e, _) => MessageView.error(e,
                onRetry: () => ref.invalidate(itemProvider(widget.itemRef))),
            data: _content,
          ),
          Positioned(top: top + 8, left: 12, child: const BackOrHome()),
        ],
      ),
    );
  }

  Widget _content(MediaItem item) {
    final l = AppLayout.of(context);
    final kind = item.kind;
    final listing = kind == MediaKind.collection ||
        kind == MediaKind.playlist ||
        kind == MediaKind.folder ||
        kind == MediaKind.artist ||
        kind == MediaKind.album ||
        kind == MediaKind.season;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _header(item)),
        if (kind == MediaKind.show)
          SliverToBoxAdapter(child: _seasons(item))
        else if (listing)
          ..._children(item),
        if (item.people.isNotEmpty)
          SliverToBoxAdapter(child: _CastShelf(people: item.people)),
        if (kind == MediaKind.movie || kind == MediaKind.show)
          SliverToBoxAdapter(
            child: AsyncMediaShelf(
              title: 'More like this',
              value: ref.watch(similarProvider(item.ref)),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: l.tv ? 56 : 36)),
      ],
    );
  }

  // -- header ---------------------------------------------------------------

  Widget _header(MediaItem item) {
    final l = AppLayout.of(context);
    final theme = Theme.of(context);
    final bg = theme.scaffoldBackgroundColor;
    final top = MediaQuery.paddingOf(context).top;
    final wide = l.width >= 760;
    final banner = item.backdrop ?? item.thumb;
    final hasBanner = banner != null;
    final bannerHeight = hasBanner
        ? (wide ? (l.width * 0.34).clamp(300.0, 480.0) : 240.0) + top
        : top + 64;
    final posterWidth = wide ? (l.tv ? 220.0 : 200.0) : 108.0;
    final square = item.squareArt;
    final posterHeight = square ? posterWidth : posterWidth * 1.5;
    final overlap = hasBanner ? (wide ? posterHeight * 0.55 : 56.0) : 0.0;
    final showPoster = item.poster != null || !hasBanner;
    final version = item.versions
            .where((v) => v.id == _versionId)
            .firstOrNull ??
        item.versions.firstOrNull;

    final meta = <InlineSpan>[
      if (item.year != null) TextSpan(text: '${item.year}'),
      if (item.duration != null && item.kind.isPlayable)
        TextSpan(text: formatDuration(item.duration!)),
      if (item.contentRating != null) TextSpan(text: item.contentRating),
      if (item.rating != null && item.rating! > 0) ratingSpan(item.rating!),
      if (item.childCount != null && !item.kind.isPlayable)
        TextSpan(
          text: switch (item.kind) {
            MediaKind.show => '${item.childCount} seasons',
            MediaKind.season => '${item.childCount} episodes',
            MediaKind.album => '${item.childCount} tracks',
            _ => '${item.childCount} items',
          },
        ),
    ];

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.kind == MediaKind.episode && item.grandparentTitle != null)
          _Kicker(
            text: [item.grandparentTitle!, ?item.episodeCode].join(' · '),
            onTap: item.grandparentId == null
                ? null
                : () => openItem(
                      context,
                      MediaItem(
                        serverId: item.serverId,
                        id: item.grandparentId!,
                        kind: MediaKind.show,
                        title: item.grandparentTitle!,
                      ),
                    ),
          )
        else if (item.kind == MediaKind.season ||
            item.kind == MediaKind.album ||
            item.kind == MediaKind.track)
          if ((item.grandparentTitle ?? item.parentTitle) != null)
            _Kicker(text: (item.grandparentTitle ?? item.parentTitle)!),
        Text(
          item.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: (wide
                  ? theme.textTheme.displaySmall
                  : theme.textTheme.headlineSmall)
              ?.copyWith(height: 1.08),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(children: [
              for (var i = 0; i < meta.length; i++) ...[
                if (i > 0) const TextSpan(text: '  ·  '),
                meta[i],
              ],
            ]),
            style: const TextStyle(
                color: Palette.text, fontWeight: FontWeight.w500),
          ),
        ],
        if (version != null && item.kind.isVideo) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: versionTags(version)),
        ],
      ],
    );

    final rest = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        _actions(item),
        if (item.genres.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(item.genres.take(4).join(' · '),
              style: const TextStyle(color: Palette.muted, fontSize: 13)),
        ],
        if ((item.tagline ?? '').isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(item.tagline!,
              style: const TextStyle(
                  fontStyle: FontStyle.italic, color: Palette.text)),
        ],
        if ((item.overview ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: _Overview(item.overview!),
          ),
        ],
      ],
    );

    return Stack(
      children: [
        if (hasBanner)
          SizedBox(
            height: bannerHeight,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Artwork(
                  image: banner,
                  aspect: 16 / 9,
                  seed: item.title,
                  alignment: Alignment.topCenter,
                  showIcon: false,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, 0.4, 1],
                      colors: [
                        bg.withValues(alpha: 0.5),
                        bg.withValues(alpha: 0.15),
                        bg,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
              l.gutter, bannerHeight - overlap, l.gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment:
                    wide ? CrossAxisAlignment.start : CrossAxisAlignment.end,
                children: [
                  if (showPoster) ...[
                    SizedBox(
                      width: posterWidth,
                      height: posterHeight,
                      child: ArtFrame(
                        radius: item.kind == MediaKind.artist ? 999 : 12,
                        child: Artwork(
                          image: item.poster,
                          aspect: square ? 1 : 2 / 3,
                          icon: kindIcon(item.kind),
                          seed: item.title,
                        ),
                      ),
                    ),
                    SizedBox(width: wide ? 28 : 14),
                  ],
                  Expanded(
                    child: Padding(
                      // On wide layouts the text starts where the banner ends.
                      padding: EdgeInsets.only(
                          top: wide && hasBanner ? overlap * 0.38 : 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [titleBlock, if (wide) rest],
                      ),
                    ),
                  ),
                ],
              ),
              if (!wide) rest,
            ],
          ),
        ),
      ],
    );
  }

  Widget _actions(MediaItem item) {
    final l = AppLayout.of(context);
    final backend = ref.watch(backendsProvider)[item.serverId];
    final kind = item.kind;
    final playableContainer = kind == MediaKind.show ||
        kind == MediaKind.season ||
        kind == MediaKind.album ||
        kind == MediaKind.playlist ||
        kind == MediaKind.collection;
    final canWatchlist = backend != null &&
        backend.supportsWatchlist &&
        (kind == MediaKind.movie || kind == MediaKind.show);
    final listed = canWatchlist
        ? (ref.watch(watchlistedProvider(item.ref)).value ?? false)
        : false;
    final remaining = (item.duration ?? Duration.zero) - item.viewOffset;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (kind.isPlayable)
          FilledButton.icon(
            autofocus: l.tv,
            onPressed: () =>
                playItem(context, item, versionId: _versionId),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(item.inProgress
                ? 'Resume · ${formatDuration(remaining)} left'
                : 'Play'),
          )
        else if (playableContainer) ...[
          FilledButton.icon(
            autofocus: l.tv,
            onPressed: _busy ? null : () => _playContainer(item),
            icon: _busy && !_shuffling
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
          ),
          OutlinedButton.icon(
            onPressed:
                _busy ? null : () => _playContainer(item, shuffle: true),
            icon: _busy && _shuffling
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.shuffle_rounded, size: 18),
            label: const Text('Shuffle'),
          ),
        ],
        if (kind.isVideo && item.inProgress)
          IconButton.outlined(
            tooltip: 'Start from the beginning',
            onPressed: () => playItem(context, item,
                startOver: true, versionId: _versionId),
            icon: const Icon(Icons.replay_rounded),
          ),
        if (kind.isVideo || kind == MediaKind.show || kind == MediaKind.season)
          IconButton.outlined(
            tooltip: item.played ? 'Mark as unwatched' : 'Mark as watched',
            onPressed: () => _togglePlayed(item),
            icon: Icon(
              item.played
                  ? Icons.check_circle_rounded
                  : Icons.check_circle_outline_rounded,
              color: item.played ? Palette.accent : null,
            ),
          ),
        if (canWatchlist)
          IconButton.outlined(
            tooltip: listed
                ? 'Remove from ${backend.watchlistName}'
                : 'Add to ${backend.watchlistName}',
            onPressed: () => _toggleWatchlist(item, listed),
            icon: Icon(
              listed ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              color: listed ? Palette.accent : null,
            ),
          ),
        AddToPlaylistButton(item: item),
        ManageButton(item: item),
        if (kind.isVideo && item.versions.length > 1)
          SelectMenu(
            items: [
              for (final v in item.versions)
                SelectMenuItem(
                  label: v.label.isEmpty ? 'Version' : v.label,
                  selected: v.id == (_versionId ?? item.versions.first.id),
                  icon: v.id == (_versionId ?? item.versions.first.id)
                      ? Icons.check_rounded
                      : null,
                  onPressed: () => setState(() => _versionId = v.id),
                ),
            ],
            builder: (context, focusNode, toggle) => OutlinedButton.icon(
              focusNode: focusNode,
              onPressed: toggle,
              icon: const Icon(Icons.layers_outlined, size: 18),
              label: Text('${item.versions.length} versions'),
            ),
          ),
      ],
    );
  }

  // -- seasons & episodes ---------------------------------------------------

  Widget _seasons(MediaItem show) {
    final l = AppLayout.of(context);
    final seasons = ref.watch(childrenProvider(show.ref));
    return seasons.when(
      loading: () => const Padding(
          padding: EdgeInsets.all(40), child: Loading()),
      error: (e, _) => MessageView.error(e,
          onRetry: () => ref.invalidate(childrenProvider(show.ref))),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final selected = list.where((s) => s.id == _seasonId).firstOrNull ??
            list.where((s) => !s.played && (s.index ?? 1) > 0).firstOrNull ??
            list.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 18),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: l.gutter),
              child: Row(
                children: [
                  for (final s in list) ...[
                    ChoiceChip(
                      label: Text(s.title),
                      selected: s.id == selected.id,
                      onSelected: (_) => setState(() => _seasonId = s.id),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            _LeafList(parent: selected.ref),
          ],
        );
      },
    );
  }

  List<Widget> _children(MediaItem item) {
    final children = ref.watch(childrenProvider(item.ref));
    return children.when(
      loading: () => const [
        SliverToBoxAdapter(
            child: Padding(padding: EdgeInsets.all(40), child: Loading())),
      ],
      error: (e, _) => [
        SliverToBoxAdapter(
          child: MessageView.error(e,
              onRetry: () => ref.invalidate(childrenProvider(item.ref))),
        ),
      ],
      data: (list) {
        if (list.isEmpty) {
          return const [
            SliverToBoxAdapter(
              child: MessageView(
                  icon: Icons.inbox_outlined, title: 'Nothing here yet'),
            ),
          ];
        }
        final leaves = list.every(
            (c) => c.kind == MediaKind.track || c.kind == MediaKind.episode);
        if (leaves && item.kind != MediaKind.collection) {
          return [SliverToBoxAdapter(child: _LeafList(parent: item.ref))];
        }
        return [
          if (item.kind == MediaKind.artist)
            const SliverToBoxAdapter(child: SectionTitle('Albums')),
          MediaSliverGrid(
            items: list,
            contextual: item.kind == MediaKind.artist,
          ),
        ];
      },
    );
  }
}

class _Kicker extends StatelessWidget {
  const _Kicker({required this.text, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Palette.accent,
          fontWeight: FontWeight.w700,
          fontSize: 13.5,
        ),
      ),
    );
    return onTap == null ? label : InkWell(onTap: onTap, child: label);
  }
}

class _Overview extends StatefulWidget {
  const _Overview(this.text);
  final String text;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final long = widget.text.length > 280;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          maxLines: _open || !long ? null : 4,
          overflow: _open || !long ? null : TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Palette.text.withValues(alpha: 0.86)),
        ),
        if (long)
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => setState(() => _open = !_open),
            child: Text(_open ? 'Less' : 'More'),
          ),
      ],
    );
  }
}

/// Episodes of a season, or tracks of an album/playlist.
class _LeafList extends ConsumerWidget {
  const _LeafList({required this.parent});
  final ItemRef parent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLayout.of(context);
    final children = ref.watch(childrenProvider(parent));
    return children.when(
      loading: () =>
          const Padding(padding: EdgeInsets.all(40), child: Loading()),
      error: (e, _) => MessageView.error(e,
          onRetry: () => ref.invalidate(childrenProvider(parent))),
      data: (list) => Padding(
        padding: EdgeInsets.fromLTRB(l.gutter - 8, 10, l.gutter - 8, 0),
        child: Column(
          children: [
            for (final c in list)
              c.kind == MediaKind.track
                  ? _TrackTile(track: c, queue: list)
                  : _EpisodeTile(episode: c, queue: list),
          ],
        ),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.episode, this.queue});
  final MediaItem episode;
  final List<MediaItem>? queue;

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    final thumbWidth = l.phone ? 132.0 : (l.tv ? 240.0 : 200.0);
    return Pressable(
      onTap: () => playItem(context, episode, queue: queue),
      onLongPress: () => openItem(context, episode),
      grow: 1,
      builder: (context, focused, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: focused || hovered ? Palette.surface : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: focused ? Colors.white : Colors.transparent, width: 2),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: thumbWidth,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Artwork(
                        image: episode.thumb ?? episode.backdrop,
                        aspect: 16 / 9,
                        icon: Icons.tv,
                        seed: episode.title,
                      ),
                      if (episode.played)
                        const Positioned(
                          top: 6,
                          right: 6,
                          child: CircleAvatar(
                            radius: 9,
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.check,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      if (episode.inProgress)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: ProgressLine(episode.progress),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${episode.index != null ? '${episode.index}. ' : ''}${episode.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  if (episode.duration != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(formatDuration(episode.duration!),
                          style: const TextStyle(
                              color: Palette.muted, fontSize: 12.5)),
                    ),
                  if ((episode.overview ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        episode.overview!,
                        maxLines: l.phone ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Palette.muted, fontSize: 13, height: 1.35),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Details',
              onPressed: () => openItem(context, episode),
              icon: const Icon(Icons.info_outline_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track, required this.queue});
  final MediaItem track;
  final List<MediaItem> queue;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => playItem(context, track, queue: queue),
      grow: 1,
      builder: (context, focused, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        decoration: BoxDecoration(
          color: focused || hovered ? Palette.surface : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: focused ? Colors.white : Colors.transparent, width: 2),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text('${track.index ?? '·'}',
                  style: const TextStyle(color: Palette.muted)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (track.grandparentTitle != null)
                    Text(track.grandparentTitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Palette.muted, fontSize: 12.5)),
                ],
              ),
            ),
            if (track.duration != null)
              Text(formatClock(track.duration!),
                  style:
                      const TextStyle(color: Palette.muted, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

class _CastShelf extends StatelessWidget {
  const _CastShelf({required this.people});
  final List<Person> people;

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    final w = l.tv ? 120.0 : 92.0;
    final scale = MediaQuery.textScalerOf(context);
    return HorizontalShelf(
      title: 'Cast & crew',
      itemCount: people.length,
      itemWidth: w,
      itemHeight: w + 10 + scale.scale(12.5) * 2.7 + scale.scale(11.5) * 1.4,
      itemBuilder: (context, i) {
        final p = people[i];
        return Column(
          children: [
            SizedBox(
              width: w,
              height: w,
              child: ClipOval(
                child: Artwork(
                  image: p.image,
                  aspect: 1,
                  icon: Icons.person_outline,
                  seed: p.name,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(p.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.3, fontWeight: FontWeight.w600)),
            if (p.role != null)
              Text(p.role!,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5, height: 1.3, color: Palette.muted)),
          ],
        );
      },
    );
  }
}
