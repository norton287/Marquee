import 'package:flutter/foundation.dart';

enum ServerKind { plex, jellyfin, demo }

enum MediaKind {
  movie,
  show,
  season,
  episode,
  artist,
  album,
  track,
  collection,
  playlist,
  folder,
  video,
  unknown;

  bool get isVideo => this == movie || this == episode || this == video;
  bool get isAudio => this == track;
  bool get isPlayable => isVideo || isAudio;
  bool get isMusic => this == artist || this == album || this == track;

  String get label => switch (this) {
        movie => 'Movies',
        show => 'Shows',
        season => 'Seasons',
        episode => 'Episodes',
        artist => 'Artists',
        album => 'Albums',
        track => 'Tracks',
        collection => 'Collections',
        playlist => 'Playlists',
        folder => 'Folders',
        video => 'Videos',
        unknown => 'Other',
      };
}

enum LibraryKind { movies, shows, music, other }

/// A lazily sized image. `{w}` and `{h}` in the template are replaced with
/// pixel sizes so each server can do its own resizing.
@immutable
class ImageRef {
  const ImageRef(this.template, {this.headers});
  final String template;
  final Map<String, String>? headers;

  String url(int width, {double aspect = 2 / 3}) {
    // Bucket widths so scrolling grids reuse cache entries.
    final w = ((width / 80).ceil() * 80).clamp(80, 1920);
    return template
        .replaceAll('{w}', '$w')
        .replaceAll('{h}', '${(w / aspect).round()}');
  }
}

@immutable
class ServerConfig {
  const ServerConfig({
    required this.id,
    required this.kind,
    required this.name,
    required this.baseUrl,
    this.token = '',
    this.userId,
    this.userName,
    this.userThumb,
    this.accountToken,
    this.homeToken,
    this.machineId,
    this.connections = const [],
  });

  final String id;
  final ServerKind kind;
  final String name;
  final String baseUrl;
  final String token;
  final String? userId;
  final String? userName;
  final String? userThumb;

  /// Plex only: the active profile's plex.tv token (watchlist lives on plex.tv).
  final String? accountToken;

  /// Plex only: the primary plex.tv account token from sign-in, used to list
  /// and switch Plex Home profiles even when a managed user is active.
  final String? homeToken;
  final String? machineId;

  /// Plex only: every address the server advertises, best first.
  final List<String> connections;

  static const _keep = Object();

  ServerConfig copyWith({
    String? baseUrl,
    String? name,
    String? token,
    String? userId,
    String? userName,
    Object? userThumb = _keep,
    String? accountToken,
    String? homeToken,
    List<String>? connections,
  }) =>
      ServerConfig(
        id: id,
        kind: kind,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        token: token ?? this.token,
        userId: userId ?? this.userId,
        userName: userName ?? this.userName,
        userThumb:
            userThumb == _keep ? this.userThumb : userThumb as String?,
        accountToken: accountToken ?? this.accountToken,
        homeToken: homeToken ?? this.homeToken,
        machineId: machineId,
        connections: connections ?? this.connections,
      );

  /// Public part, safe for plain preferences.
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'baseUrl': baseUrl,
        'userId': userId,
        'userName': userName,
        'userThumb': userThumb,
        'machineId': machineId,
        'connections': connections,
      };

  Map<String, dynamic> secrets() => {
        'token': token,
        'accountToken': accountToken,
        'homeToken': homeToken,
      };

  factory ServerConfig.fromJson(
          Map<String, dynamic> j, Map<String, dynamic> secrets) =>
      ServerConfig(
        id: j['id'] as String,
        kind: ServerKind.values.byName(j['kind'] as String),
        name: j['name'] as String? ?? 'Server',
        baseUrl: j['baseUrl'] as String? ?? '',
        token: secrets['token'] as String? ?? '',
        accountToken: secrets['accountToken'] as String?,
        homeToken: (secrets['homeToken'] ?? secrets['accountToken']) as String?,
        userId: j['userId'] as String?,
        userName: j['userName'] as String?,
        userThumb: j['userThumb'] as String?,
        machineId: j['machineId'] as String?,
        connections:
            (j['connections'] as List?)?.cast<String>() ?? const <String>[],
      );
}

@immutable
class Library {
  const Library({
    required this.serverId,
    required this.id,
    required this.title,
    required this.kind,
    this.art,
  });
  final String serverId;
  final String id;
  final String title;
  final LibraryKind kind;
  final ImageRef? art;
}

enum StreamType { video, audio, subtitle }

@immutable
class MediaStreamInfo {
  const MediaStreamInfo({
    required this.id,
    required this.type,
    required this.title,
    this.codec,
    this.language,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.selected = false,
    this.channels,
    this.url,
  });
  final String id;
  final StreamType type;
  final String title;
  final String? codec;
  final String? language;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;
  final bool selected;
  final int? channels;

  /// Set for sidecar subtitles the player can load directly.
  final String? url;
}

@immutable
class MediaVersion {
  const MediaVersion({
    required this.id,
    this.partId,
    this.partKey,
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.width,
    this.height,
    this.bitrateKbps,
    this.audioChannels,
    this.hdr,
    this.streams = const [],
    this.name,
  });
  final String id;
  final String? partId;
  final String? partKey;
  final String? container;
  final String? videoCodec;
  final String? audioCodec;
  final int? width;
  final int? height;
  final int? bitrateKbps;
  final int? audioChannels;

  /// 'HDR10', 'HLG', 'DV' …
  final String? hdr;
  final List<MediaStreamInfo> streams;
  final String? name;

  List<MediaStreamInfo> get audio =>
      streams.where((s) => s.type == StreamType.audio).toList();
  List<MediaStreamInfo> get subtitles =>
      streams.where((s) => s.type == StreamType.subtitle).toList();

  String? get resolution {
    final w = width ?? 0, h = height ?? 0;
    if (w == 0 && h == 0) return null;
    if (w >= 3800 || h >= 2000) return '4K';
    if (w >= 1900 || h >= 1000) return '1080p';
    if (w >= 1260 || h >= 700) return '720p';
    return 'SD';
  }

  String? get audioLayout => switch (audioChannels) {
        null => null,
        1 => 'Mono',
        2 => 'Stereo',
        6 => '5.1',
        8 => '7.1',
        final n => '$n ch',
      };

  String get label => [
        ?name,
        ?resolution,
        ?hdr,
        ?videoCodec?.toUpperCase(),
        if (bitrateKbps != null)
          '${(bitrateKbps! / 1000).toStringAsFixed(1)} Mbps',
      ].join(' · ');
}

@immutable
class Chapter {
  const Chapter({required this.title, required this.start, this.thumb});
  final String title;
  final Duration start;
  final ImageRef? thumb;
}

enum MarkerType { intro, credits }

@immutable
class Marker {
  const Marker({required this.type, required this.start, required this.end});
  final MarkerType type;
  final Duration start;
  final Duration end;
}

@immutable
class Person {
  const Person({required this.name, this.role, this.image});
  final String name;
  final String? role;
  final ImageRef? image;
}

typedef ItemRef = ({String serverId, String id, MediaKind kind});

@immutable
class MediaItem {
  const MediaItem({
    required this.serverId,
    required this.id,
    required this.kind,
    required this.title,
    this.overview,
    this.tagline,
    this.year,
    this.duration,
    this.viewOffset = Duration.zero,
    this.played = false,
    this.unplayedCount,
    this.childCount,
    this.poster,
    this.thumb,
    this.backdrop,
    this.parentId,
    this.grandparentId,
    this.parentTitle,
    this.grandparentTitle,
    this.index,
    this.parentIndex,
    this.contentRating,
    this.rating,
    this.genres = const [],
    this.people = const [],
    this.studio,
    this.addedAt,
    this.lastViewedAt,
    this.versions = const [],
    this.chapters = const [],
    this.markers = const [],
    this.isFavorite = false,
    this.externalIds = const {},
    this.external = false,
    this.libraryId,
  });

  final String serverId;
  final String id;
  final MediaKind kind;
  final String title;
  final String? overview;
  final String? tagline;
  final int? year;
  final Duration? duration;
  final Duration viewOffset;
  final bool played;
  final int? unplayedCount;
  final int? childCount;

  /// Portrait (or square for music) artwork.
  final ImageRef? poster;

  /// Landscape still, used for episodes and continue watching.
  final ImageRef? thumb;
  final ImageRef? backdrop;

  /// Season for an episode, show for a season, album for a track.
  final String? parentId;

  /// Show for an episode, artist for a track.
  final String? grandparentId;
  final String? parentTitle;
  final String? grandparentTitle;
  final int? index;
  final int? parentIndex;
  final String? contentRating;

  /// 0–10.
  final double? rating;
  final List<String> genres;
  final List<Person> people;
  final String? studio;
  final DateTime? addedAt;
  final DateTime? lastViewedAt;
  final List<MediaVersion> versions;
  final List<Chapter> chapters;
  final List<Marker> markers;
  final bool isFavorite;

  /// 'tmdb', 'imdb', 'plex' …
  final Map<String, String> externalIds;

  /// True for items that are not on the server (e.g. Plex watchlist entries).
  final bool external;

  /// The library the item lives in, where the server says so (Plex). Used to
  /// keep hidden libraries out of merged shelves and search.
  final String? libraryId;

  ItemRef get ref => (serverId: serverId, id: id, kind: kind);

  double get progress {
    final d = duration?.inMilliseconds ?? 0;
    if (d <= 0) return 0;
    return (viewOffset.inMilliseconds / d).clamp(0.0, 1.0);
  }

  bool get inProgress => viewOffset > const Duration(seconds: 5) && !played;

  String? get episodeCode {
    if (kind != MediaKind.episode) return null;
    final s = parentIndex, e = index;
    if (s == null && e == null) return null;
    return '${s != null ? 'S$s' : ''}${s != null && e != null ? ' · ' : ''}${e != null ? 'E$e' : ''}';
  }

  /// Title for a card when the item is shown out of context (home shelves).
  String get cardTitle => switch (kind) {
        MediaKind.episode => grandparentTitle ?? title,
        _ => title,
      };

  String? get cardSubtitle => switch (kind) {
        MediaKind.episode =>
          [?episodeCode, title].join(' — '),
        MediaKind.season => grandparentTitle ?? parentTitle,
        MediaKind.album => parentTitle ?? year?.toString(),
        MediaKind.track => grandparentTitle ?? parentTitle,
        MediaKind.collection || MediaKind.playlist =>
          childCount != null ? '$childCount items' : null,
        MediaKind.folder => null,
        _ => year?.toString(),
      };

  bool get squareArt =>
      kind.isMusic || kind == MediaKind.playlist || kind == MediaKind.folder;

  MediaItem copyWith({
    Duration? viewOffset,
    bool? played,
    bool? isFavorite,
    List<Marker>? markers,
    List<MediaVersion>? versions,
  }) =>
      MediaItem(
        serverId: serverId,
        id: id,
        kind: kind,
        title: title,
        overview: overview,
        tagline: tagline,
        year: year,
        duration: duration,
        viewOffset: viewOffset ?? this.viewOffset,
        played: played ?? this.played,
        unplayedCount: unplayedCount,
        childCount: childCount,
        poster: poster,
        thumb: thumb,
        backdrop: backdrop,
        parentId: parentId,
        grandparentId: grandparentId,
        parentTitle: parentTitle,
        grandparentTitle: grandparentTitle,
        index: index,
        parentIndex: parentIndex,
        contentRating: contentRating,
        rating: rating,
        genres: genres,
        people: people,
        studio: studio,
        addedAt: addedAt,
        lastViewedAt: lastViewedAt,
        versions: versions ?? this.versions,
        chapters: chapters,
        markers: markers ?? this.markers,
        isFavorite: isFavorite ?? this.isFavorite,
        externalIds: externalIds,
        external: external,
        libraryId: libraryId,
      );
}

@immutable
class Shelf {
  const Shelf(this.title, this.items, {this.landscape = false});
  final String title;
  final List<MediaItem> items;
  final bool landscape;
}

@immutable
class Paged {
  const Paged(this.items, this.total);
  final List<MediaItem> items;
  final int total;
}

enum SortField {
  title('Title'),
  added('Date added'),
  released('Release date'),
  rating('Rating');

  const SortField(this.label);
  final String label;
}

/// What a library grid is showing.
enum LibraryView { items, albums, artists }

@immutable
class LibraryQuery {
  const LibraryQuery({
    this.sort = SortField.title,
    this.descending = false,
    this.unwatchedOnly = false,
    this.view = LibraryView.items,
  });
  final SortField sort;
  final bool descending;
  final bool unwatchedOnly;
  final LibraryView view;

  LibraryQuery copyWith({
    SortField? sort,
    bool? descending,
    bool? unwatchedOnly,
    LibraryView? view,
  }) =>
      LibraryQuery(
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
        unwatchedOnly: unwatchedOnly ?? this.unwatchedOnly,
        view: view ?? this.view,
      );

  @override
  bool operator ==(Object other) =>
      other is LibraryQuery &&
      other.sort == sort &&
      other.descending == descending &&
      other.unwatchedOnly == unwatchedOnly &&
      other.view == view;

  @override
  int get hashCode => Object.hash(sort, descending, unwatchedOnly, view);
}

enum PlayMethod {
  directPlay('Direct play'),
  directStream('Direct stream'),
  transcode('Transcoding');

  const PlayMethod(this.label);
  final String label;
}

@immutable
class PlaybackRequest {
  const PlaybackRequest({
    this.versionId,
    this.maxBitrateKbps,
    this.audioStreamId,
    this.subtitleStreamId,
  });
  final String? versionId;

  /// null = original quality (direct play when possible).
  final int? maxBitrateKbps;
  final String? audioStreamId;

  /// '' = subtitles off.
  final String? subtitleStreamId;
}

@immutable
class PlaybackSource {
  const PlaybackSource({
    required this.url,
    required this.method,
    required this.sessionId,
    this.headers = const {},
    this.version,
    this.mediaSourceId,
    this.audioStreams = const [],
    this.subtitleStreams = const [],
  });
  final String url;
  final Map<String, String> headers;
  final PlayMethod method;
  final String sessionId;
  final MediaVersion? version;
  final String? mediaSourceId;

  /// Server side stream lists; used for track switching while transcoding
  /// and for loading sidecar subtitles.
  final List<MediaStreamInfo> audioStreams;
  final List<MediaStreamInfo> subtitleStreams;
}

enum PlayState { started, playing, paused, stopped }

@immutable
class QualityOption {
  const QualityOption(this.label, this.kbps);
  final String label;
  final int? kbps;

  static const all = [
    QualityOption('Original', null),
    QualityOption('4K · 40 Mbps', 40000),
    QualityOption('1080p · 20 Mbps', 20000),
    QualityOption('1080p · 12 Mbps', 12000),
    QualityOption('1080p · 8 Mbps', 8000),
    QualityOption('720p · 4 Mbps', 4000),
    QualityOption('720p · 2 Mbps', 2000),
    QualityOption('480p · 1.5 Mbps', 1500),
    QualityOption('360p · 0.7 Mbps', 700),
  ];

  static QualityOption of(int? kbps) =>
      all.firstWhere((q) => q.kbps == kbps, orElse: () => all.first);
}

const _languageAliases = {
  'eng': ['en', 'eng'],
  'spa': ['es', 'spa'],
  'fra': ['fr', 'fra', 'fre'],
  'deu': ['de', 'deu', 'ger'],
  'ita': ['it', 'ita'],
  'por': ['pt', 'por'],
  'nld': ['nl', 'nld', 'dut'],
  'jpn': ['ja', 'jpn'],
  'kor': ['ko', 'kor'],
  'zho': ['zh', 'zho', 'chi'],
  'hin': ['hi', 'hin'],
  'ara': ['ar', 'ara'],
  'rus': ['ru', 'rus'],
};

/// Files tag languages as 'en', 'eng', 'en-US' … so compare loosely.
bool languageMatches(String preferred, String? actual) {
  if (actual == null || actual.isEmpty) return false;
  final code = actual.toLowerCase().split(RegExp('[-_]')).first;
  return (_languageAliases[preferred] ?? [preferred]).contains(code);
}

int? asInt(Object? v) => switch (v) {
      final int i => i,
      final num n => n.toInt(),
      final String s => int.tryParse(s) ?? double.tryParse(s)?.toInt(),
      _ => null,
    };

double? asDouble(Object? v) => switch (v) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
    };

bool asBool(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

// ---------------------------------------------------------------------------
// Managing items (refresh, match, artwork)
// ---------------------------------------------------------------------------

/// What the Manage menu on a details page can do for an item.
enum ManageAction {
  edit('Edit details…'),
  refresh('Refresh metadata'),
  analyze('Analyze'),
  match('Fix match…'),
  unmatch('Unmatch'),
  poster('Change poster…'),
  upload('Upload poster…'),
  background('Change background…'),
  uploadBackground('Upload background…');

  const ManageAction(this.label);
  final String label;
}

enum ArtworkKind {
  poster('Poster'),
  background('Background');

  const ArtworkKind(this.label);
  final String label;
}

/// One result of a "fix match" search.
@immutable
class MatchCandidate {
  const MatchCandidate({
    required this.id,
    required this.title,
    this.year,
    this.score,
    this.image,
    this.source,
    this.overview,
    this.raw = const {},
  });

  /// Plex: the agent guid. Jellyfin: a provider id such as "tmdb:603".
  final String id;
  final String title;
  final int? year;

  /// 0–100 where the server ranks results (Plex).
  final int? score;
  final ImageRef? image;

  /// Where the result came from, e.g. "TheMovieDb".
  final String? source;
  final String? overview;

  /// The server's own record, sent back as-is when applying (Jellyfin).
  final Map<String, dynamic> raw;
}

/// One choice when changing a poster or background.
@immutable
class ArtworkOption {
  const ArtworkOption({
    required this.id,
    required this.image,
    this.selected = false,
    this.source,
    this.width,
    this.height,
  });

  /// Plex: the image key to select. Jellyfin: the remote image URL.
  final String id;
  final ImageRef image;

  /// The one in use now (Plex says; Jellyfin doesn't).
  final bool selected;
  final String? source;
  final int? width;
  final int? height;
}
