import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

/// Availability as Seerr reports it.
enum SeerrStatus {
  none('Not requested'),
  pending('Pending approval'),
  processing('Requested'),
  partial('Partially available'),
  available('Available');

  const SeerrStatus(this.label);
  final String label;

  static SeerrStatus of(Object? code) => switch (asInt(code)) {
        2 => pending,
        3 => processing,
        4 => partial,
        5 => available,
        _ => none,
      };
}

@immutable
class SeerrItem {
  const SeerrItem({
    required this.tmdbId,
    required this.isMovie,
    required this.title,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.year,
    this.rating,
    this.status = SeerrStatus.none,
    this.seasons = const [],
  });
  final int tmdbId;
  final bool isMovie;
  final String title;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final int? year;
  final double? rating;
  final SeerrStatus status;

  /// Season numbers (TV details only).
  final List<int> seasons;

  String get mediaType => isMovie ? 'movie' : 'tv';
  String? get poster =>
      posterPath == null ? null : 'https://image.tmdb.org/t/p/w342$posterPath';
  String? get backdrop => backdropPath == null
      ? null
      : 'https://image.tmdb.org/t/p/w780$backdropPath';

  static SeerrItem? parse(Map<String, dynamic> m) {
    final type = m['mediaType'] as String?;
    if (type != null && type != 'movie' && type != 'tv') return null;
    final isMovie = type == 'movie' || (type == null && m['title'] != null);
    final date = '${m['releaseDate'] ?? m['firstAirDate'] ?? ''}';
    return SeerrItem(
      tmdbId: asInt(m['id']) ?? 0,
      isMovie: isMovie,
      title: '${m['title'] ?? m['name'] ?? ''}',
      overview: m['overview'] as String?,
      posterPath: m['posterPath'] as String?,
      backdropPath: m['backdropPath'] as String?,
      year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
      rating: asDouble(m['voteAverage']),
      status: SeerrStatus.of((m['mediaInfo'] as Map?)?['status']),
      seasons: [
        for (final s in (m['seasons'] as List?) ?? const [])
          if ((asInt((s as Map)['seasonNumber']) ?? 0) > 0)
            asInt(s['seasonNumber'])!,
      ],
    );
  }
}

@immutable
class SeerrRequest {
  const SeerrRequest({
    required this.id,
    required this.tmdbId,
    required this.isMovie,
    required this.approval,
    required this.mediaStatus,
    this.requestedBy,
    this.createdAt,
  });
  final int id;
  final int tmdbId;
  final bool isMovie;

  /// 1 pending, 2 approved, 3 declined.
  final int approval;
  final SeerrStatus mediaStatus;
  final String? requestedBy;
  final DateTime? createdAt;

  String get statusLabel => switch (approval) {
        1 => 'Pending approval',
        3 => 'Declined',
        _ => mediaStatus == SeerrStatus.none
            ? 'Approved'
            : mediaStatus.label,
      };
}

/// Client for Seerr and its ancestors Overseerr and Jellyseerr, which all
/// share the same `/api/v1` surface.
class SeerrClient {
  SeerrClient(String baseUrl, {String? apiKey, String? cookie})
      : _dio = Dio(BaseOptions(
          baseUrl: '${_trim(baseUrl)}/api/v1',
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 20),
          headers: {
            'Accept': 'application/json',
            if (apiKey != null && apiKey.isNotEmpty) 'X-Api-Key': apiKey,
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          },
        ));

  final Dio _dio;

  static String _trim(String s) {
    var out = s.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    if (!out.contains('://')) out = 'http://$out';
    return out;
  }

  /// Signs in and returns the session cookie to store. [mode] is one of
  /// 'local' (email + password), 'jellyfin' (username + password) or
  /// 'plex' (password carries the plex.tv token).
  static Future<String> signIn(String baseUrl,
      {required String mode, String? user, required String secret}) async {
    final dio = Dio(BaseOptions(
      baseUrl: '${_trim(baseUrl)}/api/v1',
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ));
    final r = await dio.post<dynamic>('/auth/$mode',
        data: switch (mode) {
          'plex' => {'authToken': secret},
          'jellyfin' => {'username': user, 'password': secret},
          _ => {'email': user, 'password': secret},
        });
    final cookies = r.headers.map['set-cookie'] ?? const [];
    final session = cookies
        .map((c) => c.split(';').first)
        .where((c) => c.startsWith('connect.sid='))
        .firstOrNull;
    if (session == null) throw StateError('Sign-in did not return a session');
    return session;
  }

  Future<String> whoAmI() async {
    final r = await _dio.get<Map<String, dynamic>>('/auth/me');
    final d = r.data ?? const {};
    return '${d['displayName'] ?? d['username'] ?? d['email'] ?? 'Signed in'}';
  }

  Future<List<SeerrItem>> _results(String path,
      [Map<String, dynamic>? query]) async {
    final r = await _dio.get<Map<String, dynamic>>(path,
        queryParameters: {'page': 1, ...?query});
    return [
      for (final m in (r.data?['results'] as List?) ?? const [])
        ?SeerrItem.parse(m as Map<String, dynamic>),
    ];
  }

  Future<List<SeerrItem>> trending() => _results('/discover/trending');
  Future<List<SeerrItem>> popularMovies() => _results('/discover/movies');
  Future<List<SeerrItem>> popularShows() => _results('/discover/tv');
  Future<List<SeerrItem>> upcomingMovies() =>
      _results('/discover/movies/upcoming');
  Future<List<SeerrItem>> upcomingShows() => _results('/discover/tv/upcoming');
  Future<List<SeerrItem>> search(String query) =>
      _results('/search', {'query': query});

  Future<SeerrItem> details(String mediaType, int tmdbId) async {
    final r = await _dio.get<Map<String, dynamic>>('/$mediaType/$tmdbId');
    return SeerrItem.parse({...r.data!, 'mediaType': mediaType})!;
  }

  /// [seasons] is ignored for movies; empty means every season.
  Future<void> request(SeerrItem item, {List<int> seasons = const []}) =>
      _dio.post<dynamic>('/request', data: {
        'mediaType': item.mediaType,
        'mediaId': item.tmdbId,
        if (!item.isMovie) 'seasons': seasons.isEmpty ? 'all' : seasons,
      });

  Future<List<SeerrRequest>> requests() async {
    final r = await _dio.get<Map<String, dynamic>>('/request',
        queryParameters: {'take': 40, 'skip': 0, 'sort': 'added'});
    return [
      for (final raw in (r.data?['results'] as List?) ?? const [])
        _request(raw as Map<String, dynamic>),
    ];
  }

  SeerrRequest _request(Map<String, dynamic> m) {
    final media = (m['media'] as Map?) ?? const {};
    final by = (m['requestedBy'] as Map?) ?? const {};
    return SeerrRequest(
      id: asInt(m['id']) ?? 0,
      tmdbId: asInt(media['tmdbId']) ?? 0,
      isMovie: (m['type'] ?? media['mediaType']) == 'movie',
      approval: asInt(m['status']) ?? 1,
      mediaStatus: SeerrStatus.of(media['status']),
      requestedBy: (by['displayName'] ?? by['username']) as String?,
      createdAt: DateTime.tryParse('${m['createdAt']}'),
    );
  }

  void close() => _dio.close();
}
