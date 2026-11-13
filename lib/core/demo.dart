import 'backend.dart';
import 'models.dart';

/// An offline-generated library so the app can be explored without a server.
/// Artwork comes from picsum.photos; playback uses public test streams.
class DemoBackend extends MediaBackend {
  DemoBackend(this.config) {
    if (_movies.isEmpty) _build();
  }

  @override
  final ServerConfig config;

  static const demoId = 'demo';
  static const _video = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
  static const _audio =
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3';

  static final _movies = <MediaItem>[];
  static final _shows = <MediaItem>[];
  static final _seasons = <String, List<MediaItem>>{};
  static final _episodes = <String, List<MediaItem>>{};
  static final _albums = <MediaItem>[];
  static final _tracks = <String, List<MediaItem>>{};
  static final _progress = <String, Duration>{};
  static final _played = <String>{};
  static final _favorites = <String>{'m2', 's1'};

  static ImageRef _pic(String seed) =>
      ImageRef('https://picsum.photos/seed/marquee-$seed/{w}/{h}');

  static const _movieTitles = [
    'The Long Tide', 'Paper Lanterns', 'North of Nowhere', 'Static Bloom',
    'A Quiet Orbit', 'Saltwater Kings', 'The Glass Orchard', 'Night Ferry',
    'Low Sun', 'Harbor Lights', 'Thirteen Winters', 'Copper Sky',
    'The Cartographer', 'Small Hours', 'Wild Meridian', 'Second Violin',
    'Ember & Ash', 'The Last Arcade', 'Blue Hour', 'Field Notes',
  ];
  static const _showTitles = [
    'Signal Fire', 'The Understory', 'Kitchen Table', 'Outer Banks Radio',
    'Lowlands', 'Tin Roof', 'Parallel Lines', 'The Lighthouse Keepers',
  ];
  static const _albumTitles = [
    ('Slow Weather', 'Mara Quill'), ('Night Bus Home', 'The Paper Kites Club'),
    ('Tidal', 'Osei'), ('Rooms', 'Hollow Pine'),
    ('Neon Garden', 'Vela'), ('First Light', 'Anders & June'),
  ];
  static const _genres = ['Drama', 'Sci-Fi', 'Comedy', 'Thriller', 'Adventure'];
  static const _blurb =
      'A demo title. Connect a Plex or Jellyfin server in Settings to see '
      'your own library here, with artwork, progress and playback.';

  void _build() {
    final now = DateTime.now();
    for (var i = 0; i < _movieTitles.length; i++) {
      final uhd = i % 3 == 0;
      _movies.add(MediaItem(
        serverId: serverId,
        id: 'm$i',
        kind: MediaKind.movie,
        title: _movieTitles[i],
        overview: _blurb,
        tagline: i.isEven ? 'Every story starts somewhere.' : null,
        year: 2026 - i % 9,
        duration: Duration(minutes: 92 + (i * 7) % 50),
        contentRating: const ['PG', 'PG-13', 'R'][i % 3],
        rating: 6.1 + (i * 37 % 30) / 10,
        genres: [_genres[i % 5], _genres[(i + 2) % 5]],
        poster: _pic('mp$i'),
        thumb: _pic('mb$i'),
        backdrop: _pic('mb$i'),
        addedAt: now.subtract(Duration(days: i * 3)),
        people: [
          for (var p = 0; p < 6; p++)
            Person(name: 'Cast Member ${p + 1}', role: 'Character ${p + 1}'),
        ],
        chapters: [
          for (var c = 0; c < 6; c++)
            Chapter(title: 'Chapter ${c + 1}', start: Duration(minutes: c * 2)),
        ],
        versions: [
          MediaVersion(
            id: 'm$i-v',
            container: 'mkv',
            videoCodec: uhd ? 'hevc' : 'h264',
            audioCodec: 'eac3',
            width: uhd ? 3840 : 1920,
            height: uhd ? 2160 : 1080,
            bitrateKbps: uhd ? 42000 : 9500,
            audioChannels: uhd ? 8 : 6,
            hdr: uhd ? (i % 6 == 0 ? 'DV' : 'HDR10') : null,
          ),
        ],
        externalIds: const {},
      ));
    }
    _progress['m1'] = const Duration(minutes: 34);
    _progress['m4'] = const Duration(minutes: 71);
    _played.addAll(['m7', 'm9']);

    for (var s = 0; s < _showTitles.length; s++) {
      final showId = 's$s';
      final seasons = <MediaItem>[];
      for (var n = 1; n <= 2 + s % 2; n++) {
        final seasonId = '$showId-$n';
        seasons.add(MediaItem(
          serverId: serverId,
          id: seasonId,
          kind: MediaKind.season,
          title: 'Season $n',
          index: n,
          parentId: showId,
          parentTitle: _showTitles[s],
          grandparentTitle: _showTitles[s],
          poster: _pic('sp$s-$n'),
          backdrop: _pic('sb$s'),
          childCount: 6,
          unplayedCount: 6,
        ));
        _episodes[seasonId] = [
          for (var e = 1; e <= 6; e++)
            MediaItem(
              serverId: serverId,
              id: '$seasonId-$e',
              kind: MediaKind.episode,
              title: 'Episode $e',
              overview: _blurb,
              index: e,
              parentIndex: n,
              parentId: seasonId,
              grandparentId: showId,
              parentTitle: 'Season $n',
              grandparentTitle: _showTitles[s],
              duration: Duration(minutes: 42 + e),
              poster: _pic('sp$s'),
              thumb: _pic('se$s-$n-$e'),
              backdrop: _pic('sb$s'),
              markers: const [
                Marker(
                    type: MarkerType.intro,
                    start: Duration(seconds: 20),
                    end: Duration(seconds: 50)),
              ],
              versions: const [
                MediaVersion(
                    id: 'v',
                    videoCodec: 'h264',
                    width: 1920,
                    height: 1080,
                    bitrateKbps: 6000,
                    audioChannels: 6),
              ],
            ),
        ];
      }
      _seasons[showId] = seasons;
      _shows.add(MediaItem(
        serverId: serverId,
        id: showId,
        kind: MediaKind.show,
        title: _showTitles[s],
        overview: _blurb,
        year: 2020 + s % 6,
        contentRating: 'TV-14',
        rating: 7.0 + s % 3 * 0.7,
        genres: [_genres[(s + 1) % 5]],
        poster: _pic('sp$s'),
        thumb: _pic('sb$s'),
        backdrop: _pic('sb$s'),
        childCount: seasons.length,
        unplayedCount: seasons.length * 6,
        addedAt: now.subtract(Duration(days: s * 4 + 1)),
      ));
    }
    _progress['s0-1-3'] = const Duration(minutes: 12);
    _played.addAll(['s0-1-1', 's0-1-2', 's2-1-1']);

    for (var a = 0; a < _albumTitles.length; a++) {
      final (title, artist) = _albumTitles[a];
      final id = 'a$a';
      _albums.add(MediaItem(
        serverId: serverId,
        id: id,
        kind: MediaKind.album,
        title: title,
        parentTitle: artist,
        year: 2019 + a,
        poster: _pic('al$a'),
        childCount: 8,
        addedAt: now.subtract(Duration(days: a * 6)),
      ));
      _tracks[id] = [
        for (var t = 1; t <= 8; t++)
          MediaItem(
            serverId: serverId,
            id: '$id-$t',
            kind: MediaKind.track,
            title: 'Track $t',
            index: t,
            parentId: id,
            parentTitle: title,
            grandparentTitle: artist,
            duration: Duration(minutes: 3, seconds: t * 7),
            poster: _pic('al$a'),
          ),
      ];
    }
  }

  MediaItem _live(MediaItem i) {
    var unplayed = i.unplayedCount;
    var played = _played.contains(i.id);
    if (i.kind == MediaKind.season) {
      final eps = _episodes[i.id] ?? const [];
      unplayed = eps.where((e) => !_played.contains(e.id)).length;
      played = unplayed == 0;
    } else if (i.kind == MediaKind.show) {
      final eps = (_seasons[i.id] ?? const [])
          .expand((s) => _episodes[s.id] ?? const <MediaItem>[]);
      unplayed = eps.where((e) => !_played.contains(e.id)).length;
      played = unplayed == 0;
    }
    return MediaItem(
      serverId: i.serverId,
      id: i.id,
      kind: i.kind,
      title: i.title,
      overview: i.overview,
      tagline: i.tagline,
      year: i.year,
      duration: i.duration,
      viewOffset: _progress[i.id] ?? Duration.zero,
      played: played,
      unplayedCount: unplayed,
      childCount: i.childCount,
      poster: i.poster,
      thumb: i.thumb,
      backdrop: i.backdrop,
      parentId: i.parentId,
      grandparentId: i.grandparentId,
      parentTitle: i.parentTitle,
      grandparentTitle: i.grandparentTitle,
      index: i.index,
      parentIndex: i.parentIndex,
      contentRating: i.contentRating,
      rating: i.rating,
      genres: i.genres,
      people: i.people,
      addedAt: i.addedAt,
      versions: i.versions,
      chapters: i.chapters,
      markers: i.markers,
      isFavorite: _favorites.contains(i.id),
      libraryId: switch (i.kind) {
        MediaKind.movie => 'movies',
        MediaKind.show || MediaKind.season || MediaKind.episode => 'shows',
        MediaKind.artist || MediaKind.album || MediaKind.track => 'music',
        _ => null,
      },
    );
  }

  List<MediaItem> _liveAll(Iterable<MediaItem> l) => l.map(_live).toList();

  Iterable<MediaItem> get _allEpisodes => _episodes.values.expand((e) => e);
  Iterable<MediaItem> get _everything => [
        ..._movies,
        ..._shows,
        ..._seasons.values.expand((e) => e),
        ..._allEpisodes,
        ..._albums,
        ..._tracks.values.expand((e) => e),
      ];

  static const _collection = MediaItem(
      serverId: demoId,
      id: 'c0',
      kind: MediaKind.collection,
      title: 'Staff Picks',
      childCount: 6);
  static const _playlist = MediaItem(
      serverId: demoId,
      id: 'p0',
      kind: MediaKind.playlist,
      title: 'Friday Night',
      childCount: 5);

  @override
  Future<List<Library>> libraries() async => [
        Library(
            serverId: serverId,
            id: 'movies',
            title: 'Movies',
            kind: LibraryKind.movies,
            art: _pic('mb2')),
        Library(
            serverId: serverId,
            id: 'shows',
            title: 'TV Shows',
            kind: LibraryKind.shows,
            art: _pic('sb1')),
        Library(
            serverId: serverId,
            id: 'music',
            title: 'Music',
            kind: LibraryKind.music,
            art: _pic('al1')),
      ];

  @override
  Future<List<MediaItem>> continueWatching() async => _liveAll(_everything
      .where((i) => _progress.containsKey(i.id) && !_played.contains(i.id)));

  @override
  Future<List<MediaItem>> nextUp() async {
    final out = <MediaItem>[];
    for (final show in _shows) {
      final eps = (_seasons[show.id] ?? const [])
          .expand((s) => _episodes[s.id] ?? const <MediaItem>[])
          .toList();
      final watched = eps.lastIndexWhere((e) => _played.contains(e.id));
      if (watched >= 0 &&
          watched + 1 < eps.length &&
          !_progress.containsKey(eps[watched + 1].id)) {
        out.add(eps[watched + 1]);
      }
    }
    return _liveAll(out);
  }

  List<MediaItem> _of(Library l) => switch (l.kind) {
        LibraryKind.movies => _movies,
        LibraryKind.shows => _shows,
        _ => _albums,
      };

  @override
  Future<List<MediaItem>> recentlyAdded(Library library,
          {int limit = 20}) async =>
      _liveAll(_of(library).take(limit));

  @override
  Future<Paged> libraryItems(
    Library library, {
    int start = 0,
    int limit = 60,
    LibraryQuery query = const LibraryQuery(),
  }) async {
    var list = _liveAll(_of(library));
    if (query.unwatchedOnly) list = list.where((i) => !i.played).toList();
    int cmp(MediaItem a, MediaItem b) => switch (query.sort) {
          SortField.title => a.title.compareTo(b.title),
          SortField.added => (a.addedAt ?? DateTime(0))
              .compareTo(b.addedAt ?? DateTime(0)),
          SortField.released => (a.year ?? 0).compareTo(b.year ?? 0),
          SortField.rating => (a.rating ?? 0).compareTo(b.rating ?? 0),
        };
    list.sort(query.descending ? (a, b) => cmp(b, a) : cmp);
    return Paged(list.skip(start).take(limit).toList(), list.length);
  }

  @override
  Future<List<MediaItem>> collections(Library? library) async =>
      library == null || library.kind == LibraryKind.movies
          ? [_collection]
          : const [];

  @override
  Future<List<MediaItem>> playlists() async => [_playlist];

  @override
  Future<List<MediaItem>> folders(Library library) async => [
        MediaItem(
            serverId: serverId,
            id: 'f-${library.id}',
            kind: MediaKind.folder,
            title: '${library.title} (A–M)'),
      ];

  @override
  Future<List<MediaItem>> children(MediaItem parent) async =>
      _liveAll(switch (parent.kind) {
        MediaKind.show => _seasons[parent.id] ?? const [],
        MediaKind.season => _episodes[parent.id] ?? const [],
        MediaKind.album => _tracks[parent.id] ?? const [],
        MediaKind.collection => _movies.take(6),
        MediaKind.playlist => [..._movies.skip(8).take(3), ..._allEpisodes.take(2)],
        MediaKind.folder => parent.id == 'f-shows'
            ? _shows.take(4)
            : parent.id == 'f-music'
                ? _albums.take(3)
                : _movies.take(10),
        _ => const <MediaItem>[],
      });

  @override
  Future<MediaItem> item(String id, {MediaKind? kind}) async {
    if (id == _collection.id) return _collection;
    if (id == _playlist.id) return _playlist;
    if (id.startsWith('f-')) {
      return MediaItem(
          serverId: serverId, id: id, kind: MediaKind.folder, title: 'Folder');
    }
    return _live(_everything.firstWhere((i) => i.id == id));
  }

  @override
  Future<List<MediaItem>> similar(MediaItem item) async => _liveAll(
      (item.kind == MediaKind.show ? _shows : _movies)
          .where((i) => i.id != item.id)
          .take(10));

  @override
  Future<List<Shelf>> discover() async => [
        Shelf('Top rated movies',
            _liveAll([..._movies]..sort((a, b) => b.rating!.compareTo(a.rating!)))),
        Shelf('Shows you might like', _liveAll(_shows.reversed)),
      ];

  @override
  Future<List<Shelf>> recommended(Library library) async {
    final shows = library.kind == LibraryKind.shows;
    final pool = _liveAll(_of(library));
    final inProgress = _liveAll(_everything.where((i) =>
        _progress.containsKey(i.id) &&
        !_played.contains(i.id) &&
        (shows ? i.kind == MediaKind.episode : i.kind == MediaKind.movie)));
    final genre = _genres[1];
    return [
      Shelf('Continue watching', inProgress, landscape: true),
      if (shows) Shelf('Next up', await nextUp(), landscape: true),
      Shelf('Recently added', pool.take(12).toList()),
      Shelf(shows ? 'Top rated shows' : 'Top rated movies',
          [...pool]..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0))),
      if (!shows)
        Shelf('More $genre',
            pool.where((i) => i.genres.contains(genre)).toList()),
    ].where((s) => s.items.isNotEmpty).toList();
  }

  @override
  Future<List<MediaItem>> search(String query) async {
    final q = query.toLowerCase();
    return _liveAll([..._movies, ..._shows, ..._albums].where((i) =>
        i.title.toLowerCase().contains(q) ||
        (i.parentTitle ?? '').toLowerCase().contains(q)));
  }

  @override
  Future<MediaItem?> nextEpisode(MediaItem episode) async {
    final eps = (_seasons[episode.grandparentId] ?? const [])
        .expand((s) => _episodes[s.id] ?? const <MediaItem>[])
        .toList();
    final i = eps.indexWhere((e) => e.id == episode.id);
    return (i < 0 || i + 1 >= eps.length) ? null : _live(eps[i + 1]);
  }

  @override
  Future<List<Marker>> markers(MediaItem item) async => item.markers;

  @override
  Future<PlaybackSource> playback(
          MediaItem item, PlaybackRequest request) async =>
      PlaybackSource(
        url: item.kind.isAudio ? _audio : _video,
        method: request.maxBitrateKbps == null
            ? PlayMethod.directPlay
            : PlayMethod.transcode,
        sessionId: 'demo',
        version: item.versions.firstOrNull,
      );

  @override
  Future<void> reportProgress(MediaItem item, PlaybackSource source,
      Duration position, PlayState state) async {
    final total = item.duration ?? Duration.zero;
    if (total > Duration.zero && position.inSeconds > total.inSeconds * 0.9) {
      _played.add(item.id);
      _progress.remove(item.id);
    } else if (position > const Duration(seconds: 10)) {
      _progress[item.id] = position;
    }
  }

  @override
  Future<void> setPlayed(MediaItem item, bool played) async {
    final ids = switch (item.kind) {
      MediaKind.show => (_seasons[item.id] ?? const <MediaItem>[])
          .expand((s) => _episodes[s.id] ?? const <MediaItem>[])
          .map((e) => e.id),
      MediaKind.season =>
        (_episodes[item.id] ?? const <MediaItem>[]).map((e) => e.id),
      _ => [item.id],
    };
    for (final id in ids) {
      played ? _played.add(id) : _played.remove(id);
      _progress.remove(id);
    }
  }

  @override
  bool get supportsWatchlist => true;

  @override
  String get watchlistName => 'Watchlist';

  @override
  Future<List<MediaItem>> watchlist() async =>
      _liveAll(_everything.where((i) => _favorites.contains(i.id)));

  @override
  Future<bool> isWatchlisted(MediaItem item) async =>
      _favorites.contains(item.id);

  @override
  Future<void> setWatchlisted(MediaItem item, bool value) async =>
      value ? _favorites.add(item.id) : _favorites.remove(item.id);
}
