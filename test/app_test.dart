import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marquee/app.dart';
import 'package:marquee/core/backend.dart';
import 'package:marquee/core/demo.dart';
import 'package:marquee/core/jellyfin.dart';
import 'package:marquee/core/models.dart';
import 'package:marquee/core/plex.dart';
import 'package:marquee/core/providers.dart';
import 'package:marquee/core/storage.dart';
import 'package:marquee/ui/add_server_screen.dart';
import 'package:marquee/ui/libraries_screen.dart';
import 'package:marquee/ui/player/player_widgets.dart';
import 'package:marquee/ui/widgets.dart';

Future<AppStorage> _storage({bool demo = true}) async {
  final storage = AppStorage(MemoryStore());
  await storage.load();
  if (demo) await storage.saveServers(const [demoServer]);
  return storage;
}

Future<void> _pump(WidgetTester tester, Size size,
    {bool tv = false, bool demo = true}) async {
  Artwork.network = false;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final storage = await _storage(demo: demo);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      storageProvider.overrideWithValue(storage),
      deviceIsTvProvider.overrideWithValue(tv),
    ],
    retry: (_, _) => null,
    child: const MarqueeApp(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  const sizes = {
    'phone': (Size(390, 844), false),
    'tablet': (Size(900, 1200), false),
    'desktop': (Size(1440, 900), false),
    'tv': (Size(1920, 1080), true),
  };

  for (final MapEntry(key: name, value: (size, tv)) in sizes.entries) {
    testWidgets('home, detail and tabs lay out on $name', (tester) async {
      await _pump(tester, size, tv: tv);
      expect(find.text('Continue watching'), findsOneWidget);
      expect(find.text('CONTINUE WATCHING'), findsOneWidget);
      // Shelves further down are built lazily: scroll to one, then back.
      final page = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('New in Movies'), 250,
          scrollable: page);
      expect(find.text('New in Movies'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Details'), -250,
          scrollable: page);
      await tester.pumpAndSettle();

      // Hero → details for the item in progress.
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Resume'), findsOneWidget);
      expect(find.text('Cast & crew'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      for (final tab in ['Libraries', 'Search', 'Explore', 'Settings']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
      }
      expect(find.text('Video quality'), findsOneWidget);
    });
  }

  testWidgets('show page lists seasons and episodes', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Libraries').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('TV Shows'));
    await tester.pumpAndSettle();
    // TV libraries open on Recommended; the show grid is under All.
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Signal Fire'));
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('3. Episode 3'), findsOneWidget);
    expect(find.text('Shuffle'), findsOneWidget);
  });

  testWidgets('playlist page offers Play and Shuffle', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Libraries').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Friday Night'));
    await tester.pumpAndSettle();
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Shuffle'), findsOneWidget);
  });

  testWidgets('search finds demo titles across kinds', (tester) async {
    await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Search').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'tide');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('The Long Tide'), findsOneWidget);
  });

  testWidgets('first run shows the welcome screen', (tester) async {
    await _pump(tester, const Size(390, 844), demo: false);
    expect(find.text('Connect Plex'), findsOneWidget);
    expect(find.text('Connect Jellyfin'), findsOneWidget);
    await tester.tap(find.text('Look around with a demo library'));
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget);
  });

  test('Plex metadata maps to the shared model', () {
    final backend = PlexBackend(const ServerConfig(
        id: 'p', kind: ServerKind.plex, name: 'P', baseUrl: 'http://h:32400',
        token: 't'));
    final item = backend.parse({
      'ratingKey': '42',
      'type': 'episode',
      'title': 'Pilot',
      'grandparentTitle': 'Show',
      'grandparentRatingKey': '7',
      'parentRatingKey': '8',
      'index': 1,
      'parentIndex': 2,
      'duration': 3600000,
      'viewOffset': 900000,
      'thumb': '/library/metadata/42/thumb/1',
      'guid': 'plex://episode/abc',
      'Guid': [
        {'id': 'tmdb://123'}
      ],
      'Media': [
        {
          'id': 1,
          'videoResolution': '4k',
          'videoCodec': 'hevc',
          'audioChannels': 6,
          'bitrate': 40000,
          'Part': [
            {
              'id': 5,
              'key': '/library/parts/5/file.mkv',
              'Stream': [
                {'id': 1, 'streamType': 1, 'colorTrc': 'smpte2084'},
                {'id': 2, 'streamType': 2, 'languageCode': 'eng', 'selected': true},
                {'id': 3, 'streamType': 3, 'languageCode': 'spa', 'key': '/library/streams/3'},
              ],
            }
          ],
        }
      ],
      'Marker': [
        {'type': 'intro', 'startTimeOffset': 5000, 'endTimeOffset': 65000}
      ],
    });
    expect(item.kind, MediaKind.episode);
    expect(item.episodeCode, 'S2 · E1');
    expect(item.progress, 0.25);
    expect(item.externalIds, {'plex': 'plex://episode/abc', 'tmdb': '123'});
    final v = item.versions.single;
    expect(v.resolution, '4K');
    expect(v.hdr, 'HDR10');
    expect(v.subtitles.single.url,
        'http://h:32400/library/streams/3?X-Plex-Token=t');
    expect(item.markers.single.end, const Duration(seconds: 65));
    expect(item.thumb!.url(300, aspect: 16 / 9), contains('width=320&height=180'));
  });

  test('Jellyfin items map to the shared model', () {
    final backend = JellyfinBackend(const ServerConfig(
        id: 'j', kind: ServerKind.jellyfin, name: 'J', baseUrl: 'http://h:8096',
        token: 't', userId: 'u'));
    final item = backend.parse({
      'Id': 'e1',
      'Type': 'Episode',
      'Name': 'Pilot',
      'SeriesId': 's1',
      'SeriesName': 'Show',
      'SeasonId': 'se1',
      'IndexNumber': 3,
      'ParentIndexNumber': 1,
      'RunTimeTicks': 36000000000,
      'UserData': {'PlaybackPositionTicks': 18000000000, 'IsFavorite': true},
      'ImageTags': {'Primary': 'abc'},
      'ProviderIds': {'Tmdb': '99'},
      'Chapters': [
        {'StartPositionTicks': 600000000, 'Name': 'Cold open'}
      ],
      'MediaSources': [
        {
          'Id': 'e1',
          'Container': 'mkv',
          'Bitrate': 8000000,
          'MediaStreams': [
            {'Index': 0, 'Type': 'Video', 'Codec': 'h264', 'Width': 1920, 'Height': 1080, 'VideoRangeType': 'SDR'},
            {'Index': 1, 'Type': 'Audio', 'Codec': 'aac', 'Channels': 2, 'Language': 'eng'},
          ],
        }
      ],
    });
    expect(item.kind, MediaKind.episode);
    expect(item.duration, const Duration(hours: 1));
    expect(item.progress, 0.5);
    expect(item.isFavorite, isTrue);
    expect(item.grandparentId, 's1');
    expect(item.chapters.single.start, const Duration(minutes: 1));
    expect(item.versions.single.resolution, '1080p');
    expect(item.versions.single.bitrateKbps, 8000);
    expect(item.poster!.url(200), 'http://h:8096/Items/s1/Images/Primary?fillWidth=240&quality=90');
  });

  test('language preferences match loosely', () {
    expect(languageMatches('eng', 'en'), isTrue);
    expect(languageMatches('eng', 'en-US'), isTrue);
    expect(languageMatches('fra', 'fre'), isTrue);
    expect(languageMatches('spa', 'eng'), isFalse);
  });

  test('settings and servers round-trip through storage', () async {
    final store = MemoryStore();
    final a = AppStorage(store);
    await a.load();
    await a.saveServers(const [
      ServerConfig(id: 'x', kind: ServerKind.plex, name: 'X',
          baseUrl: 'http://x', token: 'secret', accountToken: 'acct'),
    ]);
    await a.saveSettings(
        const AppSettings(maxBitrateKbps: 8000, seerrApiKey: 'k', seerrUrl: 'u'));
    final b = AppStorage(store);
    await b.load();
    expect(b.clientId, a.clientId);
    expect(b.servers.single.token, 'secret');
    expect(b.servers.single.accountToken, 'acct');
    expect(b.settings.maxBitrateKbps, 8000);
    expect(b.settings.hasSeerr, isTrue);
    // Tokens never land in the plain server list.
    expect(await store.read('servers'), isNot(contains('secret')));
    expect(DemoBackend.demoId, 'demo');
  });

  test('Plex Home profile survives storage and keeps tokens secret', () async {
    final store = MemoryStore();
    final a = AppStorage(store);
    await a.load();
    await a.saveServers(const [
      ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
          baseUrl: 'http://p', token: 'srv', accountToken: 'kid-token',
          homeToken: 'home-token', userId: 'u2', userName: 'Kid',
          userThumb: 'https://plex.tv/kid.png'),
    ]);
    final b = AppStorage(store);
    await b.load();
    final s = b.servers.single;
    expect(s.accountToken, 'kid-token');
    expect(s.homeToken, 'home-token');
    expect(s.userId, 'u2');
    expect(s.userName, 'Kid');
    expect(s.userThumb, 'https://plex.tv/kid.png');
    final plain = await store.read('servers');
    expect(plain, isNot(contains('home-token')));
    expect(plain, isNot(contains('kid-token')));
  });

  test('servers saved before profiles existed treat the account as home', () {
    final s = ServerConfig.fromJson(
      {'id': 'p', 'kind': 'plex', 'name': 'P', 'baseUrl': 'http://p'},
      {'token': 't', 'accountToken': 'acct'},
    );
    expect(s.homeToken, 'acct');
  });

  test('ServerConfig.copyWith keeps unspecified fields', () {
    const s = ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
        baseUrl: 'http://p', token: 't', homeToken: 'h',
        userThumb: 'thumb', connections: ['http://a', 'http://b']);
    final moved = s.copyWith(baseUrl: 'http://b');
    expect(moved.baseUrl, 'http://b');
    expect(moved.token, 't');
    expect(moved.homeToken, 'h');
    expect(moved.userThumb, 'thumb');
    expect(moved.connections, ['http://a', 'http://b']);
    // A profile without a picture clears the previous one.
    expect(s.copyWith(userThumb: null).userThumb, isNull);
  });

  test('Plex Home users parse from plex.tv', () {
    final admin = PlexHomeUser.parse({
      'uuid': 'a1', 'title': 'Alex', 'username': 'alex42',
      'thumb': 'https://plex.tv/a.png', 'admin': true, 'protected': true,
    });
    expect(admin.uuid, 'a1');
    expect(admin.name, 'Alex');
    expect(admin.subtitle, 'Admin');
    expect(admin.protected, isTrue);

    final kid = PlexHomeUser.parse({
      'id': 7, 'title': '  ', 'friendlyName': 'Kiddo', 'thumb': '',
      'restricted': 1,
    });
    expect(kid.uuid, '7');
    expect(kid.name, 'Kiddo');
    expect(kid.thumb, isNull);
    expect(kid.subtitle, 'Managed profile');
    expect(PlexHomeUser.parse(const {}).name, 'Plex user');
  });

  test('hidden libraries round-trip and empty servers are dropped', () async {
    final store = MemoryStore();
    final a = AppStorage(store);
    await a.load();
    var settings = const AppSettings()
        .withLibraryHidden('srv', '1', true)
        .withLibraryHidden('srv', '2', true)
        .withLibraryHidden('other', '9', true)
        .withLibraryHidden('other', '9', false);
    expect(settings.hiddenLibraries, {'srv': {'1', '2'}});
    await a.saveSettings(settings);
    final b = AppStorage(store);
    await b.load();
    settings = b.settings;
    expect(settings.isHidden('srv', '1'), isTrue);
    expect(settings.isHidden('srv', '3'), isFalse);
    expect(settings.hiddenOn('other'), isEmpty);
  });

  test('Plex items know their library', () {
    final backend = PlexBackend(const ServerConfig(
        id: 'p', kind: ServerKind.plex, name: 'P', baseUrl: 'http://h',
        token: 't'))
      ..hiddenLibraries = {'2'};
    final a = backend.parse(
        {'ratingKey': '1', 'type': 'movie', 'title': 'A', 'librarySectionID': 1});
    final b = backend.parse(
        {'ratingKey': '2', 'type': 'movie', 'title': 'B', 'librarySectionID': 2});
    final c = backend.parse({'ratingKey': '3', 'type': 'movie', 'title': 'C'});
    expect(a.libraryId, '1');
    expect(backend.visible([a, b, c]).map((i) => i.title), ['A', 'C']);
  });

  test('a hidden library disappears from libraries, shelves and search',
      () async {
    final container = ProviderContainer(overrides: [
      storageProvider.overrideWithValue(await _storage()),
    ]);
    addTearDown(container.dispose);
    const demo = DemoBackend.demoId;

    container.read(settingsProvider.notifier)
        .setLibraryHidden(demo, 'movies', true);

    final libs = await container.read(librariesProvider(demo).future);
    expect(libs.map((l) => l.id), ['shows', 'music']);
    final all = await container.read(allLibrariesProvider(demo).future);
    expect(all, hasLength(3));

    final sub = container.listen(searchProvider('the long tide'), (_, _) {});
    final found = await container.read(searchProvider('the long tide').future);
    expect(found, isEmpty);
    sub.close();

    final discover = await container.read(discoverProvider.future);
    expect(discover.expand((s) => s.items).where((i) => i.kind == MediaKind.movie),
        isEmpty);

    container.read(settingsProvider.notifier)
        .setLibraryHidden(demo, 'movies', false);
    expect(await container.read(librariesProvider(demo).future), hasLength(3));
  });

  testWidgets('settings lists libraries and hides one across the app',
      (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('3 of 3 shown'), findsOneWidget);
    await tester.tap(find.text('Libraries').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('TV Shows'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 shown'), findsOneWidget);
    expect(find.text('Hidden'), findsOneWidget);

    await tester.tap(find.text('Libraries').first); // the nav tab
    await tester.pumpAndSettle();
    expect(find.text('Movies'), findsWidgets);
    expect(find.text('TV Shows'), findsNothing);
  });

  test('Jellyfin scopes queries to visible libraries when some are hidden',
      () async {
    final calls = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls.add('${o.path}?parentId=${o.queryParameters['parentId']}');
        final data = switch (o.path) {
          '/UserViews' => {
              'Items': [
                {'Id': 'movies', 'Name': 'Movies', 'CollectionType': 'movies'},
                {'Id': 'kids', 'Name': 'Kids', 'CollectionType': 'movies'},
                {'Id': 'tunes', 'Name': 'Music', 'CollectionType': 'music'},
              ]
            },
          _ => {
              'Items': [
                {'Id': 'x-${o.queryParameters['parentId']}', 'Type': 'Movie',
                 'Name': 'X'},
              ]
            },
        };
        h.resolve(Response(requestOptions: o, data: data, statusCode: 200));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);

    await jf.continueWatching();
    expect(calls, ['/UserItems/Resume?parentId=null']);

    calls.clear();
    jf.hiddenLibraries = {'kids'};
    final resume = await jf.continueWatching();
    // Music is skipped for video-only queries; Kids is hidden.
    expect(calls, ['/UserViews?parentId=null', '/UserItems/Resume?parentId=movies']);
    expect(resume.map((i) => i.id), ['x-movies']);

    calls.clear();
    await jf.search('x');
    expect(calls, ['/Items?parentId=movies', '/Items?parentId=tunes']);
  });

  testWidgets('TV remote can reach the side menu and come back',
      (tester) async {
    await _pump(tester, const Size(1920, 1080), tv: true);
    FocusNode? focus() => FocusManager.instance.primaryFocus;
    bool inNav() => focus()?.debugLabel?.startsWith('nav ') ?? false;

    // Down into a shelf, then keep pressing left until the rail takes focus.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(inNav(), isFalse);
    FocusNode? lastInPage;
    for (var i = 0; i < 12 && !inNav(); i++) {
      lastInPage = focus();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }
    expect(focus()?.debugLabel, 'nav Home');

    // Right goes back to the card we left from.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focus(), same(lastInPage));

    // Into the rail, down to Libraries, open it, then right lands on that
    // tab rather than a card in the hidden Home tab underneath.
    for (var i = 0; i < 12 && !inNav(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focus()?.debugLabel, 'nav Libraries');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(inNav(), isFalse);
    expect(
        focus()?.context?.findAncestorWidgetOfExactType<LibrariesScreen>(),
        isNotNull);
  });

  testWidgets('drop-down menus take focus for the remote and give it back',
      (tester) async {
    await _pump(tester, const Size(1920, 1080), tv: true);
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

    await tester.tap(find.text('Video quality'));
    await tester.pumpAndSettle();
    // Lands on the current choice ("Original" is first).
    expect(focused(), 'menu item 0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(), 'menu item 1');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(QualityOption.all[1].label), findsOneWidget);
    expect(focused(), 'menu button');

    // Reopening starts on the new choice.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(focused(), 'menu item 1');
  });

  testWidgets('option panels focus their current row and scroll to it',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showPanel<void>(context,
                builder: (_) => OptionPanel(title: 'Subtitles', children: [
                      for (var i = 0; i < 40; i++)
                        OptionTile(
                          label: 'Track $i',
                          selected: i == 33,
                          autofocus: i == 33,
                          onTap: () {},
                        ),
                    ])),
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final ctx = FocusManager.instance.primaryFocus!.context!;
    expect(ctx.findAncestorWidgetOfExactType<OptionTile>()!.label, 'Track 33');
    final box = tester.getRect(find.text('Track 33'));
    expect(box.top, greaterThanOrEqualTo(0));
    expect(box.bottom, lessThanOrEqualTo(1080));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<OptionTile>()!
            .label,
        'Track 34');
  });

  testWidgets('video libraries open on Recommended', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Libraries').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies').last);
    await tester.pumpAndSettle();
    final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Recommended'));
    expect(chip.selected, isTrue);
    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text('Top rated movies'), findsOneWidget);
    // Sorting and the unwatched filter belong to the All grid.
    expect(find.text('Unwatched'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(find.text('Unwatched'), findsOneWidget);
    expect(find.text('Recently added'), findsNothing);
  });

  test('Plex library hubs become Recommended rows', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://h'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        expect(o.path, '/hubs/sections/3');
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'MediaContainer': {
            'Hub': [
              {
                'hubIdentifier': 'movie.inprogress.3',
                'title': 'Continue Watching',
                'Metadata': [
                  {'ratingKey': '1', 'type': 'movie', 'title': 'A'}
                ],
              },
              {'hubIdentifier': 'movie.empty', 'title': 'Empty'},
              {
                'hubIdentifier': 'movie.recentlyadded.3',
                'title': 'Recently Added Movies',
                'Metadata': [
                  {'ratingKey': '2', 'type': 'movie', 'title': 'B'}
                ],
              },
            ],
          },
        }));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't'),
        dio: dio);
    final rows = await plex.recommended(const Library(
        serverId: 'p', id: '3', title: 'Movies', kind: LibraryKind.movies));
    expect(rows.map((r) => r.title),
        ['Continue Watching', 'Recently Added Movies']);
    expect(rows.map((r) => r.landscape), [true, false]);
  });

  test('Jellyfin builds Recommended rows scoped to the library', () async {
    final paths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        paths.add(o.path);
        expect(o.queryParameters['parentId'], 'tv');
        final empty = o.path == '/Items/Latest';
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'Items': [
            if (!empty) {'Id': 'x', 'Type': 'Series', 'Name': 'X'},
          ],
        }));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    final rows = await jf.recommended(const Library(
        serverId: 'j', id: 'tv', title: 'TV', kind: LibraryKind.shows));
    expect(paths, containsAll(['/UserItems/Resume', '/Shows/NextUp', '/Items']));
    // The empty "Recently added" row is dropped.
    expect(rows.map((r) => r.title),
        ['Continue watching', 'Next up', 'Top rated shows']);
    expect(rows.map((r) => r.landscape), [true, true, false]);
  });

  testWidgets('TV library grid fits seven posters across', (tester) async {
    // A 1080p TV at the usual 2x density: 960x540 logical pixels.
    tester.view.devicePixelRatio = 2;
    await _pump(tester, const Size(1920, 1080), tv: true);
    tester.view.devicePixelRatio = 2;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Libraries').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();

    final cards = find.byType(MediaCard);
    final tops = [
      for (final e in cards.evaluate()) tester.getTopLeft(find.byWidget(e.widget)).dy
    ];
    final firstRow = tops.where((t) => t == tops.first).length;
    expect(firstRow, 7);
    // At least two full rows fit on the screen.
    final rowTops = tops.toSet().toList()..sort();
    expect(rowTops.length, greaterThanOrEqualTo(2));
    final secondRowBottom =
        tester.getBottomLeft(find.byWidget(cards.evaluate().elementAt(7).widget)).dy;
    expect(secondRowBottom, lessThanOrEqualTo(540));
  });

  test('backend errors reach the user verbatim', () {
    expect(friendlyError(const BackendException('That PIN wasn\'t right.')),
        'That PIN wasn\'t right.');
  });
}
