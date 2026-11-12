import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend.dart';
import 'demo.dart';
import 'jellyfin.dart';
import 'models.dart';
import 'plex.dart';
import 'seerr.dart';
import 'storage.dart';

/// Overridden in main() with the loaded storage.
final storageProvider =
    Provider<AppStorage>((ref) => throw UnimplementedError('storage'));

/// Overridden in main(): true on Android TV / Fire TV / Google TV.
final deviceIsTvProvider = Provider<bool>((ref) => false);

// ---------------------------------------------------------------------------
// Settings and servers
// ---------------------------------------------------------------------------

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(storageProvider).settings;

  void change(AppSettings Function(AppSettings s) f) {
    state = f(state);
    unawaited(ref.read(storageProvider).saveSettings(state));
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Ten-foot layout: bigger targets, focus rings, no touch-only affordances.
final tvProvider = Provider<bool>((ref) {
  final mode = ref.watch(settingsProvider.select((s) => s.tvMode));
  return switch (mode) {
    'on' => true,
    'off' => false,
    _ => ref.watch(deviceIsTvProvider),
  };
});

class ServersNotifier extends Notifier<List<ServerConfig>> {
  @override
  List<ServerConfig> build() {
    final servers = ref.read(storageProvider).servers;
    // Plex servers move between LAN, remote and relay addresses.
    Future.microtask(_revalidate);
    return servers;
  }

  Future<void> _save(List<ServerConfig> next) async {
    state = next;
    await ref.read(storageProvider).saveServers(next);
  }

  Future<void> add(ServerConfig server) => _save([
        for (final s in state)
          if (s.id != server.id) s,
        server,
      ]);

  Future<void> remove(String id) =>
      _save(state.where((s) => s.id != id).toList());

  Future<void> _revalidate() async {
    for (final s in state) {
      if (s.kind != ServerKind.plex || s.connections.length < 2) continue;
      final best = await PlexAccount.bestConnection(s.connections, s.token);
      if (best != null && best != s.baseUrl && ref.mounted) {
        await _save([
          for (final o in state) o.id == s.id ? o.copyWith(baseUrl: best) : o,
        ]);
      }
    }
  }
}

final serversProvider =
    NotifierProvider<ServersNotifier, List<ServerConfig>>(ServersNotifier.new);

MediaBackend createBackend(ServerConfig s) => switch (s.kind) {
      ServerKind.plex => PlexBackend(s),
      ServerKind.jellyfin => JellyfinBackend(s),
      ServerKind.demo => DemoBackend(s),
    };

final backendsProvider = Provider<Map<String, MediaBackend>>((ref) {
  final map = {
    for (final s in ref.watch(serversProvider)) s.id: createBackend(s),
  };
  ref.onDispose(() {
    for (final b in map.values) {
      b.dispose();
    }
  });
  return map;
});

extension BackendLookup on Ref {
  MediaBackend backend(String serverId) {
    final b = watch(backendsProvider)[serverId];
    if (b == null) throw StateError('That server was removed');
    return b;
  }
}

/// One unreachable server must never blank a merged shelf.
Future<List<T>> _orEmpty<T>(Future<List<T>> f) async {
  try {
    return await f;
  } catch (_) {
    return <T>[];
  }
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

final continueWatchingProvider = FutureProvider<List<MediaItem>>((ref) async {
  final backends = ref.watch(backendsProvider).values.toList();
  final lists =
      await Future.wait(backends.map((b) => _orEmpty(b.continueWatching())));
  final all = lists.expand((l) => l).toList();
  if (backends.length > 1) {
    final epoch = DateTime(0);
    all.sort((a, b) =>
        (b.lastViewedAt ?? epoch).compareTo(a.lastViewedAt ?? epoch));
  }
  return all;
});

final nextUpProvider = FutureProvider<List<MediaItem>>((ref) async {
  final backends = ref.watch(backendsProvider).values;
  final lists = await Future.wait(backends.map((b) => _orEmpty(b.nextUp())));
  return lists.expand((l) => l).toList();
});

final librariesProvider =
    FutureProvider.family<List<Library>, String>((ref, serverId) {
  return ref.backend(serverId).libraries();
});

typedef LibraryRef = ({String serverId, String libraryId});

final libraryProvider =
    FutureProvider.family<Library, LibraryRef>((ref, key) async {
  final libs = await ref.watch(librariesProvider(key.serverId).future);
  return libs.firstWhere((l) => l.id == key.libraryId);
});

final recentlyAddedProvider =
    FutureProvider.family<List<MediaItem>, LibraryRef>((ref, key) async {
  final lib = await ref.watch(libraryProvider(key).future);
  return ref.backend(key.serverId).recentlyAdded(lib);
});

final collectionsProvider =
    FutureProvider.family<List<MediaItem>, String>((ref, serverId) {
  return ref.backend(serverId).collections(null);
});

final libraryCollectionsProvider =
    FutureProvider.family<List<MediaItem>, LibraryRef>((ref, key) async {
  final lib = await ref.watch(libraryProvider(key).future);
  return ref.backend(key.serverId).collections(lib);
});

final libraryFoldersProvider =
    FutureProvider.family<List<MediaItem>, LibraryRef>((ref, key) async {
  final lib = await ref.watch(libraryProvider(key).future);
  return ref.backend(key.serverId).folders(lib);
});

final playlistsProvider =
    FutureProvider.family<List<MediaItem>, String>((ref, serverId) {
  return ref.backend(serverId).playlists();
});

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

final itemProvider = FutureProvider.family<MediaItem, ItemRef>((ref, key) {
  return ref.backend(key.serverId).item(key.id, kind: key.kind);
});

final childrenProvider =
    FutureProvider.family<List<MediaItem>, ItemRef>((ref, key) async {
  final parent = await ref.watch(itemProvider(key).future);
  return ref.backend(key.serverId).children(parent);
});

final similarProvider =
    FutureProvider.family<List<MediaItem>, ItemRef>((ref, key) async {
  final item = await ref.watch(itemProvider(key).future);
  return ref.backend(key.serverId).similar(item);
});

final watchlistedProvider =
    FutureProvider.family<bool, ItemRef>((ref, key) async {
  final backend = ref.backend(key.serverId);
  if (!backend.supportsWatchlist) return false;
  final item = await ref.watch(itemProvider(key).future);
  return backend.isWatchlisted(item);
});

/// Call after anything that changes watch state.
void refreshWatchState(WidgetRef ref, [MediaItem? item]) {
  ref.invalidate(continueWatchingProvider);
  ref.invalidate(nextUpProvider);
  if (item != null) {
    ref.invalidate(itemProvider(item.ref));
    ref.invalidate(childrenProvider);
  }
}

// ---------------------------------------------------------------------------
// Search, explore, watchlist
// ---------------------------------------------------------------------------

final searchProvider = FutureProvider.autoDispose
    .family<List<MediaItem>, String>((ref, query) async {
  if (query.trim().length < 2) return const [];
  // Debounce: a newer keystroke disposes this provider before it fires.
  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(const Duration(milliseconds: 280));
  if (cancelled) return const [];
  final backends = ref.watch(backendsProvider).values;
  final lists =
      await Future.wait(backends.map((b) => _orEmpty(b.search(query.trim()))));
  return lists.expand((l) => l).toList();
});

final discoverProvider = FutureProvider<List<Shelf>>((ref) async {
  final backends = ref.watch(backendsProvider).values.toList();
  final lists = await Future.wait(backends.map((b) => _orEmpty(b.discover())));
  final out = <Shelf>[];
  for (var i = 0; i < backends.length; i++) {
    for (final s in lists[i]) {
      out.add(backends.length > 1
          ? Shelf('${s.title} · ${backends[i].config.name}', s.items)
          : s);
    }
  }
  return out;
});

final watchlistProvider = FutureProvider<List<Shelf>>((ref) async {
  final backends = ref
      .watch(backendsProvider)
      .values
      .where((b) => b.supportsWatchlist)
      .toList();
  final lists =
      await Future.wait(backends.map((b) => _orEmpty(b.watchlist())));
  return [
    for (var i = 0; i < backends.length; i++)
      if (lists[i].isNotEmpty)
        Shelf(
          backends.length > 1
              ? '${backends[i].watchlistName} · ${backends[i].config.name}'
              : backends[i].watchlistName,
          lists[i],
        ),
  ];
});

// ---------------------------------------------------------------------------
// Requests (Seerr / Overseerr / Jellyseerr)
// ---------------------------------------------------------------------------

final seerrProvider = Provider<SeerrClient?>((ref) {
  final s = ref.watch(settingsProvider);
  if (!s.hasSeerr) return null;
  final client =
      SeerrClient(s.seerrUrl!, apiKey: s.seerrApiKey, cookie: s.seerrCookie);
  ref.onDispose(client.close);
  return client;
});

typedef SeerrRow = ({String title, List<SeerrItem> items});

final seerrShelvesProvider = FutureProvider<List<SeerrRow>>((ref) async {
  final c = ref.watch(seerrProvider);
  if (c == null) return const [];
  final names = [
    'Trending',
    'Popular movies',
    'Popular shows',
    'Upcoming movies',
    'Upcoming shows',
  ];
  final results = await Future.wait([
    c.trending(), // Let a failure here surface: it means Seerr is unreachable.
    _orEmpty(c.popularMovies()),
    _orEmpty(c.popularShows()),
    _orEmpty(c.upcomingMovies()),
    _orEmpty(c.upcomingShows()),
  ]);
  return [
    for (var i = 0; i < names.length; i++)
      if (results[i].isNotEmpty) (title: names[i], items: results[i]),
  ];
});

final seerrSearchProvider = FutureProvider.autoDispose
    .family<List<SeerrItem>, String>((ref, query) async {
  final c = ref.watch(seerrProvider);
  if (c == null || query.trim().length < 2) return const [];
  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  if (cancelled) return const [];
  return _orEmpty(c.search(query.trim()));
});

typedef SeerrRef = ({String mediaType, int tmdbId});

final seerrDetailsProvider =
    FutureProvider.family<SeerrItem, SeerrRef>((ref, key) {
  final c = ref.watch(seerrProvider);
  if (c == null) throw StateError('Requests are not set up');
  return c.details(key.mediaType, key.tmdbId);
});

final seerrRequestsProvider = FutureProvider<List<SeerrRequest>>((ref) async {
  final c = ref.watch(seerrProvider);
  return c == null ? const [] : c.requests();
});
