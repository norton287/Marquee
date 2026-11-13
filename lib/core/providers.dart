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

  void setLibraryHidden(String serverId, String libraryId, bool hidden) =>
      change((s) => s.withLibraryHidden(serverId, libraryId, hidden));
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

  Future<void> remove(String id) async {
    await _save(state.where((s) => s.id != id).toList());
    // Forget its hidden libraries so a re-added server starts clean.
    final settings = ref.read(settingsProvider.notifier);
    if (ref.read(settingsProvider).hiddenLibraries.containsKey(id)) {
      settings.change((s) => s.copyWith(
          hiddenLibraries: {...s.hiddenLibraries}..remove(id)));
    }
  }

  /// Switches all Plex servers belonging to [homeToken] to [user].
  Future<void> switchPlexProfile({
    required String homeToken,
    required PlexHomeUser user,
    String? pin,
  }) async {
    final userToken =
        await PlexAccount.switchHomeUser(homeToken, user.uuid, pin: pin);
    final resources = await PlexAccount.servers(userToken);
    final byMachine = {for (final r in resources) r.machineId: r};
    final next = <ServerConfig>[];
    for (final s in state) {
      final serverHomeToken = s.homeToken ?? s.accountToken;
      if (s.kind == ServerKind.plex && serverHomeToken == homeToken) {
        final r = byMachine[s.machineId];
        next.add(s.copyWith(
          token: r?.accessToken ?? userToken,
          accountToken: userToken,
          homeToken: homeToken,
          userId: user.uuid,
          userName: user.name,
          userThumb: user.thumb,
          connections: (r != null && r.connections.isNotEmpty)
              ? r.connections
              : s.connections,
        ));
      } else {
        next.add(s);
      }
    }
    await _save(next);
    unawaited(_revalidate());
  }

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
  // Only rebuilds when the hidden set itself changes (copyWith keeps the
  // same map otherwise), and every shelf then refetches without it.
  final hidden = ref.watch(settingsProvider.select((s) => s.hiddenLibraries));
  final map = {
    for (final s in ref.watch(serversProvider))
      s.id: createBackend(s)..hiddenLibraries = hidden[s.id] ?? const {},
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

/// [_orEmpty], minus anything from a library the user hid.
Future<List<MediaItem>> _visible(
        MediaBackend b, Future<List<MediaItem>> f) async =>
    b.visible(await _orEmpty(f));

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

final continueWatchingProvider = FutureProvider<List<MediaItem>>((ref) async {
  final backends = ref.watch(backendsProvider).values.toList();
  final lists = await Future.wait(
      backends.map((b) => _visible(b, b.continueWatching())));
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
  final lists =
      await Future.wait(backends.map((b) => _visible(b, b.nextUp())));
  return lists.expand((l) => l).toList();
});

/// Every library on the server, hidden or not (Settings lists these).
final allLibrariesProvider =
    FutureProvider.family<List<Library>, String>((ref, serverId) {
  return ref.backend(serverId).libraries();
});

/// The libraries the user hasn't hidden: what the rest of the app shows.
final librariesProvider =
    FutureProvider.family<List<Library>, String>((ref, serverId) async {
  final hidden =
      ref.watch(settingsProvider.select((s) => s.hiddenOn(serverId)));
  final all = await ref.watch(allLibrariesProvider(serverId).future);
  return all.where((l) => !hidden.contains(l.id)).toList();
});

typedef LibraryRef = ({String serverId, String libraryId});

final libraryProvider =
    FutureProvider.family<Library, LibraryRef>((ref, key) async {
  // From the full list, so an open page survives its library being hidden.
  final libs = await ref.watch(allLibrariesProvider(key.serverId).future);
  return libs.firstWhere((l) => l.id == key.libraryId);
});

final recentlyAddedProvider =
    FutureProvider.family<List<MediaItem>, LibraryRef>((ref, key) async {
  final lib = await ref.watch(libraryProvider(key).future);
  return ref.backend(key.serverId).recentlyAdded(lib);
});

final collectionsProvider =
    FutureProvider.family<List<MediaItem>, String>((ref, serverId) async {
  final b = ref.backend(serverId);
  return b.visible(await b.collections(null));
});

final libraryRecommendedProvider =
    FutureProvider.family<List<Shelf>, LibraryRef>((ref, key) async {
  final lib = await ref.watch(libraryProvider(key).future);
  return ref.backend(key.serverId).recommended(lib);
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
  final b = ref.backend(key.serverId);
  return b.visible(await b.similar(item));
});

final watchlistedProvider =
    FutureProvider.family<bool, ItemRef>((ref, key) async {
  final backend = ref.backend(key.serverId);
  if (!backend.supportsWatchlist) return false;
  final item = await ref.watch(itemProvider(key).future);
  return backend.isWatchlisted(item);
});

/// Asks [serverId] to rescan [library] (all libraries when null), then
/// reloads what's on screen. The scan itself runs on the server, so a second
/// reload follows once it has had time to find new files.
Future<void> scanLibrary(
    ProviderContainer container, String serverId, Library? library) async {
  final backend = container.read(backendsProvider)[serverId];
  if (backend == null) return;
  await backend.scanLibrary(library);
  void reload() {
    container
      ..invalidate(allLibrariesProvider(serverId))
      ..invalidate(recentlyAddedProvider)
      ..invalidate(continueWatchingProvider)
      ..invalidate(nextUpProvider)
      ..invalidate(collectionsProvider(serverId))
      ..invalidate(libraryCollectionsProvider)
      ..invalidate(discoverProvider);
  }

  reload();
  Timer(const Duration(seconds: 20), reload);
}

/// What the Manage menu offers for an item (empty: no menu).
final manageActionsProvider =
    FutureProvider.family<Set<ManageAction>, ItemRef>((ref, key) async {
  final item = await ref.watch(itemProvider(key).future);
  return ref.backend(key.serverId).manageActions(item);
});

/// The user's playlists that [ItemRef] can be added to.
final playlistsForProvider = FutureProvider.autoDispose
    .family<List<MediaItem>, ItemRef>((ref, key) async {
  final item = await ref.watch(itemProvider(key).future);
  return ref.backend(key.serverId).playlistsFor(item);
});

/// Reloads everything that shows [item] after its metadata or artwork
/// changed. Refreshes and matches finish on the server a little later, so
/// [again] reloads once more after that.
void reloadItem(ProviderContainer container, MediaItem item,
    {bool again = false}) {
  void reload() {
    container
      ..invalidate(itemProvider(item.ref))
      ..invalidate(childrenProvider)
      ..invalidate(similarProvider)
      ..invalidate(continueWatchingProvider)
      ..invalidate(nextUpProvider)
      ..invalidate(recentlyAddedProvider)
      ..invalidate(libraryRecommendedProvider)
      ..invalidate(collectionsProvider(item.serverId))
      ..invalidate(discoverProvider)
      ..invalidate(watchlistProvider);
  }

  reload();
  if (again) Timer(const Duration(seconds: 10), reload);
}

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
  final lists = await Future.wait(
      backends.map((b) => _visible(b, b.search(query.trim()))));
  return lists.expand((l) => l).toList();
});

final discoverProvider = FutureProvider<List<Shelf>>((ref) async {
  final backends = ref.watch(backendsProvider).values.toList();
  final lists = await Future.wait(backends.map((b) => _orEmpty(b.discover())));
  final out = <Shelf>[];
  for (var i = 0; i < backends.length; i++) {
    for (final s in lists[i]) {
      final items = backends[i].visible(s.items);
      if (items.isEmpty) continue;
      out.add(Shelf(
        backends.length > 1
            ? '${s.title} · ${backends[i].config.name}'
            : s.title,
        items,
        landscape: s.landscape,
      ));
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
      await Future.wait(backends.map((b) => _visible(b, b.watchlist())));
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
