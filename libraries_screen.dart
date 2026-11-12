import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'nav.dart';
import 'theme.dart';
import 'widgets.dart';

IconData libraryIcon(LibraryKind kind) => switch (kind) {
      LibraryKind.movies => Icons.movie_outlined,
      LibraryKind.shows => Icons.tv_rounded,
      LibraryKind.music => Icons.library_music_outlined,
      LibraryKind.other => Icons.folder_outlined,
    };

class LibrariesScreen extends ConsumerWidget {
  const LibrariesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serversProvider);
    final l = AppLayout.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(librariesProvider);
            ref.invalidate(collectionsProvider);
            ref.invalidate(playlistsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(l.gutter, 20, l.gutter, 0),
                child: Text('Libraries',
                    style: Theme.of(context).textTheme.headlineMedium),
              ),
              for (final s in servers) _ServerSection(server: s),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerSection extends ConsumerWidget {
  const _ServerSection({required this.server});
  final ServerConfig server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libs = ref.watch(librariesProvider(server.id));
    final l = AppLayout.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          server.name,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ServerDot(server.id),
              const SizedBox(width: 6),
              Text(
                switch (server.kind) {
                  ServerKind.plex => 'Plex',
                  ServerKind.jellyfin => 'Jellyfin',
                  ServerKind.demo => 'Demo',
                },
                style: const TextStyle(color: Palette.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(l.gutter, 10, l.gutter, 0),
          child: libs.when(
            loading: () => const SizedBox(height: 120, child: Loading()),
            error: (e, _) => Row(
              children: [
                Expanded(
                  child: Text(friendlyError(e),
                      style: const TextStyle(color: Palette.muted)),
                ),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(librariesProvider(server.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
            data: (list) => LayoutBuilder(builder: (context, c) {
              final cols = l.phone ? 2 : (c.maxWidth / 280).floor().clamp(3, 5);
              const gap = 12.0;
              final w = (c.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < list.length; i++)
                    SizedBox(
                      width: w,
                      child: _LibraryTile(library: list[i]),
                    ),
                ],
              );
            }),
          ),
        ),
        AsyncMediaShelf(
          title: 'Collections',
          value: ref.watch(collectionsProvider(server.id)),
        ),
        AsyncMediaShelf(
          title: 'Playlists',
          value: ref.watch(playlistsProvider(server.id)),
          shape: CardShape.square,
        ),
      ],
    );
  }
}

class _LibraryTile extends StatelessWidget {
  const _LibraryTile({required this.library});
  final Library library;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => openLibrary(context, library),
      grow: 1.03,
      builder: (context, focused, hovered) => AspectRatio(
        aspectRatio: 16 / 9,
        child: ArtFrame(
          focused: focused,
          hovered: hovered,
          radius: 14,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Artwork(
                image: library.art,
                aspect: 16 / 9,
                seed: library.title,
                showIcon: false,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black26, Colors.black87],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(libraryIcon(library.kind),
                        color: Colors.white, size: 22),
                    const SizedBox(height: 4),
                    Text(
                      library.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Back button that also works for pages opened by deep link.
class BackOrHome extends StatelessWidget {
  const BackOrHome({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Back',
      icon: const Icon(Icons.arrow_back_rounded),
      style: IconButton.styleFrom(backgroundColor: Colors.black38),
      onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
    );
  }
}
