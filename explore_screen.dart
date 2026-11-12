import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../core/seerr.dart';
import 'theme.dart';
import 'widgets.dart';

/// Trending and recommendations, the watchlist, and requests.
class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  int _tab = 0;
  static const _labels = ['Discover', 'Watchlist', 'Requests'];

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(l.gutter, 20, l.gutter, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Explore',
                        style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (var i = 0; i < _labels.length; i++)
                          ChoiceChip(
                            label: Text(_labels[i]),
                            selected: _tab == i,
                            onSelected: (_) => setState(() => _tab = i),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            ...switch (_tab) {
              0 => _discover(),
              1 => _watchlist(),
              _ => _requests(),
            },
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  List<Widget> _discover() {
    final hasSeerr = ref.watch(settingsProvider.select((s) => s.hasSeerr));
    final trending = ref.watch(seerrShelvesProvider);
    final local = ref.watch(discoverProvider);
    return [
      if (!hasSeerr)
        SliverToBoxAdapter(
          child: _Notice(
            icon: Icons.local_fire_department_outlined,
            title: 'See what\'s trending and request it',
            body: 'Connect Seerr (or Overseerr / Jellyseerr) to browse '
                'trending movies and shows and request them for your server.',
            action: 'Set up requests',
            onAction: () => context.go('/settings'),
          ),
        )
      else if (trending.hasError && !trending.hasValue)
        SliverToBoxAdapter(
          child: _Notice(
            icon: Icons.cloud_off_outlined,
            title: 'Can\'t reach your request server',
            body: friendlyError(trending.error!),
            action: 'Retry',
            onAction: () => ref.invalidate(seerrShelvesProvider),
          ),
        )
      else if (!trending.hasValue)
        const SliverToBoxAdapter(
          child: ShelfSkeleton(title: 'Trending', shape: CardShape.poster),
        )
      else
        for (final shelf in trending.value!)
          SliverToBoxAdapter(
            child: SeerrShelf(title: shelf.title, items: shelf.items),
          ),
      if (!local.hasValue && !local.hasError)
        const SliverToBoxAdapter(
          child: ShelfSkeleton(
              title: 'From your libraries', shape: CardShape.poster),
        ),
      for (final shelf in local.value ?? const <Shelf>[])
        SliverToBoxAdapter(
          child: MediaShelf(title: shelf.title, items: shelf.items),
        ),
    ];
  }

  List<Widget> _watchlist() {
    final lists = ref.watch(watchlistProvider);
    return lists.when(
      loading: () => const [
        SliverFillRemaining(hasScrollBody: false, child: Loading()),
      ],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: MessageView.error(e,
              onRetry: () => ref.invalidate(watchlistProvider)),
        ),
      ],
      data: (shelves) => shelves.isEmpty
          ? const [
              SliverFillRemaining(
                hasScrollBody: false,
                child: MessageView(
                  icon: Icons.bookmark_border_rounded,
                  title: 'Your watchlist is empty',
                  body: 'Use the bookmark on any movie or show to save it '
                      'for later. Plex uses your Plex Watchlist; Jellyfin '
                      'uses Favorites.',
                ),
              ),
            ]
          : [
              for (final s in shelves) ...[
                SliverToBoxAdapter(child: SectionTitle(s.title)),
                MediaSliverGrid(items: s.items),
              ],
            ],
    );
  }

  List<Widget> _requests() {
    final hasSeerr = ref.watch(settingsProvider.select((s) => s.hasSeerr));
    if (!hasSeerr) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: MessageView(
            icon: Icons.add_task_rounded,
            title: 'Requests aren\'t set up',
            body: 'Connect Seerr, Overseerr or Jellyseerr in Settings to '
                'request movies and shows and follow their progress.',
            action: 'Open Settings',
            onAction: () => context.go('/settings'),
          ),
        ),
      ];
    }
    final requests = ref.watch(seerrRequestsProvider);
    final l = AppLayout.of(context);
    return requests.when(
      loading: () => const [
        SliverFillRemaining(hasScrollBody: false, child: Loading()),
      ],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: MessageView.error(e,
              onRetry: () => ref.invalidate(seerrRequestsProvider)),
        ),
      ],
      data: (list) => list.isEmpty
          ? const [
              SliverFillRemaining(
                hasScrollBody: false,
                child: MessageView(
                  icon: Icons.add_task_rounded,
                  title: 'No requests yet',
                  body: 'Anything you request from Discover shows up here.',
                ),
              ),
            ]
          : [
              SliverPadding(
                padding: EdgeInsets.symmetric(
                    horizontal: l.gutter - 8, vertical: 8),
                sliver: SliverList.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => _RequestTile(request: list[i]),
                ),
              ),
            ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onAction,
  });
  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(l.gutter, 14, l.gutter, 0),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Palette.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Palette.outline),
        ),
        child: Wrap(
          spacing: 16,
          runSpacing: 14,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: Palette.accent),
                  const SizedBox(width: 14),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(body,
                            style: const TextStyle(
                                color: Palette.muted, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            FilledButton(onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seerr tiles
// ---------------------------------------------------------------------------

Color _statusColor(SeerrStatus s) => switch (s) {
      SeerrStatus.available => const Color(0xFF4ADE80),
      SeerrStatus.partial => const Color(0xFF4ADE80),
      SeerrStatus.processing => const Color(0xFF60A5FA),
      SeerrStatus.pending => const Color(0xFFFBBF24),
      SeerrStatus.none => Palette.muted,
    };

class SeerrShelf extends StatelessWidget {
  const SeerrShelf({super.key, required this.title, required this.items});
  final String title;
  final List<SeerrItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final l = AppLayout.of(context);
    return HorizontalShelf(
      title: title,
      itemCount: items.length,
      itemWidth: l.posterWidth,
      itemHeight: l.posterWidth * 1.5 + cardTextHeight(context),
      itemBuilder: (context, i) => SeerrCard(item: items[i]),
    );
  }
}

class SeerrCard extends StatelessWidget {
  const SeerrCard({super.key, required this.item});
  final SeerrItem item;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => showPanel<void>(context,
          builder: (_) => SeerrDetailPanel(item: item), width: 440),
      builder: (context, focused, hovered) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ArtFrame(
              focused: focused,
              hovered: hovered,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Artwork(
                    image: item.poster == null ? null : ImageRef(item.poster!),
                    icon: item.isMovie ? Icons.movie_outlined : Icons.tv,
                    seed: item.title,
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Tag(item.isMovie ? 'MOVIE' : 'SERIES'),
                  ),
                  if (item.status != SeerrStatus.none)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: _statusColor(item.status),
                        child: Icon(
                          item.status == SeerrStatus.available ||
                                  item.status == SeerrStatus.partial
                              ? Icons.check_rounded
                              : Icons.schedule_rounded,
                          size: 13,
                          color: Palette.bg,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13.5, height: 1.3, fontWeight: FontWeight.w600)),
          Text.rich(
            TextSpan(children: [
              if (item.year != null) TextSpan(text: '${item.year}'),
              if (item.year != null && (item.rating ?? 0) > 0)
                const TextSpan(text: ' · '),
              if ((item.rating ?? 0) > 0) ratingSpan(item.rating!, size: 13),
            ]),
            maxLines: 1,
            style: const TextStyle(
                fontSize: 12, height: 1.3, color: Palette.muted),
          ),
        ],
      ),
    );
  }
}

/// Details for a title from Seerr with the request action.
class SeerrDetailPanel extends ConsumerStatefulWidget {
  const SeerrDetailPanel({super.key, required this.item});
  final SeerrItem item;

  @override
  ConsumerState<SeerrDetailPanel> createState() => _SeerrDetailPanelState();
}

class _SeerrDetailPanelState extends ConsumerState<SeerrDetailPanel> {
  final _seasons = <int>{};
  bool _sending = false;
  String? _message;

  SeerrRef get _key =>
      (mediaType: widget.item.mediaType, tmdbId: widget.item.tmdbId);

  Future<void> _request(SeerrItem item) async {
    final client = ref.read(seerrProvider);
    if (client == null) return;
    setState(() {
      _sending = true;
      _message = null;
    });
    try {
      await client.request(item, seasons: _seasons.toList()..sort());
      ref.invalidate(seerrDetailsProvider(_key));
      ref.invalidate(seerrRequestsProvider);
      ref.invalidate(seerrShelvesProvider);
      if (mounted) setState(() => _message = 'Requested');
    } catch (e) {
      if (mounted) setState(() => _message = friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Start from what the card knew, then fill in from the details call.
    final item = ref.watch(seerrDetailsProvider(_key)).value ?? widget.item;
    final status = item.status;
    final requestable =
        status == SeerrStatus.none || status == SeerrStatus.partial;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        if (item.backdrop != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Artwork(
                image: ImageRef(item.backdrop!),
                aspect: 16 / 9,
                seed: item.title,
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text(item.title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tag(item.isMovie ? 'MOVIE' : 'SERIES'),
            if (item.year != null)
              Text('${item.year}',
                  style: const TextStyle(color: Palette.muted)),
            if ((item.rating ?? 0) > 0)
              Text.rich(ratingSpan(item.rating!),
                  style: const TextStyle(color: Palette.muted)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 9, color: _statusColor(status)),
                const SizedBox(width: 5),
                Text(status.label,
                    style: TextStyle(
                        color: _statusColor(status),
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ],
            ),
          ],
        ),
        if ((item.overview ?? '').isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(item.overview!,
              style: TextStyle(color: Palette.text.withValues(alpha: 0.86))),
        ],
        if (!item.isMovie && requestable && item.seasons.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Seasons', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Leave all unselected to request every season.',
              style: TextStyle(color: Palette.muted, fontSize: 12.5)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in item.seasons)
                FilterChip(
                  label: Text('S$n'),
                  selected: _seasons.contains(n),
                  onSelected: (v) => setState(
                      () => v ? _seasons.add(n) : _seasons.remove(n)),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        if (requestable)
          FilledButton.icon(
            autofocus: true,
            onPressed: _sending ? null : () => _request(item),
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.add_rounded),
            label: Text(status == SeerrStatus.partial
                ? 'Request more'
                : 'Request'),
          ),
        if (status == SeerrStatus.available ||
            status == SeerrStatus.partial) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              context.go(Uri(
                  path: '/search',
                  queryParameters: {'q': item.title}).toString());
            },
            icon: const Icon(Icons.search_rounded, size: 18),
            label: const Text('Find in my libraries'),
          ),
        ],
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message!,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.request});
  final SeerrRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (
      mediaType: request.isMovie ? 'movie' : 'tv',
      tmdbId: request.tmdbId,
    );
    // The request list has ids only; titles and posters come per item.
    final item = ref.watch(seerrDetailsProvider(key)).value;
    final color = request.approval == 3
        ? Theme.of(context).colorScheme.error
        : _statusColor(request.approval == 1
            ? SeerrStatus.pending
            : (request.mediaStatus == SeerrStatus.none
                ? SeerrStatus.processing
                : request.mediaStatus));
    return Pressable(
      onTap: item == null
          ? null
          : () => showPanel<void>(context,
              builder: (_) => SeerrDetailPanel(item: item), width: 440),
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
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 52,
                height: 78,
                child: Artwork(
                  image: item?.poster == null ? null : ImageRef(item!.poster!),
                  icon: request.isMovie ? Icons.movie_outlined : Icons.tv,
                  seed: '${request.tmdbId}',
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item?.title ?? '…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      request.isMovie ? 'Movie' : 'Series',
                      if (item?.year != null) '${item!.year}',
                      if (request.requestedBy != null)
                        'by ${request.requestedBy}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Palette.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Tag(request.statusLabel.toUpperCase(), color: color),
          ],
        ),
      ),
    );
  }
}
