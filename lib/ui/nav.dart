import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'add_server_screen.dart';
import 'detail_screen.dart';
import 'explore_screen.dart';
import 'home_screen.dart';
import 'libraries_screen.dart';
import 'library_screen.dart';
import 'music.dart';
import 'player/player_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'shell.dart';

class PlayerArgs {
  const PlayerArgs(
    this.item, {
    this.startOver = false,
    this.versionId,
    this.queue = const [],
  });
  final MediaItem item;
  final bool startOver;
  final String? versionId;
  final List<MediaItem> queue;
}

const _tabs = ['home', 'libraries', 'search', 'explore', 'settings'];

/// The tab this context lives in, so pushed pages stay inside it and the
/// navigation bar stays put.
String _tabRoot(BuildContext context) {
  final segments = GoRouterState.of(context).uri.pathSegments;
  final first = segments.isEmpty ? 'home' : segments.first;
  return '/${_tabs.contains(first) ? first : 'home'}';
}

void openItem(BuildContext context, MediaItem item) {
  if (item.external) {
    // Not on a server (e.g. a Plex watchlist entry): look for it instead.
    context.go(Uri(path: '/search', queryParameters: {'q': item.title})
        .toString());
    return;
  }
  context.push(Uri(path: '${_tabRoot(context)}/item', queryParameters: {
    's': item.serverId,
    'id': item.id,
    'k': item.kind.name,
  }).toString());
}

void openLibrary(BuildContext context, Library library) {
  context.push(Uri(path: '${_tabRoot(context)}/library', queryParameters: {
    's': library.serverId,
    'l': library.id,
  }).toString());
}

/// Plays a video full screen, or hands a track to the music player.
/// [queue] is the list the item came from (album, playlist, season).
void playItem(
  BuildContext context,
  MediaItem item, {
  bool startOver = false,
  String? versionId,
  List<MediaItem>? queue,
}) {
  if (item.kind.isAudio) {
    final tracks =
        (queue ?? [item]).where((t) => t.kind.isAudio).toList();
    final index = tracks.indexWhere((t) => t.id == item.id);
    ProviderScope.containerOf(context, listen: false)
        .read(musicProvider.notifier)
        .playQueue(tracks, index < 0 ? 0 : index);
    return;
  }
  final videos =
      (queue ?? const <MediaItem>[]).where((v) => v.kind.isVideo).toList();
  context.push(
    '/player',
    extra: PlayerArgs(
      item,
      startOver: startOver,
      versionId: versionId,
      queue: videos,
    ),
  );
}

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

final routerProvider = Provider<GoRouter>((ref) {
  List<RouteBase> shared() => [
        GoRoute(
          path: 'item',
          builder: (context, state) {
            final q = state.uri.queryParameters;
            return DetailScreen(
              key: ValueKey(state.uri.toString()),
              itemRef: (
                serverId: q['s'] ?? '',
                id: q['id'] ?? '',
                kind: MediaKind.values.asNameMap()[q['k']] ?? MediaKind.unknown,
              ),
            );
          },
        ),
        GoRoute(
          path: 'library',
          builder: (context, state) {
            final q = state.uri.queryParameters;
            return LibraryScreen(
              key: ValueKey(state.uri.toString()),
              libraryRef: (serverId: q['s'] ?? '', libraryId: q['l'] ?? ''),
            );
          },
        ),
      ];

  StatefulShellBranch branch(String name, GoRouterWidgetBuilder builder) =>
      StatefulShellBranch(routes: [
        GoRoute(path: '/$name', builder: builder, routes: shared()),
      ]);

  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/home',
    redirect: (context, state) {
      final hasServers = ref.read(serversProvider).isNotEmpty;
      final loc = state.matchedLocation;
      final onboarding = loc == '/welcome' || loc == '/add-server';
      if (!hasServers && !onboarding) return '/welcome';
      if (hasServers && loc == '/welcome') return '/home';
      if (loc == '/player' && state.extra is! PlayerArgs) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomeScreen()),
      GoRoute(
        path: '/add-server',
        parentNavigatorKey: _rootKey,
        builder: (_, state) =>
            AddServerScreen(kind: state.uri.queryParameters['kind'] ?? 'plex'),
      ),
      GoRoute(
        path: '/player',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: PlayerScreen(args: state.extra! as PlayerArgs),
          transitionDuration: const Duration(milliseconds: 220),
          transitionsBuilder: (_, a, _, child) =>
              FadeTransition(opacity: a, child: child),
        ),
      ),
      StatefulShellRoute(
        builder: (_, _, shell) => AppShell(shell: shell),
        navigatorContainerBuilder: (_, shell, children) =>
            _BranchStack(index: shell.currentIndex, children: children),
        branches: [
          branch('home', (_, _) => const HomeScreen()),
          branch('libraries', (_, _) => const LibrariesScreen()),
          branch(
            'search',
            (_, state) =>
                SearchScreen(initialQuery: state.uri.queryParameters['q']),
          ),
          branch('explore', (_, _) => const ExploreScreen()),
          branch('settings', (_, _) => const SettingsScreen()),
        ],
      ),
    ],
  );
  ref.listen(serversProvider, (_, _) => router.refresh());
  ref.onDispose(router.dispose);
  return router;
});

/// Keeps every tab alive like an IndexedStack, but only the visible one can
/// take focus. Otherwise arrow keys on a TV can land on cards in a hidden
/// tab, since they're still laid out underneath.
class _BranchStack extends StatelessWidget {
  const _BranchStack({required this.index, required this.children});
  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => IndexedStack(
        index: index,
        children: [
          for (var i = 0; i < children.length; i++)
            ExcludeFocus(
              excluding: i != index,
              child: TickerMode(enabled: i == index, child: children[i]),
            ),
        ],
      );
}
