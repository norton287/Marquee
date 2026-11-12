import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'add_server_screen.dart';
import 'nav.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serversProvider);
    final resume = ref.watch(continueWatchingProvider);
    final nextUp = ref.watch(nextUpProvider);
    final l = AppLayout.of(context);

    Future<void> refresh() async {
      ref.invalidate(continueWatchingProvider);
      ref.invalidate(nextUpProvider);
      ref.invalidate(librariesProvider);
      ref.invalidate(recentlyAddedProvider);
      try {
        await ref.read(continueWatchingProvider.future);
      } catch (_) {}
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _Hero(
                item: resume.value?.firstOrNull,
                loading: resume.isLoading && !resume.hasValue,
              ),
            ),
            SliverToBoxAdapter(
              child: AsyncMediaShelf(
                title: 'Continue watching',
                value: resume,
                shape: CardShape.landscape,
                playOnTap: true,
              ),
            ),
            SliverToBoxAdapter(
              child: AsyncMediaShelf(
                title: 'Next up',
                value: nextUp,
                shape: CardShape.landscape,
                playOnTap: true,
              ),
            ),
            for (final s in servers)
              SliverToBoxAdapter(
                child: _ServerRecents(server: s, showName: servers.length > 1),
              ),
            SliverToBoxAdapter(child: SizedBox(height: l.tv ? 48 : 28)),
          ],
        ),
      ),
    );
  }
}

class _ServerRecents extends ConsumerWidget {
  const _ServerRecents({required this.server, required this.showName});
  final ServerConfig server;
  final bool showName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libs = ref.watch(librariesProvider(server.id));
    final l = AppLayout.of(context);
    if (libs.hasError && !libs.hasValue) {
      return Padding(
        padding: EdgeInsets.fromLTRB(l.gutter, 20, l.gutter, 0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Palette.outline),
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined, color: Palette.muted),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Can\'t reach ${server.name}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(friendlyError(libs.error!),
                        style: const TextStyle(
                            color: Palette.muted, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => ref.invalidate(librariesProvider(server.id)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final list = libs.value;
    if (list == null) {
      return const ShelfSkeleton(
          title: 'Recently added', shape: CardShape.poster);
    }
    return Column(
      children: [
        for (final lib in list)
          Consumer(builder: (context, ref, _) {
            final recent = ref.watch(recentlyAddedProvider(
                (serverId: lib.serverId, libraryId: lib.id)));
            return AsyncMediaShelf(
              title: 'New in ${lib.title}'
                  '${showName ? ' · ${server.name}' : ''}',
              value: recent,
            );
          }),
      ],
    );
  }
}

/// Full-bleed feature for the thing you were last watching.
class _Hero extends ConsumerWidget {
  const _Hero({required this.item, required this.loading});
  final MediaItem? item;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLayout.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final plexServer = ref
        .watch(serversProvider)
        .where((s) =>
            s.kind == ServerKind.plex &&
            (s.homeToken ?? s.accountToken) != null)
        .firstOrNull;
    final i = item;
    if (i == null) {
      // No hero: a compact header keeps the page from starting abruptly.
      return Padding(
        padding: EdgeInsets.fromLTRB(l.gutter, top + 20, l.gutter, 0),
        child: l.sideNav
            ? Text(loading ? ' ' : 'Home',
                style: Theme.of(context).textTheme.headlineMedium)
            : Row(
                children: [
                  const Expanded(
                    child: Align(
                        alignment: Alignment.centerLeft, child: Wordmark()),
                  ),
                  if (plexServer != null)
                    _ProfilePill(
                      server: plexServer,
                      onTap: () => showPlexProfileDialog(context, ref,
                          server: plexServer),
                    ),
                ],
              ),
      );
    }
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final height = l.phone
        ? (l.width * 0.78).clamp(280.0, 400.0)
        : (l.width * 0.4).clamp(340.0, l.tv ? 520.0 : 560.0);
    final remaining = (i.duration ?? Duration.zero) - i.viewOffset;
    return SizedBox(
      height: height + top,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Artwork(
            image: i.backdrop ?? i.thumb ?? i.poster,
            aspect: 16 / 9,
            icon: kindIcon(i.kind),
            seed: i.title,
            alignment: Alignment.topCenter,
            showIcon: false,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.35, 1],
                colors: [
                  bg.withValues(alpha: 0.55),
                  bg.withValues(alpha: 0.05),
                  bg,
                ],
              ),
            ),
          ),
          if (!l.phone)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [bg.withValues(alpha: 0.85), Colors.transparent],
                  stops: const [0, 0.6],
                ),
              ),
            ),
          if (!l.sideNav)
            Positioned(
              top: top + 14,
              left: l.gutter,
              right: l.gutter,
              child: Row(
                children: [
                  const Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wordmark(size: 18),
                    ),
                  ),
                  if (plexServer != null)
                    _ProfilePill(
                      server: plexServer,
                      onTap: () => showPlexProfileDialog(context, ref,
                          server: plexServer),
                    ),
                ],
              ),
            ),
          Positioned(
            left: l.gutter,
            right: l.gutter,
            bottom: 8,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'CONTINUE WATCHING',
                    style: TextStyle(
                      fontSize: 11.5,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w800,
                      color: Palette.accent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    i.cardTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (l.phone
                            ? Theme.of(context).textTheme.headlineMedium
                            : Theme.of(context).textTheme.displaySmall)
                        ?.copyWith(height: 1.05),
                  ),
                  if (i.cardSubtitle != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      i.cardSubtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Palette.text, fontWeight: FontWeight.w500),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 160,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: ProgressLine(i.progress),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (remaining > Duration.zero)
                        Text('${formatDuration(remaining)} left',
                            style: const TextStyle(
                                fontSize: 12.5, color: Palette.muted)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      FilledButton.icon(
                        autofocus: l.tv,
                        onPressed: () => playItem(context, i),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Resume'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: () => openItem(context, i),
                        child: const Text('Details'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Avatar + name of the active Plex Home profile in the phone header.
/// Tapping it opens the "Who's watching?" switcher.
class _ProfilePill extends StatelessWidget {
  const _ProfilePill({required this.server, required this.onTap});
  final ServerConfig server;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = server.userName ?? 'Profile';
    return Semantics(
      button: true,
      label: 'Switch Plex profile ($name)',
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        builder: (context, focused, hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          decoration: BoxDecoration(
            // Translucent so it reads over hero artwork as well as the
            // plain background.
            color: focused || hovered
                ? Palette.surfaceHigh
                : Palette.bg.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: focused ? Colors.white : Palette.outline,
              width: focused ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlexAvatar(name: name, thumb: server.userThumb, size: 26),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Palette.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
