import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'models.dart';
import 'network.dart';

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
/// The server couldn't be reached (as opposed to refusing or not having
/// something): worth re-probing its addresses and trying again.
bool isConnectionError(Object e) =>
    e is DioException &&
    const {
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.unknown,
    }.contains(e.type);

/// What a car A–Z folder lists.
enum MusicList { artists, albums, tracks }

abstract class MediaBackend {
  ServerConfig get config;
  String get serverId => config.id;

  /// Reached on the home network (decides home vs away streaming quality).
  bool get isLocal => isLocalAddress(config.baseUrl);

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

  /// Up to [limit] random tracks from a music [library] ("Shuffle all" in the
  /// car), picked by the server.
  Future<List<MediaItem>> randomTracks(Library library, {int limit = 200}) async =>
      const [];

  /// A music [library]'s artists, albums or tracks under [letter] ('A'–'Z',
  /// or '#' for anything else), by title, at most [limit] (car A–Z folders).
  Future<List<MediaItem>> musicStartingWith(
          Library library, MusicList kind, String letter,
          {int limit = 500}) async =>
      const [];

  /// A music [library]'s newest tracks (car: Tracks → Recently added).
  Future<List<MediaItem>> recentTracks(Library library, {int limit = 200}) async =>
      const [];

  /// The tracks played most, played ones only (car: Tracks → Most played).
  Future<List<MediaItem>> topTracks(Library library, {int limit = 200}) async =>
      const [];

  /// Whether [title] belongs in the car's [letter] folder: by its first
  /// letter, or for "The …" by the next word ("The Beatles" under B, not T);
  /// '#' holds everything not starting with A–Z.
  static bool underLetter(String title, String letter) {
    var t = title.trim().toUpperCase();
    if (t.startsWith('THE ') && t.length > 4) t = t.substring(4).trimLeft();
    final c = t.isEmpty ? '' : t[0];
    final az = c.length == 1 && c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90;
    return letter == '#' ? !az : c == letter;
  }

  /// A music [library]'s albums for the car's Recent tab: recently played
  /// first, then recently added, each once.
  Future<List<MediaItem>> recentMusic(Library library, {int limit = 20}) =>
      recentlyAdded(library, limit: limit);

  /// [first] then [rest], each id once, at most [limit].
  static List<MediaItem> mergeUnique(
      List<MediaItem> first, List<MediaItem> rest, int limit) {
    final seen = <String>{};
    return [
      for (final i in [...first, ...rest])
        if (seen.add(i.id)) i,
    ].take(limit).toList();
  }
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

  /// The ways [library]'s All view can be filtered; [LibraryQuery.filters]
  /// keys are their ids. Empty = no Filter button.
  Future<List<FilterCategory>> filterCategories(Library library) async =>
      const [];

  /// The choices in [category] (for a searchable one, those matching
  /// [search]; the server may need it to list anything).
  Future<List<FilterValue>> filterValues(
          Library library, FilterCategory category,
          {String? search}) async =>
      const [];

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

  // -- managing items (server owner / administrator) ---------------------------

  /// What the Manage menu offers for [item]; empty hides the menu. Servers
  /// that can tell the user isn't allowed to manage return empty up front.
  Future<Set<ManageAction>> manageActions(MediaItem item) async => const {};

  /// Change [item]'s title and summary, and (movies and shows) its sort
  /// title, year and genres; null leaves a field alone. Changed fields are
  /// locked afterwards where the server can, as in Plex's own editor, so a
  /// later metadata refresh keeps them.
  Future<void> editDetails(MediaItem item,
      {required String title,
      required String summary,
      String? sortTitle,
      int? year,
      List<String>? genres}) async {}

  /// Re-fetch [item]'s metadata from the server's agents. Returns once the
  /// server has accepted the request; the refresh itself runs in the
  /// background.
  Future<void> refreshMetadata(MediaItem item) async {}

  /// Re-read the file's media info (Plex).
  Future<void> analyze(MediaItem item) async {}

  /// Search the metadata agents for what [item] really is.
  Future<List<MatchCandidate>> searchMatches(MediaItem item,
          {required String title, int? year}) async =>
      const [];

  Future<void> applyMatch(MediaItem item, MatchCandidate match) async {}

  Future<void> unmatch(MediaItem item) async {}

  /// Images the server can use as [item]'s poster or background.
  Future<List<ArtworkOption>> artwork(MediaItem item, ArtworkKind kind) async =>
      const [];

  Future<void> setArtwork(
      MediaItem item, ArtworkKind kind, ArtworkOption option) async {}

  // -- playlists (any user) ----------------------------------------------------

  /// Whether [item] can go into a playlist on this server.
  bool canAddToPlaylist(MediaItem item) => false;

  /// The user's playlists that can take [item] (same media type, not smart).
  Future<List<MediaItem>> playlistsFor(MediaItem item) async => const [];

  Future<void> addToPlaylist(MediaItem playlist, MediaItem item) async {}

  /// A playlist's tracks, at most [limit] (a smart playlist can match a whole
  /// library). Default: [children], trimmed.
  Future<List<MediaItem>> playlistTracks(MediaItem playlist, {int? limit}) async {
    final all = await children(playlist);
    return limit == null ? all : all.take(limit).toList();
  }

  /// Every music playlist to play from (the car's Playlists tab), including
  /// ones that can't be added to by hand such as Plex smart playlists.
  /// Default: those a track could be added to.
  Future<List<MediaItem>> musicPlaylists() => playlistsFor(
      MediaItem(serverId: '', id: '', kind: MediaKind.track, title: ''));

  /// [item]'s entries in [playlist] (several if it was added more than once),
  /// each with its [MediaItem.playlistEntryId] for [removeFromPlaylist].
  /// Neither server can ask "which playlists hold this?", so this reads the
  /// playlist's contents.
  Future<List<MediaItem>> playlistEntriesOf(
          MediaItem playlist, MediaItem item) async =>
      [for (final e in await children(playlist)) if (e.id == item.id) e];

  /// Creates a playlist called [title] holding [item].
  Future<void> createPlaylist(String title, MediaItem item) async {}

  /// Use an image of your own as [item]'s poster or background: either the
  /// file's [bytes] (with its [mimeType]) or a [url] the server downloads.
  /// The upload becomes the selected image.
  Future<void> uploadArtwork(MediaItem item, ArtworkKind kind,
      {Uint8List? bytes, String? mimeType, String? url}) async {}

  /// Permanently deletes [item]'s files from the server's disk. Only offered
  /// (via [manageActions]) where the server allows deletion.
  Future<void> deleteItem(MediaItem item) async {}

  /// The versions of [item] that can be deleted one by one: all of them
  /// when there are several. Offered under the same rule as [deleteItem].
  List<MediaVersion> deletableVersions(MediaItem item) =>
      item.versions.length > 1 ? item.versions : const [];

  /// Permanently deletes one version's file(s); the item and its other
  /// versions stay.
  Future<void> deleteVersion(MediaItem item, MediaVersion version) =>
      throw UnsupportedError('This server can\'t delete single versions.');

  /// Deletes a playlist (not the media in it). Users may delete their own
  /// playlists, so this needs no owner or administrator rights.
  Future<void> deletePlaylist(MediaItem playlist) async {}

  /// Takes one entry ([MediaItem.playlistEntryId], from [children] of the
  /// playlist or [playlistEntriesOf]) out of [playlist]. The media stays. Any user, own playlists.
  Future<void> removeFromPlaylist(MediaItem playlist, MediaItem entry) =>
      throw UnsupportedError('This server can\'t remove playlist items.');

  /// Manage actions every server offers on a playlist: removing needs a
  /// hand-made playlist with something in it.
  static Set<ManageAction> playlistActions(MediaItem playlist) =>
      playlist.smart || playlist.childCount == 0
          ? const {ManageAction.deletePlaylist}
          : const {ManageAction.removeFromPlaylist, ManageAction.deletePlaylist};

  /// The entry id to remove, or a user-ready error.
  static String entryIdOf(MediaItem entry) =>
      entry.playlistEntryId ??
      (throw StateError("Can't remove this item from the playlist."));

  void dispose() {}
}
