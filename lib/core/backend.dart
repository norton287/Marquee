import 'models.dart';

/// Identity this app presents to servers. Filled in once at startup.
class ClientInfo {
  static const product = 'Marquee';
  static const version = '1.0.0';
  static String clientId = 'marquee-dev';
  static String deviceName = 'Marquee';
  static String platform = 'Flutter';

  static Map<String, String> get plexHeaders => {
        'Accept': 'application/json',
        'X-Plex-Client-Identifier': clientId,
        'X-Plex-Product': product,
        'X-Plex-Version': version,
        'X-Plex-Platform': platform,
        'X-Plex-Device': platform,
        'X-Plex-Device-Name': deviceName,
      };

  /// Jellyfin's `MediaBrowser` scheme. The legacy X-Emby-* headers and the
  /// `api_key` query parameter are going away, so this is the only form used.
  static String jellyfinAuth([String? token]) {
    String q(String v) => Uri.encodeComponent(v);
    return 'MediaBrowser Client="${q(product)}", Device="${q(deviceName)}", '
        'DeviceId="${q(clientId)}", Version="$version"'
        '${token != null && token.isNotEmpty ? ', Token="$token"' : ''}';
  }
}

/// A failure whose [message] is already worded for the user.
class BackendException implements Exception {
  const BackendException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Everything the UI needs from a media server. Plex and Jellyfin each
/// implement this, so no screen ever knows which one it is talking to.
abstract class MediaBackend {
  ServerConfig get config;
  String get serverId => config.id;

  /// Libraries the user hid in Settings. Set once when the backend is created;
  /// toggling a library creates fresh backends, so this never changes under
  /// a running query.
  Set<String> hiddenLibraries = const {};

  /// Drops items that belong to a hidden library. Items whose library isn't
  /// known pass through; backends that can't tag items scope their queries
  /// instead (Jellyfin).
  List<MediaItem> visible(List<MediaItem> items) => hiddenLibraries.isEmpty
      ? items
      : items
          .where((i) =>
              i.libraryId == null || !hiddenLibraries.contains(i.libraryId))
          .toList();

  /// Whether [scanLibrary] does anything on this server.
  bool get canScanLibraries => false;

  /// Asks the server to rescan [library] (or every library when null) for
  /// new and changed files. Returns once the scan has been started; the
  /// server finishes it in the background.
  Future<void> scanLibrary(Library? library) async {}

  Future<List<Library>> libraries();
  Future<List<MediaItem>> continueWatching();

  /// Next unwatched episodes. Empty where the server folds these into
  /// [continueWatching] (Plex).
  Future<List<MediaItem>> nextUp();
  Future<List<MediaItem>> recentlyAdded(Library library, {int limit = 20});
  Future<Paged> libraryItems(
    Library library, {
    int start = 0,
    int limit = 60,
    LibraryQuery query = const LibraryQuery(),
  });
  Future<List<MediaItem>> collections(Library? library);
  Future<List<MediaItem>> playlists();
  Future<List<MediaItem>> folders(Library library);

  /// Seasons, episodes, albums, tracks, collection/playlist/folder contents.
  Future<List<MediaItem>> children(MediaItem parent);
  Future<MediaItem> item(String id, {MediaKind? kind});
  Future<List<MediaItem>> similar(MediaItem item);
  Future<List<Shelf>> discover();

  /// The Recommended tab of one movie or TV library: rows such as continue
  /// watching, recently added and "because you watched". The default is just
  /// the library's recently added row.
  Future<List<Shelf>> recommended(Library library) async =>
      [Shelf('Recently added', await recentlyAdded(library))];

  Future<List<MediaItem>> search(String query);
  Future<MediaItem?> nextEpisode(MediaItem episode);
  Future<List<Marker>> markers(MediaItem item);

  Future<PlaybackSource> playback(MediaItem item, PlaybackRequest request);
  Future<void> reportProgress(
    MediaItem item,
    PlaybackSource source,
    Duration position,
    PlayState state,
  );
  Future<void> setPlayed(MediaItem item, bool played);

  /// Plex: the plex.tv watchlist. Jellyfin: favorites.
  bool get supportsWatchlist;
  String get watchlistName;
  Future<List<MediaItem>> watchlist();
  Future<bool> isWatchlisted(MediaItem item);
  Future<void> setWatchlisted(MediaItem item, bool value);

  void dispose() {}
}
