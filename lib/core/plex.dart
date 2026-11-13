import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'backend.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// plex.tv account: PIN sign-in and server discovery
// ---------------------------------------------------------------------------

class PlexPin {
  const PlexPin(this.id, this.code, {required this.strong});
  final int id;
  final String code;
  final bool strong;

  /// Page the user signs in on (phones/desktops open it in a browser).
  String get authUrl => 'https://app.plex.tv/auth#?'
      'clientID=${Uri.encodeQueryComponent(ClientInfo.clientId)}'
      '&code=$code'
      '&context%5Bdevice%5D%5Bproduct%5D=${ClientInfo.product}';
}

class PlexResource {
  const PlexResource({
    required this.name,
    required this.machineId,
    required this.accessToken,
    required this.connections,
    required this.owned,
  });
  final String name;
  final String machineId;
  final String accessToken;
  final bool owned;

  /// Ordered: local, then remote, then relay.
  final List<String> connections;
}

class PlexHomeUser {
  const PlexHomeUser({
    required this.uuid,
    required this.name,
    this.thumb,
    this.admin = false,
    this.restricted = false,
    this.guest = false,
    this.protected = false,
  });

  final String uuid;
  final String name;
  final String? thumb;
  final bool admin;
  final bool restricted;
  final bool guest;
  final bool protected;

  String get subtitle {
    if (admin) return 'Admin';
    if (guest) return 'Guest';
    if (restricted) return 'Managed profile';
    return 'Home user';
  }

  static PlexHomeUser parse(Map<String, dynamic> m) {
    final name = [m['title'], m['friendlyName'], m['username']]
        .whereType<String>()
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => 'Plex user');
    final thumb = m['thumb'] as String?;
    return PlexHomeUser(
      uuid: '${m['uuid'] ?? m['id'] ?? ''}',
      name: name,
      thumb: (thumb == null || thumb.isEmpty) ? null : thumb,
      admin: asBool(m['admin']),
      restricted: asBool(m['restricted']),
      guest: asBool(m['guest']),
      protected: asBool(m['protected']),
    );
  }
}

class PlexAccount {
  static Dio _tv([String? token]) => Dio(BaseOptions(
        baseUrl: 'https://plex.tv/api/v2',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          ...ClientInfo.plexHeaders,
          'X-Plex-Token': ?token,
        },
      ));

  /// [strong] pins are long codes carried in a URL. Non-strong pins are the
  /// four character codes typed in at plex.tv/link, which is what a TV wants.
  static Future<PlexPin> createPin({required bool strong}) async {
    final r = await _tv().post<Map<String, dynamic>>('/pins',
        queryParameters: {'strong': strong});
    return PlexPin(asInt(r.data!['id'])!, r.data!['code'] as String,
        strong: strong);
  }

  /// Returns the account token once the user has approved the pin.
  static Future<String?> checkPin(PlexPin pin) async {
    final r = await _tv().get<Map<String, dynamic>>('/pins/${pin.id}');
    final t = r.data?['authToken'] as String?;
    return (t == null || t.isEmpty) ? null : t;
  }

  static Future<PlexHomeUser> currentUser(String token) async {
    final r = await _tv(token).get<Map<String, dynamic>>('/user');
    return PlexHomeUser.parse(r.data ?? const {});
  }

  static Future<String> userName(String token) async =>
      (await currentUser(token)).name;

  /// Lists all users in the Plex Home. Falls back to the signed-in account
  /// if the account is not in a Plex Home.
  static Future<List<PlexHomeUser>> homeUsers(String token) async {
    try {
      final r = await _tv(token).get<Map<String, dynamic>>('/home/users');
      final raw = (r.data?['users'] as List?) ?? const [];
      final users = [
        for (final u in raw.whereType<Map<String, dynamic>>())
          PlexHomeUser.parse(u),
      ];
      if (users.isNotEmpty) return users;
    } catch (_) {
      // Fall back to /user below if /home/users is unavailable.
    }
    return [await currentUser(token)];
  }

  /// Exchanges a Plex Home account token for a specific Home user's token.
  static Future<String> switchHomeUser(
    String homeToken,
    String uuid, {
    String? pin,
  }) async {
    try {
      final r = await _tv(homeToken).post<Map<String, dynamic>>(
        '/home/users/$uuid/switch',
        queryParameters: {
          if (pin != null && pin.isNotEmpty) 'pin': pin,
        },
      );
      final token = r.data?['authToken'] as String?;
      if (token == null || token.isEmpty) {
        throw const BackendException('Plex did not return a profile token.');
      }
      return token;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403 || code == 422) {
        // Only blame the PIN when one was sent; otherwise the account token
        // itself was refused (revoked or expired).
        throw BackendException(pin != null && pin.isNotEmpty
            ? 'That PIN wasn\'t right.'
            : 'Plex refused this sign-in. Remove the server in Settings and '
                'sign in again.');
      }
      rethrow;
    }
  }

  static Future<List<PlexResource>> servers(String token) async {
    final r = await _tv(token).get<List<dynamic>>('/resources',
        queryParameters: {
          'includeHttps': 1,
          'includeRelay': 1,
          'includeIPv6': 1
        });
    final out = <PlexResource>[];
    for (final raw in r.data ?? const []) {
      final d = raw as Map<String, dynamic>;
      if (!('${d['provides']}'.split(',').contains('server'))) continue;
      final conns = ((d['connections'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) => _rank(a).compareTo(_rank(b)));
      out.add(PlexResource(
        name: d['name'] as String? ?? 'Plex server',
        machineId: d['clientIdentifier'] as String? ?? '',
        accessToken: d['accessToken'] as String? ?? token,
        owned: asBool(d['owned']),
        connections: [for (final c in conns) c['uri'] as String],
      ));
    }
    return out;
  }

  static int _rank(Map<String, dynamic> c) =>
      asBool(c['relay']) ? 2 : (asBool(c['local']) ? 0 : 1);

  /// Probes every address at once and returns the best one that answers.
  static Future<String?> bestConnection(
      List<String> uris, String token) async {
    if (uris.isEmpty) return null;
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
      headers: {...ClientInfo.plexHeaders, 'X-Plex-Token': token},
    ));
    final ok = await Future.wait(uris.map((u) async {
      try {
        await dio.get<dynamic>('$u/identity');
        return true;
      } catch (_) {
        return false;
      }
    }));
    dio.close();
    for (var i = 0; i < uris.length; i++) {
      if (ok[i]) return uris[i];
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Plex Media Server
// ---------------------------------------------------------------------------

class PlexBackend extends MediaBackend {
  PlexBackend(this.config, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: config.baseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 25),
              headers: {
                ...ClientInfo.plexHeaders,
                'X-Plex-Token': config.token,
              },
            ));

  @override
  final ServerConfig config;
  final Dio _dio;
  Dio? _discoverDio;

  String get _base => config.baseUrl;
  String get _token => config.token;

  Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic>? query]) async {
    final r = await _dio.get<Map<String, dynamic>>(path,
        queryParameters: query);
    return (r.data?['MediaContainer'] as Map<String, dynamic>?) ?? const {};
  }

  List<MediaItem> _items(Map<String, dynamic> c) => [
        for (final m in (c['Metadata'] as List?) ?? const [])
          parse(m as Map<String, dynamic>),
      ];

  ImageRef? _img(Object? path) {
    if (path is! String || path.isEmpty) return null;
    if (path.startsWith('http')) return ImageRef(path);
    return ImageRef('$_base/photo/:/transcode?width={w}&height={h}'
        '&minSize=1&upscale=1&url=${Uri.encodeQueryComponent(path)}'
        '&X-Plex-Token=$_token');
  }

  static MediaKind _kind(String? type) => switch (type) {
        'movie' => MediaKind.movie,
        'show' => MediaKind.show,
        'season' => MediaKind.season,
        'episode' => MediaKind.episode,
        'artist' => MediaKind.artist,
        'album' => MediaKind.album,
        'track' => MediaKind.track,
        'collection' => MediaKind.collection,
        'playlist' => MediaKind.playlist,
        'clip' => MediaKind.video,
        _ => MediaKind.unknown,
      };

  MediaItem parse(Map<String, dynamic> m) {
    final ratingKey = m['ratingKey']?.toString();
    if (ratingKey == null) {
      // Folder rows only carry a browse path.
      return MediaItem(
        serverId: serverId,
        id: '${m['key']}',
        kind: MediaKind.folder,
        title: '${m['title'] ?? 'Folder'}',
      );
    }
    final kind = _kind(m['type'] as String?);
    final leaf = asInt(m['leafCount']);
    final viewedLeaf = asInt(m['viewedLeafCount']) ?? 0;
    final isLeaf = kind.isPlayable;
    final ids = <String, String>{};
    final guid = m['guid'] as String?;
    if (guid != null && guid.startsWith('plex://')) ids['plex'] = guid;
    for (final g in (m['Guid'] as List?) ?? const []) {
      final id = '${(g as Map)['id']}';
      final sep = id.indexOf('://');
      if (sep > 0) ids[id.substring(0, sep)] = id.substring(sep + 3);
    }

    ImageRef? poster, thumb;
    switch (kind) {
      case MediaKind.episode:
        poster = _img(m['grandparentThumb'] ?? m['parentThumb'] ?? m['thumb']);
        thumb = _img(m['thumb'] ?? m['art']);
      case MediaKind.track:
        poster = _img(m['thumb'] ?? m['parentThumb'] ?? m['grandparentThumb']);
      case MediaKind.playlist:
        poster = _img(m['composite'] ?? m['thumb']);
      default:
        poster = _img(m['thumb'] ?? m['parentThumb']);
        thumb = _img(m['art']);
    }

    DateTime? ts(Object? v) {
      final s = asInt(v);
      return s == null ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000);
    }

    final rating = asDouble(m['audienceRating']) ?? asDouble(m['rating']);
    return MediaItem(
      serverId: serverId,
      id: ratingKey,
      kind: kind,
      title: '${m['title'] ?? ''}',
      overview: m['summary'] as String?,
      tagline: m['tagline'] as String?,
      year: asInt(m['year']) ?? asInt(m['parentYear']),
      duration: asInt(m['duration']) == null
          ? null
          : Duration(milliseconds: asInt(m['duration'])!),
      viewOffset: Duration(milliseconds: asInt(m['viewOffset']) ?? 0),
      played: isLeaf
          ? (asInt(m['viewCount']) ?? 0) > 0
          : (leaf != null && leaf > 0 && viewedLeaf >= leaf),
      unplayedCount: leaf == null ? null : (leaf - viewedLeaf),
      childCount: asInt(m['childCount']) ?? leaf,
      poster: poster,
      thumb: thumb,
      backdrop: _img(m['art'] ?? m['grandparentArt']),
      parentId: m['parentRatingKey']?.toString(),
      grandparentId: m['grandparentRatingKey']?.toString(),
      parentTitle: m['parentTitle'] as String?,
      grandparentTitle: m['grandparentTitle'] as String?,
      index: asInt(m['index']),
      parentIndex: asInt(m['parentIndex']),
      contentRating: m['contentRating'] as String?,
      rating: rating,
      genres: [
        for (final g in (m['Genre'] as List?) ?? const [])
          '${(g as Map)['tag']}'
      ],
      people: [
        for (final d in (m['Director'] as List?) ?? const [])
          Person(name: '${(d as Map)['tag']}', role: 'Director'),
        for (final r in (m['Role'] as List?) ?? const [])
          Person(
            name: '${(r as Map)['tag']}',
            role: r['role'] as String?,
            image: _img(r['thumb']),
          ),
      ],
      studio: m['studio'] as String?,
      addedAt: ts(m['addedAt']),
      lastViewedAt: ts(m['lastViewedAt']),
      versions: [
        for (final media in (m['Media'] as List?) ?? const [])
          _version(media as Map<String, dynamic>),
      ],
      chapters: [
        for (final c in (m['Chapter'] as List?) ?? const [])
          Chapter(
            title: ((c as Map)['tag'] as String?)?.isNotEmpty == true
                ? c['tag'] as String
                : 'Chapter ${asInt(c['index']) ?? ''}',
            start: Duration(milliseconds: asInt(c['startTimeOffset']) ?? 0),
            thumb: _img(c['thumb']),
          ),
      ],
      markers: [
        for (final k in (m['Marker'] as List?) ?? const [])
          if ((k as Map)['type'] == 'intro' || k['type'] == 'credits')
            Marker(
              type: k['type'] == 'intro'
                  ? MarkerType.intro
                  : MarkerType.credits,
              start: Duration(milliseconds: asInt(k['startTimeOffset']) ?? 0),
              end: Duration(milliseconds: asInt(k['endTimeOffset']) ?? 0),
            ),
      ],
      externalIds: ids,
      libraryId: m['librarySectionID']?.toString(),
    );
  }

  MediaVersion _version(Map<String, dynamic> media) {
    final parts = (media['Part'] as List?) ?? const [];
    final part =
        parts.isEmpty ? const <String, dynamic>{} : parts.first as Map;
    String? hdr;
    final streams = <MediaStreamInfo>[];
    for (final raw in (part['Stream'] as List?) ?? const []) {
      final s = raw as Map;
      final type = switch (asInt(s['streamType'])) {
        1 => StreamType.video,
        2 => StreamType.audio,
        3 => StreamType.subtitle,
        _ => null,
      };
      if (type == null) continue;
      if (type == StreamType.video) {
        if (asBool(s['DOVIPresent'])) {
          hdr = 'DV';
        } else if (s['colorTrc'] == 'smpte2084') {
          hdr = 'HDR10';
        } else if (s['colorTrc'] == 'arib-std-b67') {
          hdr = 'HLG';
        }
      }
      final key = s['key'] as String?;
      streams.add(MediaStreamInfo(
        id: '${s['id']}',
        type: type,
        title:
            '${s['extendedDisplayTitle'] ?? s['displayTitle'] ?? s['title'] ?? s['codec'] ?? 'Track'}',
        codec: s['codec'] as String?,
        language: (s['languageTag'] ?? s['languageCode']) as String?,
        isDefault: asBool(s['default']),
        isForced: asBool(s['forced']),
        isExternal: key != null,
        selected: asBool(s['selected']),
        channels: asInt(s['channels']),
        url: key == null ? null : '$_base$key?X-Plex-Token=$_token',
      ));
    }
    var width = asInt(media['width']), height = asInt(media['height']);
    if (width == null && height == null) {
      // List responses often only carry the label.
      (width, height) = switch ('${media['videoResolution']}'.toLowerCase()) {
        '4k' => (3840, 2160),
        '1080' => (1920, 1080),
        '720' => (1280, 720),
        'sd' || '480' || '576' => (720, 480),
        _ => (null, null),
      };
    }
    return MediaVersion(
      id: '${media['id']}',
      partId: part['id']?.toString(),
      partKey: part['key'] as String?,
      container: media['container'] as String?,
      videoCodec: media['videoCodec'] as String?,
      audioCodec: media['audioCodec'] as String?,
      width: width,
      height: height,
      bitrateKbps: asInt(media['bitrate']),
      audioChannels: asInt(media['audioChannels']),
      hdr: hdr,
      streams: streams,
      name: media['editionTitle'] as String?,
    );
  }

  // -- browsing -------------------------------------------------------------

  @override
  Future<List<Library>> libraries() async {
    final c = await _get('/library/sections');
    final out = <Library>[];
    for (final raw in (c['Directory'] as List?) ?? const []) {
      final d = raw as Map<String, dynamic>;
      final kind = switch (d['type']) {
        'movie' => LibraryKind.movies,
        'show' => LibraryKind.shows,
        'artist' => LibraryKind.music,
        _ => null, // photos are out of scope
      };
      if (kind == null) continue;
      out.add(Library(
        serverId: serverId,
        id: '${d['key']}',
        title: '${d['title']}',
        kind: kind,
        art: _img(d['art'] ?? d['composite']),
      ));
    }
    return out;
  }

  @override
  Future<List<MediaItem>> continueWatching() async {
    try {
      return _items(
          await _get('/hubs/continueWatching/items', {'count': 24}));
    } on DioException {
      return _items(await _get('/library/onDeck'));
    }
  }

  @override
  Future<List<MediaItem>> nextUp() async => const [];

  @override
  Future<List<MediaItem>> recentlyAdded(Library library,
      {int limit = 20}) async {
    final type = _typeFor(library.kind, LibraryView.albums);
    final c = await _get('/library/sections/${library.id}/all', {
      'type': type,
      'sort': library.kind == LibraryKind.shows
          ? 'episode.addedAt:desc'
          : 'addedAt:desc',
      'X-Plex-Container-Start': 0,
      'X-Plex-Container-Size': limit,
    });
    return _items(c);
  }

  static int _typeFor(LibraryKind kind, LibraryView view) => switch (kind) {
        LibraryKind.movies => 1,
        LibraryKind.shows => 2,
        LibraryKind.music => view == LibraryView.artists ? 8 : 9,
        LibraryKind.other => 1,
      };

  @override
  Future<Paged> libraryItems(
    Library library, {
    int start = 0,
    int limit = 60,
    LibraryQuery query = const LibraryQuery(),
  }) async {
    final sort = switch (query.sort) {
      SortField.title => 'titleSort',
      SortField.added => 'addedAt',
      SortField.released => 'originallyAvailableAt',
      SortField.rating => 'audienceRating',
    };
    final c = await _get('/library/sections/${library.id}/all', {
      'type': _typeFor(library.kind, query.view),
      'sort': '$sort${query.descending ? ':desc' : ''}',
      'includeCollections': 0,
      if (query.unwatchedOnly)
        library.kind == LibraryKind.shows ? 'unwatchedLeaves' : 'unwatched': 1,
      'X-Plex-Container-Start': start,
      'X-Plex-Container-Size': limit,
    });
    final items = _items(c);
    return Paged(
        items, asInt(c['totalSize']) ?? asInt(c['size']) ?? items.length);
  }

  @override
  Future<List<MediaItem>> collections(Library? library) async {
    final libs = library != null ? [library] : await libraries();
    final out = <MediaItem>[];
    for (final l in libs) {
      try {
        out.addAll(_items(await _get('/library/sections/${l.id}/collections')));
      } on DioException {
        // A library without collection support.
      }
    }
    return out;
  }

  @override
  Future<List<MediaItem>> playlists() async =>
      _items(await _get('/playlists'))
          .where((p) => p.kind == MediaKind.playlist)
          .toList();

  @override
  Future<List<MediaItem>> folders(Library library) async =>
      _items(await _get('/library/sections/${library.id}/folder'));

  @override
  Future<List<MediaItem>> children(MediaItem parent) async {
    final path = switch (parent.kind) {
      MediaKind.collection => '/library/collections/${parent.id}/children',
      MediaKind.playlist => '/playlists/${parent.id}/items',
      MediaKind.folder => parent.id,
      _ => '/library/metadata/${parent.id}/children',
    };
    return _items(await _get(path));
  }

  @override
  Future<MediaItem> item(String id, {MediaKind? kind}) async {
    if (kind == MediaKind.folder) {
      return MediaItem(
          serverId: serverId, id: id, kind: MediaKind.folder, title: 'Folder');
    }
    final c = kind == MediaKind.playlist
        ? await _get('/playlists/$id')
        : await _get('/library/metadata/$id',
            {'includeChapters': 1, 'includeMarkers': 1});
    final list = _items(c);
    if (list.isEmpty) throw StateError('Item not found');
    return list.first;
  }

  @override
  Future<List<MediaItem>> similar(MediaItem item) async {
    try {
      final c = await _get('/hubs/metadata/${item.id}/related', {'count': 12});
      final seen = <String>{item.id};
      final out = <MediaItem>[];
      for (final h in (c['Hub'] as List?) ?? const []) {
        for (final i in _items(h as Map<String, dynamic>)) {
          if (i.kind != MediaKind.folder && seen.add(i.id)) out.add(i);
        }
      }
      return out.take(24).toList();
    } on DioException {
      return const [];
    }
  }

  @override
  Future<List<Shelf>> discover() async {
    final c = await _get('/hubs', {
      'count': 16,
      'excludeContinueWatching': 1,
      'includeLibraryPlaylists': 0,
    });
    final out = <Shelf>[];
    for (final raw in (c['Hub'] as List?) ?? const []) {
      final h = raw as Map<String, dynamic>;
      final items =
          _items(h).where((i) => i.kind != MediaKind.folder).toList();
      if (items.isEmpty) continue;
      final id = '${h['hubIdentifier']}';
      if (id.contains('ondeck') || id.contains('continue')) continue;
      out.add(Shelf('${h['title']}', items));
    }
    return out;
  }

  /// The library's own hubs, as on the Recommended tab of Plex's apps.
  @override
  Future<List<Shelf>> recommended(Library library) async {
    final c = await _get('/hubs/sections/${library.id}', {
      'count': 16,
      'includeLibraryPlaylists': 0,
      'includeStations': 0,
      'includeRecentChannels': 0,
    });
    final out = <Shelf>[];
    for (final raw in (c['Hub'] as List?) ?? const []) {
      final h = raw as Map<String, dynamic>;
      final items = _items(h)
          .where((i) => i.kind != MediaKind.folder && i.kind != MediaKind.unknown)
          .toList();
      if (items.isEmpty) continue;
      final id = '${h['hubIdentifier']}';
      out.add(Shelf(
        '${h['title']}',
        items,
        landscape: id.contains('inprogress') ||
            id.contains('ondeck') ||
            id.contains('continue'),
      ));
    }
    return out;
  }

  @override
  Future<List<MediaItem>> search(String query) async {
    final c = await _get('/hubs/search',
        {'query': query, 'limit': 24, 'includeCollections': 1});
    final out = <MediaItem>[];
    for (final h in (c['Hub'] as List?) ?? const []) {
      out.addAll(_items(h as Map<String, dynamic>).where((i) =>
          i.kind != MediaKind.folder && i.kind != MediaKind.unknown));
    }
    return out;
  }

  @override
  Future<MediaItem?> nextEpisode(MediaItem episode) async {
    final show = episode.grandparentId;
    if (episode.kind != MediaKind.episode || show == null) return null;
    final all = _items(await _get('/library/metadata/$show/allLeaves'));
    final i = all.indexWhere((e) => e.id == episode.id);
    return (i < 0 || i + 1 >= all.length) ? null : all[i + 1];
  }

  @override
  Future<List<Marker>> markers(MediaItem item) async {
    if (item.markers.isNotEmpty) return item.markers;
    return (await this.item(item.id)).markers;
  }

  // -- playback -------------------------------------------------------------

  @override
  Future<PlaybackSource> playback(
      MediaItem item, PlaybackRequest request) async {
    final full = item.versions.any((v) => v.partKey != null && v.streams.isNotEmpty)
        ? item
        : await this.item(item.id);
    if (full.versions.isEmpty) throw StateError('Nothing playable here');
    final mediaIndex = request.versionId == null
        ? 0
        : full.versions
            .indexWhere((v) => v.id == request.versionId)
            .clamp(0, full.versions.length - 1);
    final v = full.versions[mediaIndex];
    final session = const Uuid().v4();

    if (request.maxBitrateKbps == null || item.kind.isAudio) {
      return PlaybackSource(
        url: '$_base${v.partKey}?X-Plex-Token=$_token',
        method: PlayMethod.directPlay,
        sessionId: session,
        version: v,
        audioStreams: v.audio,
        subtitleStreams: v.subtitles,
      );
    }

    // The transcoder reads its audio/subtitle choice from the part.
    if (v.partId != null &&
        (request.audioStreamId != null || request.subtitleStreamId != null)) {
      await _dio.put<dynamic>('/library/parts/${v.partId}', queryParameters: {
        'audioStreamID': ?request.audioStreamId,
        if (request.subtitleStreamId != null)
          'subtitleStreamID':
              request.subtitleStreamId!.isEmpty ? 0 : request.subtitleStreamId,
        'allParts': 1,
      });
    }
    final kbps = request.maxBitrateKbps!;
    final res = kbps >= 30000
        ? '3840x2160'
        : kbps >= 8000
            ? '1920x1080'
            : kbps >= 2000
                ? '1280x720'
                : kbps >= 1000
                    ? '854x480'
                    : '640x360';
    final q = <String, String>{
      'path': '/library/metadata/${item.id}',
      'mediaIndex': '$mediaIndex',
      'partIndex': '0',
      'protocol': 'hls',
      'fastSeek': '1',
      'directPlay': '0',
      'directStream': '0',
      'directStreamAudio': '1',
      'videoQuality': '100',
      'maxVideoBitrate': '$kbps',
      'videoResolution': res,
      'subtitles': 'burn',
      'subtitleSize': '100',
      'audioBoost': '100',
      'mediaBufferSize': '102400',
      'hasMDE': '1',
      'location': 'wan',
      'session': session,
      'X-Plex-Session-Identifier': session,
      'X-Plex-Client-Profile-Extra':
          'add-transcode-target(type=videoProfile&context=streaming&protocol=hls'
              '&container=mpegts&videoCodec=h264&audioCodec=aac,ac3,mp3)',
      ...ClientInfo.plexHeaders,
      'X-Plex-Token': _token,
    }..remove('Accept');
    return PlaybackSource(
      url: Uri.parse('$_base/video/:/transcode/universal/start.m3u8')
          .replace(queryParameters: q)
          .toString(),
      method: PlayMethod.transcode,
      sessionId: session,
      version: v,
      audioStreams: v.audio,
      subtitleStreams: v.subtitles,
    );
  }

  @override
  Future<void> reportProgress(MediaItem item, PlaybackSource source,
      Duration position, PlayState state) async {
    await _dio.get<dynamic>('/:/timeline', queryParameters: {
      'ratingKey': item.id,
      'key': '/library/metadata/${item.id}',
      'state': state == PlayState.started ? 'playing' : state.name,
      'time': position.inMilliseconds,
      'duration': item.duration?.inMilliseconds ?? 0,
      'X-Plex-Session-Identifier': source.sessionId,
    });
    if (state == PlayState.stopped && source.method == PlayMethod.transcode) {
      await _dio.get<dynamic>('/video/:/transcode/universal/stop',
          queryParameters: {'session': source.sessionId});
    }
  }

  @override
  Future<void> setPlayed(MediaItem item, bool played) =>
      _dio.get<dynamic>(played ? '/:/scrobble' : '/:/unscrobble',
          queryParameters: {
            'identifier': 'com.plexapp.plugins.library',
            'key': item.id,
          });

  // -- library scans --------------------------------------------------------

  @override
  bool get canScanLibraries => true;

  @override
  Future<void> scanLibrary(Library? library) async {
    try {
      await _dio.get<dynamic>(
          '/library/sections/${library?.id ?? 'all'}/refresh');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        throw const BackendException(
            'Only the server owner can scan libraries on this Plex server.');
      }
      rethrow;
    }
  }

  // -- watchlist (lives on plex.tv, not on the server) ------------------------

  Dio get _discover => _discoverDio ??= Dio(BaseOptions(
        baseUrl: 'https://discover.provider.plex.tv',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          ...ClientInfo.plexHeaders,
          'X-Plex-Token': config.accountToken,
        },
      ));

  @override
  bool get supportsWatchlist => (config.accountToken ?? '').isNotEmpty;

  @override
  String get watchlistName => 'Plex Watchlist';

  @override
  Future<List<MediaItem>> watchlist() async {
    if (!supportsWatchlist) return const [];
    final r = await _discover.get<Map<String, dynamic>>(
        '/library/sections/watchlist/all',
        queryParameters: {
          'includeCollections': 1,
          'includeExternalMedia': 1,
          'sort': 'watchlistedAt:desc',
          'X-Plex-Container-Start': 0,
          'X-Plex-Container-Size': 100,
        });
    final c = (r.data?['MediaContainer'] as Map<String, dynamic>?) ?? const {};
    return [
      for (final raw in (c['Metadata'] as List?) ?? const [])
        _watchlistItem(raw as Map<String, dynamic>),
    ];
  }

  MediaItem _watchlistItem(Map<String, dynamic> m) => MediaItem(
        serverId: serverId,
        id: 'watchlist:${m['ratingKey']}',
        kind: _kind(m['type'] as String?),
        title: '${m['title'] ?? ''}',
        year: asInt(m['year']),
        poster: _img(m['thumb']),
        backdrop: _img(m['art']),
        external: true,
      );

  String? _discoverKey(MediaItem item) {
    if (item.id.startsWith('watchlist:')) return item.id.substring(10);
    final guid = item.externalIds['plex'];
    return guid?.split('/').last;
  }

  @override
  Future<bool> isWatchlisted(MediaItem item) async {
    final key = _discoverKey(item);
    if (!supportsWatchlist || key == null) return false;
    try {
      final r = await _discover
          .get<Map<String, dynamic>>('/library/metadata/$key/userState');
      final states = (r.data?['MediaContainer']?['UserState'] as List?) ?? [];
      return states.isNotEmpty &&
          (states.first as Map)['watchlistedAt'] != null;
    } on DioException {
      return false;
    }
  }

  @override
  Future<void> setWatchlisted(MediaItem item, bool value) async {
    final key = _discoverKey(item);
    if (key == null) {
      throw StateError('This title has no Plex match to watchlist');
    }
    await _discover.put<dynamic>(
        value ? '/actions/addToWatchlist' : '/actions/removeFromWatchlist',
        queryParameters: {'ratingKey': key});
  }

  @override
  void dispose() {
    _dio.close();
    _discoverDio?.close();
  }
}
