import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'backend.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// Sign-in helpers
// ---------------------------------------------------------------------------

class JellyfinLogin {
  const JellyfinLogin({
    required this.baseUrl,
    required this.serverName,
    required this.serverId,
    required this.token,
    required this.userId,
    required this.userName,
  });
  final String baseUrl;
  final String serverName;
  final String serverId;
  final String token;
  final String userId;
  final String userName;
}

class JellyfinServerInfo {
  const JellyfinServerInfo(this.baseUrl, this.name, this.id, this.version);
  final String baseUrl;
  final String name;
  final String id;
  final String version;
}

class JellyfinAuth {
  static Dio _dio(String base) => Dio(BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'Authorization': ClientInfo.jellyfinAuth(),
          'Accept': 'application/json',
        },
      ));

  /// Accepts whatever the user typed ("nas", "nas:8096", "https://jf.me/")
  /// and finds the address that answers.
  static Future<JellyfinServerInfo> locate(String input) async {
    var raw = input.trim();
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }
    if (raw.isEmpty) throw const FormatException('Enter a server address');
    final candidates = <String>[];
    if (raw.contains('://')) {
      candidates.add(raw);
    } else {
      final hasPort = RegExp(r':\d+$').hasMatch(raw);
      candidates.addAll([
        'https://$raw',
        'http://$raw',
        if (!hasPort) 'http://$raw:8096',
        if (!hasPort) 'https://$raw:8920',
      ]);
    }
    Object? lastError;
    for (final base in candidates) {
      try {
        final r = await _dio(base)
            .get<Map<String, dynamic>>('/System/Info/Public');
        final d = r.data;
        if (d != null && d['Id'] != null) {
          return JellyfinServerInfo(base, '${d['ServerName'] ?? 'Jellyfin'}',
              '${d['Id']}', '${d['Version'] ?? ''}');
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
        'No Jellyfin server answered at "$raw"${lastError is DioException ? ' (${lastError.type.name})' : ''}');
  }

  static JellyfinLogin _login(
      JellyfinServerInfo s, Map<String, dynamic> d) =>
      JellyfinLogin(
        baseUrl: s.baseUrl,
        serverName: s.name,
        serverId: s.id,
        token: d['AccessToken'] as String,
        userId: '${(d['User'] as Map)['Id']}',
        userName: '${(d['User'] as Map)['Name']}',
      );

  static Future<JellyfinLogin> byPassword(
      JellyfinServerInfo s, String user, String password) async {
    final r = await _dio(s.baseUrl).post<Map<String, dynamic>>(
        '/Users/AuthenticateByName',
        data: {'Username': user, 'Pw': password});
    return _login(s, r.data!);
  }

  static Future<bool> quickConnectEnabled(JellyfinServerInfo s) async {
    try {
      final r = await _dio(s.baseUrl).get<dynamic>('/QuickConnect/Enabled');
      return asBool(r.data);
    } catch (_) {
      return false;
    }
  }

  /// Returns (secret, code). Show the code; the user approves it from any
  /// signed-in Jellyfin client.
  static Future<(String, String)> quickConnectStart(
      JellyfinServerInfo s) async {
    final r = await _dio(s.baseUrl)
        .post<Map<String, dynamic>>('/QuickConnect/Initiate');
    return ('${r.data!['Secret']}', '${r.data!['Code']}');
  }

  static Future<JellyfinLogin?> quickConnectPoll(
      JellyfinServerInfo s, String secret) async {
    final dio = _dio(s.baseUrl);
    final state = await dio.get<Map<String, dynamic>>('/QuickConnect/Connect',
        queryParameters: {'secret': secret});
    if (!asBool(state.data?['Authenticated'])) return null;
    final r = await dio.post<Map<String, dynamic>>(
        '/Users/AuthenticateWithQuickConnect',
        data: {'Secret': secret});
    return _login(s, r.data!);
  }
}

// ---------------------------------------------------------------------------
// Jellyfin server (10.9 or newer)
// ---------------------------------------------------------------------------

class JellyfinBackend extends MediaBackend {
  JellyfinBackend(this.config, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: config.baseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 25),
              headers: {
                'Authorization': ClientInfo.jellyfinAuth(config.token),
                'Accept': 'application/json',
              },
            ));

  @override
  final ServerConfig config;
  final Dio _dio;

  String get _base => config.baseUrl;
  String get _uid => config.userId ?? '';
  Map<String, String> get _authHeaders =>
      {'Authorization': ClientInfo.jellyfinAuth(config.token)};

  static const _listFields =
      'PrimaryImageAspectRatio,ChildCount,ProviderIds,Width,Height,DateCreated';
  static const _detailFields =
      'Overview,Genres,People,Chapters,MediaSources,MediaStreams,ProviderIds,'
      'ChildCount,Taglines,Studios,DateCreated,Width,Height';

  Future<List<MediaItem>> _list(String path,
      [Map<String, dynamic>? query]) async {
    final r = await _dio.get<dynamic>(path, queryParameters: {
      'userId': _uid,
      'fields': _listFields,
      'enableImageTypes': 'Primary,Backdrop,Thumb',
      'imageTypeLimit': 1,
      ...?query,
    });
    return _parseList(r.data);
  }

  List<MediaItem> _parseList(Object? data) {
    final list = data is Map ? (data['Items'] as List? ?? const []) : data;
    return [
      for (final m in (list as List?) ?? const [])
        parse(m as Map<String, dynamic>)
    ];
  }

  ImageRef _img(String itemId, String type, String? tag, {int? index}) =>
      ImageRef('$_base/Items/$itemId/Images/$type${index != null ? '/$index' : ''}'
          '?fillWidth={w}&quality=90${tag != null ? '&tag=$tag' : ''}');

  static MediaKind _kind(String? type) => switch (type) {
        'Movie' => MediaKind.movie,
        'Series' => MediaKind.show,
        'Season' => MediaKind.season,
        'Episode' => MediaKind.episode,
        'MusicArtist' => MediaKind.artist,
        'MusicAlbum' => MediaKind.album,
        'Audio' => MediaKind.track,
        'BoxSet' => MediaKind.collection,
        'Playlist' => MediaKind.playlist,
        'Video' || 'MusicVideo' || 'Trailer' => MediaKind.video,
        'Folder' ||
        'CollectionFolder' ||
        'UserView' ||
        'AggregateFolder' ||
        'PhotoAlbum' =>
          MediaKind.folder,
        _ => MediaKind.unknown,
      };

  static Duration _ticks(Object? v) =>
      Duration(microseconds: (asInt(v) ?? 0) ~/ 10);

  MediaItem parse(Map<String, dynamic> m) {
    final id = '${m['Id']}';
    var kind = _kind(m['Type'] as String?);
    if (kind == MediaKind.unknown && asBool(m['IsFolder'])) {
      kind = MediaKind.folder;
    }
    final tags = (m['ImageTags'] as Map?) ?? const {};
    final user = (m['UserData'] as Map?) ?? const {};
    final backdrops = (m['BackdropImageTags'] as List?) ?? const [];
    final parentBackdrops = (m['ParentBackdropImageTags'] as List?) ?? const [];
    final seriesId = m['SeriesId'] as String?;
    final albumId = m['AlbumId'] as String?;

    ImageRef? own(String type) =>
        tags[type] != null ? _img(id, type, '${tags[type]}') : null;

    ImageRef? poster, thumb;
    switch (kind) {
      case MediaKind.episode:
        poster = seriesId != null
            ? _img(seriesId, 'Primary', m['SeriesPrimaryImageTag'] as String?)
            : own('Primary');
        thumb = own('Primary');
      case MediaKind.season:
        poster = own('Primary') ??
            (seriesId != null
                ? _img(seriesId, 'Primary',
                    m['SeriesPrimaryImageTag'] as String?)
                : null);
      case MediaKind.track:
        poster = own('Primary') ??
            (albumId != null && m['AlbumPrimaryImageTag'] != null
                ? _img(albumId, 'Primary', '${m['AlbumPrimaryImageTag']}')
                : null);
      default:
        poster = own('Primary');
        thumb = own('Thumb') ??
            (backdrops.isNotEmpty
                ? _img(id, 'Backdrop', '${backdrops.first}', index: 0)
                : null);
    }
    ImageRef? backdrop;
    if (backdrops.isNotEmpty) {
      backdrop = _img(id, 'Backdrop', '${backdrops.first}', index: 0);
    } else if (m['ParentBackdropItemId'] != null &&
        parentBackdrops.isNotEmpty) {
      backdrop = _img('${m['ParentBackdropItemId']}', 'Backdrop',
          '${parentBackdrops.first}',
          index: 0);
    }

    final chapters = <Chapter>[];
    final rawChapters = (m['Chapters'] as List?) ?? const [];
    for (var i = 0; i < rawChapters.length; i++) {
      final c = rawChapters[i] as Map;
      chapters.add(Chapter(
        title: '${c['Name'] ?? 'Chapter ${i + 1}'}',
        start: _ticks(c['StartPositionTicks']),
        thumb: c['ImageTag'] != null
            ? _img(id, 'Chapter', '${c['ImageTag']}', index: i)
            : null,
      ));
    }

    final provider = (m['ProviderIds'] as Map?) ?? const {};
    final artists = (m['Artists'] as List?)?.join(', ');
    final isSeasonOrEpisode =
        kind == MediaKind.season || kind == MediaKind.episode;
    final sources = (m['MediaSources'] as List?) ?? const [];

    return MediaItem(
      serverId: serverId,
      id: id,
      kind: kind,
      title: '${m['Name'] ?? ''}',
      overview: m['Overview'] as String?,
      tagline: ((m['Taglines'] as List?) ?? const []).isNotEmpty
          ? '${(m['Taglines'] as List).first}'
          : null,
      year: asInt(m['ProductionYear']),
      duration: m['RunTimeTicks'] != null ? _ticks(m['RunTimeTicks']) : null,
      viewOffset: _ticks(user['PlaybackPositionTicks']),
      played: asBool(user['Played']),
      unplayedCount: asInt(user['UnplayedItemCount']),
      childCount: asInt(m['ChildCount']) ?? asInt(m['RecursiveItemCount']),
      poster: poster,
      thumb: thumb,
      backdrop: backdrop,
      parentId: switch (kind) {
        MediaKind.episode => m['SeasonId'] as String?,
        MediaKind.season => seriesId,
        MediaKind.track => albumId,
        _ => m['ParentId'] as String?,
      },
      grandparentId: kind == MediaKind.episode ? seriesId : null,
      parentTitle: switch (kind) {
        MediaKind.episode => m['SeasonName'] as String?,
        MediaKind.season => m['SeriesName'] as String?,
        MediaKind.track => m['Album'] as String?,
        MediaKind.album => (m['AlbumArtist'] as String?) ?? artists,
        _ => null,
      },
      grandparentTitle: isSeasonOrEpisode
          ? m['SeriesName'] as String?
          : (kind == MediaKind.track
              ? ((m['AlbumArtist'] as String?) ?? artists)
              : null),
      index: asInt(m['IndexNumber']),
      parentIndex: asInt(m['ParentIndexNumber']),
      contentRating: m['OfficialRating'] as String?,
      rating: asDouble(m['CommunityRating']),
      genres: ((m['Genres'] as List?) ?? const []).cast<String>(),
      people: [
        for (final p in ((m['People'] as List?) ?? const []).take(24))
          Person(
            name: '${(p as Map)['Name']}',
            role: (p['Role'] as String?)?.isNotEmpty == true
                ? p['Role'] as String
                : p['Type'] as String?,
            image: p['PrimaryImageTag'] != null
                ? _img('${p['Id']}', 'Primary', '${p['PrimaryImageTag']}')
                : null,
          ),
      ],
      studio: ((m['Studios'] as List?) ?? const []).isNotEmpty
          ? '${((m['Studios'] as List).first as Map)['Name']}'
          : null,
      addedAt: DateTime.tryParse('${m['DateCreated']}'),
      lastViewedAt: DateTime.tryParse('${user['LastPlayedDate']}'),
      versions: sources.isNotEmpty
          ? [for (final s in sources) _version(s as Map<String, dynamic>)]
          : (asInt(m['Width']) != null
              ? [
                  MediaVersion(
                      id: id,
                      width: asInt(m['Width']),
                      height: asInt(m['Height']))
                ]
              : const []),
      chapters: chapters,
      isFavorite: asBool(user['IsFavorite']),
      externalIds: {
        if (provider['Tmdb'] != null) 'tmdb': '${provider['Tmdb']}',
        if (provider['Imdb'] != null) 'imdb': '${provider['Imdb']}',
        if (provider['Tvdb'] != null) 'tvdb': '${provider['Tvdb']}',
      },
    );
  }

  MediaVersion _version(Map<String, dynamic> s) {
    final itemId = '${s['Id']}';
    final streams = <MediaStreamInfo>[];
    int? width, height, channels;
    String? vCodec, aCodec, hdr;
    for (final raw in (s['MediaStreams'] as List?) ?? const []) {
      final st = raw as Map;
      final type = switch (st['Type']) {
        'Video' => StreamType.video,
        'Audio' => StreamType.audio,
        'Subtitle' => StreamType.subtitle,
        _ => null,
      };
      if (type == null) continue;
      if (type == StreamType.video && vCodec == null) {
        vCodec = st['Codec'] as String?;
        width = asInt(st['Width']);
        height = asInt(st['Height']);
        final range = '${st['VideoRangeType'] ?? st['VideoRange'] ?? ''}';
        hdr = range.startsWith('DOVI')
            ? 'DV'
            : switch (range) {
                'HDR10' || 'HDR' => 'HDR10',
                'HDR10Plus' => 'HDR10+',
                'HLG' => 'HLG',
                _ => null,
              };
      }
      if (type == StreamType.audio && (aCodec == null || asBool(st['IsDefault']))) {
        aCodec = st['Codec'] as String?;
        channels = asInt(st['Channels']);
      }
      String? url;
      if (type == StreamType.subtitle) {
        final delivery = st['DeliveryUrl'] as String?;
        if (delivery != null && st['DeliveryMethod'] == 'External') {
          url = delivery.startsWith('http') ? delivery : '$_base$delivery';
        } else if (asBool(st['IsExternal']) &&
            asBool(st['IsTextSubtitleStream'])) {
          url = '$_base/Videos/$itemId/$itemId/Subtitles/${st['Index']}/Stream.srt';
        }
      }
      streams.add(MediaStreamInfo(
        id: '${st['Index']}',
        type: type,
        title: '${st['DisplayTitle'] ?? st['Title'] ?? st['Codec'] ?? 'Track'}',
        codec: st['Codec'] as String?,
        language: st['Language'] as String?,
        isDefault: asBool(st['IsDefault']),
        isForced: asBool(st['IsForced']),
        isExternal: asBool(st['IsExternal']),
        channels: asInt(st['Channels']),
        url: url,
      ));
    }
    final bitrate = asInt(s['Bitrate']);
    return MediaVersion(
      id: itemId,
      container: s['Container'] as String?,
      videoCodec: vCodec,
      audioCodec: aCodec,
      width: width,
      height: height,
      bitrateKbps: bitrate == null ? null : bitrate ~/ 1000,
      audioChannels: channels,
      hdr: hdr,
      streams: streams,
      name: (s['Name'] as String?),
    );
  }

  // -- browsing -------------------------------------------------------------

  @override
  Future<List<Library>> libraries() async {
    final r = await _dio.get<Map<String, dynamic>>('/UserViews',
        queryParameters: {'userId': _uid});
    final out = <Library>[];
    for (final raw in (r.data?['Items'] as List?) ?? const []) {
      final v = raw as Map<String, dynamic>;
      final type = v['CollectionType'] as String?;
      // Collections and playlists get their own sections in the app.
      if (const {'boxsets', 'playlists', 'livetv', 'books', 'photos'}
          .contains(type)) {
        continue;
      }
      final tags = (v['ImageTags'] as Map?) ?? const {};
      out.add(Library(
        serverId: serverId,
        id: '${v['Id']}',
        title: '${v['Name']}',
        kind: switch (type) {
          'movies' => LibraryKind.movies,
          'tvshows' => LibraryKind.shows,
          'music' => LibraryKind.music,
          _ => LibraryKind.other,
        },
        art: tags['Primary'] != null
            ? _img('${v['Id']}', 'Primary', '${tags['Primary']}')
            : null,
      ));
    }
    return out;
  }

  Future<List<Library>>? _libraries;

  /// Jellyfin items don't say which library they came from, so when the user
  /// hides any, a query runs once per visible library ([where] narrows which)
  /// with `parentId` set. With nothing hidden it runs once, unscoped.
  Future<List<MediaItem>> _scoped(
    Future<List<MediaItem>> Function(String? parentId) fetch, {
    bool Function(Library l)? where,
  }) async {
    if (hiddenLibraries.isEmpty) return fetch(null);
    final libs = (await (_libraries ??= libraries()))
        .where((l) => !hiddenLibraries.contains(l.id) && (where?.call(l) ?? true));
    final lists = await Future.wait(libs.map((l) => fetch(l.id)));
    return lists.expand((l) => l).toList();
  }

  static bool _hasVideo(Library l) => l.kind != LibraryKind.music;
  static bool _hasShows(Library l) =>
      l.kind == LibraryKind.shows || l.kind == LibraryKind.other;

  @override
  Future<List<MediaItem>> continueWatching() async {
    final items = await _scoped(
        (parent) => _list('/UserItems/Resume', {
              'mediaTypes': 'Video',
              'limit': 24,
              'enableUserData': true,
              'parentId': ?parent,
            }),
        where: _hasVideo);
    if (hiddenLibraries.isNotEmpty) {
      final epoch = DateTime(0);
      items.sort((a, b) =>
          (b.lastViewedAt ?? epoch).compareTo(a.lastViewedAt ?? epoch));
    }
    return items.take(24).toList();
  }

  @override
  Future<List<MediaItem>> nextUp() => _scoped(
      (parent) => _list('/Shows/NextUp', {
            'limit': 24,
            'enableResumable': false,
            'enableRewatching': false,
            'parentId': ?parent,
          }),
      where: _hasShows);

  @override
  Future<List<MediaItem>> recentlyAdded(Library library, {int limit = 20}) =>
      _list('/Items/Latest', {'parentId': library.id, 'limit': limit});

  @override
  Future<Paged> libraryItems(
    Library library, {
    int start = 0,
    int limit = 60,
    LibraryQuery query = const LibraryQuery(),
  }) async {
    final sortBy = switch (query.sort) {
      SortField.title => 'SortName',
      SortField.added => 'DateCreated,SortName',
      SortField.released => 'PremiereDate,SortName',
      SortField.rating => 'CommunityRating,SortName',
    };
    final common = <String, dynamic>{
      'userId': _uid,
      'parentId': library.id,
      'startIndex': start,
      'limit': limit,
      'sortBy': sortBy,
      'sortOrder': query.descending ? 'Descending' : 'Ascending',
      'fields': _listFields,
      'enableImageTypes': 'Primary,Backdrop,Thumb',
      'imageTypeLimit': 1,
      if (query.unwatchedOnly) 'filters': 'IsUnplayed',
    };
    final Response<Map<String, dynamic>> r;
    if (library.kind == LibraryKind.music &&
        query.view == LibraryView.artists) {
      r = await _dio.get('/Artists/AlbumArtists', queryParameters: common);
    } else {
      final types = switch (library.kind) {
        LibraryKind.movies => 'Movie',
        LibraryKind.shows => 'Series',
        LibraryKind.music => 'MusicAlbum',
        LibraryKind.other => null,
      };
      r = await _dio.get('/Items', queryParameters: {
        ...common,
        'includeItemTypes': ?types,
        'recursive': types != null,
      });
    }
    final items = _parseList(r.data);
    return Paged(items, asInt(r.data?['TotalRecordCount']) ?? items.length);
  }

  @override
  Future<List<MediaItem>> collections(Library? library) => _list('/Items', {
        'includeItemTypes': 'BoxSet',
        'recursive': true,
        'sortBy': 'SortName',
      });

  @override
  Future<List<MediaItem>> playlists() => _list('/Items', {
        'includeItemTypes': 'Playlist',
        'recursive': true,
        'sortBy': 'SortName',
      });

  @override
  Future<List<MediaItem>> folders(Library library) => _list('/Items',
      {'parentId': library.id, 'sortBy': 'IsFolder,SortName'});

  @override
  Future<List<MediaItem>> children(MediaItem parent) => switch (parent.kind) {
        MediaKind.show => _list('/Shows/${parent.id}/Seasons'),
        MediaKind.season => _list(
            '/Shows/${parent.parentId ?? parent.id}/Episodes',
            {'seasonId': parent.id, 'fields': '$_listFields,Overview'}),
        MediaKind.artist => _list('/Items', {
            'albumArtistIds': parent.id,
            'includeItemTypes': 'MusicAlbum',
            'recursive': true,
            'sortBy': 'PremiereDate,SortName',
            'sortOrder': 'Descending',
          }),
        MediaKind.album => _list('/Items',
            {'parentId': parent.id, 'sortBy': 'ParentIndexNumber,IndexNumber'}),
        MediaKind.playlist => _list('/Playlists/${parent.id}/Items'),
        MediaKind.folder => _list('/Items',
            {'parentId': parent.id, 'sortBy': 'IsFolder,SortName'}),
        _ => _list('/Items', {'parentId': parent.id, 'sortBy': 'SortName'}),
      };

  @override
  Future<MediaItem> item(String id, {MediaKind? kind}) async {
    final r = await _dio.get<Map<String, dynamic>>('/Items/$id',
        queryParameters: {'userId': _uid, 'fields': _detailFields});
    return parse(r.data!);
  }

  @override
  Future<List<MediaItem>> similar(MediaItem item) async {
    try {
      return await _list('/Items/${item.id}/Similar', {'limit': 16});
    } on DioException {
      return const [];
    }
  }

  @override
  Future<List<Shelf>> discover() async {
    final out = <Shelf>[];
    try {
      final all = await (_libraries ??= libraries());
      final movieLibs = all.where((l) => l.kind == LibraryKind.movies);
      final visibleMovieLibs =
          movieLibs.where((l) => !hiddenLibraries.contains(l.id)).toList();
      // Unscoped when nothing relevant is hidden; otherwise one call per
      // visible movie library.
      final parents = visibleMovieLibs.length == movieLibs.length
          ? <String?>[null]
          : [for (final l in visibleMovieLibs) l.id];
      final lists = await Future.wait(
          parents.map((p) => _movieRecommendations(p, categories: 6)));
      out.addAll(lists.expand((l) => l));
    } on DioException {
      // Recommendations are optional.
    }
    // Suggestions can't be scoped to a library, so they're left out while a
    // shows library is hidden.
    final hidesShows = hiddenLibraries.isNotEmpty &&
        (await (_libraries ??= libraries()))
            .any((l) => _hasShows(l) && hiddenLibraries.contains(l.id));
    if (!hidesShows) {
      try {
        final shows = await _list('/Items/Suggestions',
            {'type': 'Series', 'mediaType': 'Video', 'limit': 16});
        if (shows.isNotEmpty) out.add(Shelf('Shows you might like', shows));
      } on DioException {
        // Optional too.
      }
    }
    return out;
  }

  /// "Because you watched …" style rows, optionally for one library.
  Future<List<Shelf>> _movieRecommendations(String? parentId,
      {required int categories}) async {
    final r = await _dio.get<List<dynamic>>('/Movies/Recommendations',
        queryParameters: {
          'userId': _uid,
          'categoryLimit': categories,
          'itemLimit': 16,
          'fields': _listFields,
          'parentId': ?parentId,
        });
    return [
      for (final raw in r.data ?? const [])
        if (_parseList((raw as Map)['Items']) case final items
            when items.isNotEmpty)
          Shelf(
            switch (raw['RecommendationType']) {
              'SimilarToRecentlyPlayed' =>
                'Because you watched ${raw['BaselineItemName']}',
              'SimilarToLikedItem' =>
                'Because you liked ${raw['BaselineItemName']}',
              'HasDirectorFromRecentlyPlayed' ||
              'HasLikedDirector' =>
                'Directed by ${raw['BaselineItemName']}',
              'HasActorFromRecentlyPlayed' ||
              'HasLikedActor' =>
                'Starring ${raw['BaselineItemName']}',
              _ => 'Recommended',
            },
            items,
          ),
    ];
  }

  @override
  Future<List<Shelf>> recommended(Library library) async {
    final shows = library.kind == LibraryKind.shows;
    final id = library.id;
    // Each row is optional: one failing (an older server, a plugin missing)
    // must not blank the tab.
    Future<List<MediaItem>> row(Future<List<MediaItem>> f) async {
      try {
        return await f;
      } on DioException {
        return const [];
      }
    }

    final results = await Future.wait([
      row(_list('/UserItems/Resume', {
        'parentId': id,
        'mediaTypes': 'Video',
        'limit': 16,
        'enableUserData': true,
      })),
      if (shows)
        row(_list('/Shows/NextUp', {
          'parentId': id,
          'limit': 16,
          'enableResumable': false,
          'enableRewatching': false,
        })),
      row(_list('/Items/Latest', {'parentId': id, 'limit': 16})),
      row(_list('/Items', {
        'parentId': id,
        'recursive': true,
        'includeItemTypes': shows ? 'Series' : 'Movie',
        'filters': 'IsUnplayed',
        'sortBy': 'CommunityRating,SortName',
        'sortOrder': 'Descending',
        'limit': 16,
      })),
    ]);
    var i = 0;
    final out = <Shelf>[
      Shelf('Continue watching', results[i++], landscape: true),
      if (shows) Shelf('Next up', results[i++], landscape: true),
      Shelf('Recently added', results[i++]),
      Shelf(shows ? 'Top rated shows' : 'Top rated movies', results[i++]),
    ];
    if (library.kind == LibraryKind.movies) {
      try {
        // After "Recently added", like Jellyfin's own Suggestions tab.
        out.insertAll(3, await _movieRecommendations(id, categories: 4));
      } on DioException {
        // Recommendations are optional.
      }
    }
    return out.where((s) => s.items.isNotEmpty).toList();
  }

  @override
  Future<List<MediaItem>> search(String query) => _scoped((parent) =>
      _list('/Items', {
        'searchTerm': query,
        'recursive': true,
        'limit': 60,
        'includeItemTypes':
            'Movie,Series,Episode,MusicArtist,MusicAlbum,Audio,BoxSet,Playlist',
        'parentId': ?parent,
      }));

  @override
  Future<MediaItem?> nextEpisode(MediaItem episode) async {
    final series = episode.grandparentId;
    if (episode.kind != MediaKind.episode || series == null) return null;
    final list = await _list('/Shows/$series/Episodes',
        {'startItemId': episode.id, 'limit': 2});
    return list.length > 1 ? list[1] : null;
  }

  @override
  Future<List<Marker>> markers(MediaItem item) async {
    // Media segments arrived in 10.10 (intro/outro detection plugins feed it).
    try {
      final r = await _dio.get<Map<String, dynamic>>(
          '/MediaSegments/${item.id}',
          queryParameters: {
            'includeSegmentTypes': ['Intro', 'Outro']
          });
      return [
        for (final raw in (r.data?['Items'] as List?) ?? const [])
          Marker(
            type: (raw as Map)['Type'] == 'Intro'
                ? MarkerType.intro
                : MarkerType.credits,
            start: _ticks(raw['StartTicks']),
            end: _ticks(raw['EndTicks']),
          ),
      ];
    } on DioException {
      return const [];
    }
  }

  // -- playback -------------------------------------------------------------

  /// libmpv plays practically everything, so the profile asks for direct play
  /// of any container and only describes what to transcode *to*.
  Map<String, dynamic> _deviceProfile(int maxBitrate) => {
        'Name': ClientInfo.product,
        'MaxStreamingBitrate': maxBitrate,
        'MaxStaticBitrate': maxBitrate,
        'MusicStreamingTranscodingBitrate': 320000,
        'DirectPlayProfiles': [
          {'Type': 'Video'},
          {'Type': 'Audio'},
        ],
        'TranscodingProfiles': [
          {
            'Type': 'Video',
            'Container': 'ts',
            'Protocol': 'hls',
            'VideoCodec': 'h264',
            'AudioCodec': 'aac,ac3,mp3',
            'Context': 'Streaming',
            'MaxAudioChannels': '6',
            'MinSegments': 1,
            'BreakOnNonKeyFrames': true,
          },
          {
            'Type': 'Audio',
            'Container': 'mp3',
            'AudioCodec': 'mp3',
            'Protocol': 'http',
            'Context': 'Streaming',
          },
        ],
        'SubtitleProfiles': [
          for (final f in ['srt', 'subrip', 'ass', 'ssa', 'vtt'])
            {'Format': f, 'Method': 'External'},
          for (final f in [
            'srt', 'subrip', 'ass', 'ssa', 'vtt', 'pgssub', 'pgs',
            'dvdsub', 'dvbsub', 'mov_text',
          ])
            {'Format': f, 'Method': 'Embed'},
        ],
        'CodecProfiles': <dynamic>[],
        'ContainerProfiles': <dynamic>[],
      };

  @override
  Future<PlaybackSource> playback(
      MediaItem item, PlaybackRequest request) async {
    if (item.kind.isAudio) {
      return PlaybackSource(
        url: '$_base/Audio/${item.id}/stream?static=true',
        headers: _authHeaders,
        method: PlayMethod.directPlay,
        sessionId: const Uuid().v4(),
        mediaSourceId: item.id,
      );
    }
    final original = request.maxBitrateKbps == null;
    final maxBitrate = original ? 400000000 : request.maxBitrateKbps! * 1000;
    final r = await _dio.post<Map<String, dynamic>>(
      '/Items/${item.id}/PlaybackInfo',
      queryParameters: {'userId': _uid},
      data: {
        'UserId': _uid,
        'DeviceProfile': _deviceProfile(maxBitrate),
        'MaxStreamingBitrate': maxBitrate,
        'MediaSourceId': ?request.versionId,
        if (request.audioStreamId != null)
          'AudioStreamIndex': int.tryParse(request.audioStreamId!),
        if (request.subtitleStreamId != null)
          'SubtitleStreamIndex': request.subtitleStreamId!.isEmpty
              ? -1
              : int.tryParse(request.subtitleStreamId!),
        'EnableDirectPlay': original,
        'EnableDirectStream': original,
        'EnableTranscoding': true,
        'AllowVideoStreamCopy': original,
        'AllowAudioStreamCopy': true,
        'AutoOpenLiveStream': true,
      },
    );
    final sources = (r.data?['MediaSources'] as List?) ?? const [];
    if (sources.isEmpty) {
      throw StateError('${r.data?['ErrorCode'] ?? 'The server offered no playable source'}');
    }
    final src = sources.first as Map<String, dynamic>;
    final version = _version(src);
    final session = '${r.data?['PlaySessionId'] ?? const Uuid().v4()}';
    final transcodeUrl = src['TranscodingUrl'] as String?;

    final String url;
    final PlayMethod method;
    if (original && asBool(src['SupportsDirectPlay'])) {
      url = '$_base/Videos/${item.id}/stream?static=true'
          '&mediaSourceId=${src['Id']}'
          '&deviceId=${Uri.encodeQueryComponent(ClientInfo.clientId)}'
          '&playSessionId=$session';
      method = PlayMethod.directPlay;
    } else if (transcodeUrl != null) {
      url = '$_base$transcodeUrl';
      method = original && asBool(src['SupportsDirectStream'])
          ? PlayMethod.directStream
          : PlayMethod.transcode;
    } else {
      throw StateError('The server could not prepare this file for playback');
    }
    return PlaybackSource(
      url: url,
      headers: _authHeaders,
      method: method,
      sessionId: session,
      version: version,
      mediaSourceId: '${src['Id']}',
      audioStreams: version.audio,
      subtitleStreams: version.subtitles,
    );
  }

  @override
  Future<void> reportProgress(MediaItem item, PlaybackSource source,
      Duration position, PlayState state) async {
    final body = {
      'ItemId': item.id,
      'MediaSourceId': source.mediaSourceId ?? item.id,
      'PlaySessionId': source.sessionId,
      'PositionTicks': position.inMicroseconds * 10,
      'IsPaused': state == PlayState.paused,
      'CanSeek': true,
      'PlayMethod': switch (source.method) {
        PlayMethod.directPlay => 'DirectPlay',
        PlayMethod.directStream => 'DirectStream',
        PlayMethod.transcode => 'Transcode',
      },
    };
    final path = switch (state) {
      PlayState.started => '/Sessions/Playing',
      PlayState.stopped => '/Sessions/Playing/Stopped',
      _ => '/Sessions/Playing/Progress',
    };
    await _dio.post<dynamic>(path, data: body);
  }

  @override
  Future<void> setPlayed(MediaItem item, bool played) => played
      ? _dio.post<dynamic>('/UserPlayedItems/${item.id}',
          queryParameters: {'userId': _uid})
      : _dio.delete<dynamic>('/UserPlayedItems/${item.id}',
          queryParameters: {'userId': _uid});

  // -- favorites stand in for a watchlist -----------------------------------

  @override
  bool get supportsWatchlist => true;

  @override
  String get watchlistName => 'Favorites';

  @override
  Future<List<MediaItem>> watchlist() => _scoped((parent) => _list('/Items', {
        'filters': 'IsFavorite',
        'recursive': true,
        'includeItemTypes': 'Movie,Series,Episode,MusicAlbum',
        'sortBy': 'DateCreated',
        'sortOrder': 'Descending',
        'limit': 200,
        'parentId': ?parent,
      }));

  // -- library scans --------------------------------------------------------

  @override
  bool get canScanLibraries => true;

  @override
  Future<void> scanLibrary(Library? library) async {
    try {
      if (library == null) {
        await _dio.post<dynamic>('/Library/Refresh');
      } else {
        await _dio.post<dynamic>('/Items/${library.id}/Refresh',
            queryParameters: {
              'recursive': true,
              'metadataRefreshMode': 'Default',
              'imageRefreshMode': 'Default',
              'replaceAllMetadata': false,
              'replaceAllImages': false,
            });
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        throw const BackendException(
            'Only a Jellyfin administrator can scan libraries.');
      }
      rethrow;
    }
  }

  @override
  Future<bool> isWatchlisted(MediaItem item) async => item.isFavorite;

  @override
  Future<void> setWatchlisted(MediaItem item, bool value) => value
      ? _dio.post<dynamic>('/UserFavoriteItems/${item.id}',
          queryParameters: {'userId': _uid})
      : _dio.delete<dynamic>('/UserFavoriteItems/${item.id}',
          queryParameters: {'userId': _uid});

  @override
  void dispose() => _dio.close();
}
