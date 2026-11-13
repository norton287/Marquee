import 'dart:convert';

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
import 'package:marquee/core/network.dart';
import 'package:marquee/core/plex.dart';
import 'package:marquee/core/providers.dart';
import 'package:marquee/core/storage.dart';
import 'package:marquee/ui/add_server_screen.dart';
import 'package:marquee/ui/libraries_screen.dart';
import 'package:marquee/ui/manage.dart';
import 'package:marquee/ui/music.dart';
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
      expect(find.text('Maximum quality at home'), findsOneWidget);
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

  test('plex accounts group by home token and remember the last switched',
      () async {
    const a = ServerConfig(id: 'a', kind: ServerKind.plex, name: 'A',
        baseUrl: 'http://a', homeToken: 'h1', accountToken: 'u1');
    const b = ServerConfig(id: 'b', kind: ServerKind.plex, name: 'B',
        baseUrl: 'http://b', homeToken: 'h1', accountToken: 'u1');
    const c = ServerConfig(id: 'c', kind: ServerKind.plex, name: 'C',
        baseUrl: 'http://c', accountToken: 'h2'); // old save: no homeToken
    const bare = ServerConfig(id: 'd', kind: ServerKind.plex, name: 'D',
        baseUrl: 'http://d');
    const servers = [demoServer, a, bare, b, c];

    expect(plexAccounts(servers).map((g) => g.map((s) => s.id).toList()),
        [['a', 'b'], ['c']]);
    expect(profileServer(servers, 'c')?.id, 'c');
    expect(profileServer(servers, 'b')?.id, 'a'); // that account's first server
    expect(profileServer(servers, 'gone')?.id, 'a'); // removed: first account
    expect(profileServer(servers, null)?.id, 'a');
    expect(profileServer(const [demoServer, bare], null), isNull);

    final store = MemoryStore();
    final s1 = AppStorage(store);
    await s1.load();
    await s1.saveSettings(const AppSettings(profileServerId: 'c'));
    final s2 = AppStorage(store);
    await s2.load();
    expect(s2.settings.profileServerId, 'c');
    expect(s2.settings.copyWith(autoPlayNext: false).profileServerId, 'c');
  });

  Future<void> pumpPlexAccounts(WidgetTester tester, List<ServerConfig> servers) async {
    Artwork.network = false;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = await _storage(demo: false);
    await storage.saveServers([demoServer, ...servers]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        deviceIsTvProvider.overrideWithValue(true),
      ],
      retry: (_, _) => null,
      child: const MarqueeApp(),
    ));
    await tester.pumpAndSettle();
  }

  const john = ServerConfig(id: 'pj', kind: ServerKind.plex, name: 'Den',
      baseUrl: 'http://127.0.0.1:9', homeToken: 'h1', accountToken: 'u1',
      userName: 'John');
  const sarah = ServerConfig(id: 'ps', kind: ServerKind.plex, name: 'Garage',
      baseUrl: 'http://127.0.0.1:9', homeToken: 'h2', accountToken: 'u2',
      userName: 'Sarah');

  testWidgets('TV: profile item asks which Plex account when there are two',
      (tester) async {
    await pumpPlexAccounts(tester, const [john, sarah]);
    await tester.tap(find.text('John').first);
    await tester.pumpAndSettle();

    expect(find.text('Which Plex account?'), findsOneWidget);
    final dialog = find.byType(Dialog);
    final rows = find.descendant(of: dialog, matching: find.byType(ListTile));
    expect(rows, findsNWidgets(2));
    expect(find.descendant(of: dialog, matching: find.text('Plex · Garage')),
        findsOneWidget);
    bool focusedIn(Finder f) {
      final ctx = FocusManager.instance.primaryFocus?.context;
      final target = tester.element(f);
      var hit = identical(ctx, target);
      ctx?.visitAncestorElements((e) => !(hit = hit || identical(e, target)));
      return hit;
    }
    expect(focusedIn(rows.at(0)), isTrue, reason: 'current account focused');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedIn(rows.at(1)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Which Plex account?'), findsNothing);
    expect(find.text("Who's watching?"), findsOneWidget);
  });

  testWidgets('one Plex account skips the account chooser', (tester) async {
    await pumpPlexAccounts(tester, const [john]);
    await tester.tap(find.text('John').first);
    await tester.pumpAndSettle();
    expect(find.text('Which Plex account?'), findsNothing);
    expect(find.text("Who's watching?"), findsOneWidget);
  });

  test('music stops only for the switched account\'s servers', () {
    const t = MediaItem(serverId: 'pj', id: '1', kind: MediaKind.track, title: 'T');
    const other = MediaItem(serverId: 'demo', id: '2', kind: MediaKind.track, title: 'U');
    expect(musicFromServers(const [other, t], {'pj', 'pk'}), isTrue);
    expect(musicFromServers(const [other], {'pj'}), isFalse);
    expect(musicFromServers(const [], {'pj'}), isFalse);
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

  testWidgets('settings shows home network / over the internet on its own line',
      (tester) async {
    Artwork.network = false;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = await _storage();
    await storage.saveServers(const [
      demoServer,
      ServerConfig(id: 'home', kind: ServerKind.jellyfin, name: 'Den',
          baseUrl: 'http://192.168.1.20:8096'),
      ServerConfig(id: 'away', kind: ServerKind.jellyfin, name: 'Cabin',
          baseUrl: 'https://jf.example.com'),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        deviceIsTvProvider.overrideWithValue(false),
      ],
      retry: (_, _) => null,
      child: const MarqueeApp(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();

    // Separate Text widgets, not appended to the host line.
    expect(find.text('Home network'), findsOneWidget);
    expect(find.text('Over the internet'), findsOneWidget);
    expect(find.text('Jellyfin · 192.168.1.20'), findsOneWidget);
    expect(find.text('Jellyfin · jf.example.com'), findsOneWidget);
    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
    expect(find.byIcon(Icons.public_rounded), findsOneWidget);
  });

  test('Jellyfin drops hidden-library items from similar and collections',
      () async {
    final calls = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        final q = o.queryParameters;
        calls.add('${o.path} ids=${q['ids']} parentId=${q['parentId']}');
        Map<String, dynamic> items(List<String> ids) => {
              'Items': [for (final id in ids) {'Id': id, 'Name': id, 'Type': 'Movie'}]
            };
        final data = switch (o.path) {
          '/Items/m1/Similar' => items(['a', 'b', 'c']),
          // Which of these ids live in the hidden library: only b.
          '/Items' when q['ids'] != null && q['parentId'] == 'kids' =>
            items(['b']),
          '/Items' when q['parentId'] == 'box1' => items(['a', 'b']),
          _ => <String, dynamic>{},
        };
        h.resolve(Response(
            requestOptions: o, data: jsonDecode(jsonEncode(data)), statusCode: 200));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    final movie = jf.parse({'Id': 'm1', 'Name': 'Heat', 'Type': 'Movie'});
    final box = jf.parse({'Id': 'box1', 'Name': 'Saga', 'Type': 'BoxSet'});

    // Nothing hidden: no extra lookups.
    expect((await jf.similar(movie)).map((i) => i.id), ['a', 'b', 'c']);
    expect(calls.where((c) => c.contains('ids=a')), isEmpty);

    jf.hiddenLibraries = {'kids'};
    expect((await jf.similar(movie)).map((i) => i.id), ['a', 'c']);
    expect(calls.last, '/Items ids=a,b,c parentId=kids');
    expect((await jf.children(box)).map((i) => i.id), ['a']);
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

    await tester.tap(find.text('Maximum quality at home'));
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

  testWidgets('TV shelves use the same compact cards as grids',
      (tester) async {
    // 1080p TV at 2x: 960 logical px wide. Content = 960 - rail - gutters.
    tester.view.devicePixelRatio = 2;
    await _pump(tester, const Size(1920, 1080), tv: true);
    tester.view.devicePixelRatio = 2;
    await tester.pumpAndSettle();
    const content = 960 - 104 - 48 * 2;
    const poster = (content - 14 * 6) / 7; // ~96.6, was 176
    const wide = (content - 14 * 3) / 4; // ~179.5, was 340

    final widths = {
      for (final e in find.byType(MediaCard).evaluate())
        (e.widget as MediaCard).shape:
            tester.getSize(find.byWidget(e.widget)).width,
    };
    expect(widths[CardShape.landscape], closeTo(wide, 0.5));
    // "New in Movies" is further down the page.
    await tester.scrollUntilVisible(find.text('New in Movies'), 200,
        scrollable: find.byType(Scrollable).first);
    final posterCard = find.byWidgetPredicate(
        (w) => w is MediaCard && w.shape == CardShape.poster);
    expect(tester.getSize(posterCard.first).width, closeTo(poster, 0.5));

    // A grid poster in a library is exactly the same size.
    await tester.tap(find.text('Libraries').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MediaCard).first).width,
        closeTo(poster, 0.5));
  });

  test('skip lengths default to 10/30, round-trip, and reject odd values',
      () async {
    expect(const AppSettings().skipBackSeconds, 10);
    expect(const AppSettings().skipForwardSeconds, 30);
    final store = MemoryStore();
    final a = AppStorage(store);
    await a.load();
    await a.saveSettings(
        const AppSettings(skipBackSeconds: 5, skipForwardSeconds: 60));
    final b = AppStorage(store);
    await b.load();
    expect(b.settings.skipBackSeconds, 5);
    expect(b.settings.skipForwardSeconds, 60);
    final odd = AppSettings.fromJson(
        {'skipBackSeconds': 7, 'skipForwardSeconds': 'x'}, const {});
    expect((odd.skipBackSeconds, odd.skipForwardSeconds), (10, 30));
  });

  testWidgets('skip lengths are chosen in Settings', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Skip back'), 200,
        scrollable: find.byType(Scrollable).last);
    // Let the scroll come to rest: a menu closes if its page scrolls.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('45 seconds').last);
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    expect(container.read(settingsProvider).skipBackSeconds, 45);
    expect(container.read(settingsProvider).skipForwardSeconds, 30);
  });

  testWidgets('a menu low on a TV page stays open while arrowing through it',
      (tester) async {
    await _pump(tester, const Size(1920, 1080), tv: true);
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Skip forward'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    final tile = find.ancestor(
        of: find.text('Skip forward'), matching: find.byType(ListTile));
    Focus.of(tester.element(find.text('Skip forward'))).requestFocus();
    await tester.pumpAndSettle();
    expect(tile, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
    expect(focused(), 'menu item 4'); // 30 seconds
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(focused(), 'menu item 6');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    expect(container.read(settingsProvider).skipForwardSeconds, 60);
  });

  testWidgets('scrubber steps back and forward by their own lengths',
      (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SeekBar(
          position: ValueNotifier(const Duration(seconds: 100)),
          buffer: ValueNotifier(Duration.zero),
          duration: const Duration(minutes: 10),
          onSeek: seeks.add,
          step: const Duration(seconds: 45),
          backStep: const Duration(seconds: 5),
        ),
      ),
    ));
    Focus.of(tester.element(find.descendant(
            of: find.byType(SeekBar), matching: find.byType(Semantics))
        .first))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(seeks, [const Duration(seconds: 95), const Duration(seconds: 145)]);
  });

  testWidgets('skip icons show the length', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Row(children: [
        SkipIcon(seconds: 10, forward: false),
        SkipIcon(seconds: 45, forward: true),
      ]),
    ));
    expect(find.byIcon(Icons.replay_10_rounded), findsOneWidget);
    expect(find.text('45'), findsOneWidget);
  });

  test('Plex manage and playlist calls', () async {
    final calls = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://h'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        final q = Map.of(o.queryParameters)..remove('X-Plex-Token');
        calls.add('${o.method} ${o.path} $q');
        Object? data = const <String, dynamic>{};
        if (o.path == '/library/sections') {
          data = {
            'MediaContainer': {
              'Directory': [
                {'key': '1', 'agent': 'tv.plex.agents.movie', 'language': 'en-US'}
              ]
            }
          };
        } else if (o.path.endsWith('/matches')) {
          data = {
            'MediaContainer': {
              'SearchResult': [
                {'guid': 'plex://movie/abc', 'name': 'Heat', 'year': 1995,
                 'score': 98, 'thumb': 'https://img/heat.jpg'}
              ]
            }
          };
        } else if (o.path.endsWith('/posters')) {
          data = {
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': 'https://img/p1.jpg', 'thumb': 'https://img/p1.jpg',
                 'selected': true, 'provider': 'tmdb'},
                {'ratingKey': 'upload://posters/x', 'thumb': '/library/metadata/42/file?url=x'},
              ]
            }
          };
        } else if (o.path.endsWith('/refresh') && o.method == 'PUT') {
          return h.reject(DioException(
              requestOptions: o,
              response: Response(requestOptions: o, statusCode: 403)));
        }
        h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't', machineId: 'mach'),
        dio: dio);
    final movie = plex.parse({'ratingKey': '42', 'type': 'movie',
        'title': 'Heat', 'librarySectionID': 1});

    // This fake server doesn't allow deletion, so Delete isn't offered;
    // Delete playlist is for playlists only.
    expect(
        await plex.manageActions(movie),
        ManageAction.values.toSet()
          ..remove(ManageAction.delete)
          ..remove(ManageAction.deleteVersion)
          ..remove(ManageAction.removeFromPlaylist)
          ..remove(ManageAction.deletePlaylist));
    final matches = await plex.searchMatches(movie, title: 'Heat', year: 1995);
    expect(calls.last, contains('/library/metadata/42/matches'));
    expect(calls.last, contains('agent: tv.plex.agents.movie'));
    expect(calls.last, contains('language: en-US'));
    expect((matches.single.id, matches.single.score, matches.single.source),
        ('plex://movie/abc', 98, 'Plex'));
    await plex.applyMatch(movie, matches.single);
    expect(calls.last,
        'PUT /library/metadata/42/match {guid: plex://movie/abc, name: Heat, year: 1995}');

    final posters = await plex.artwork(movie, ArtworkKind.poster);
    expect(posters.map((p) => (p.id, p.selected)),
        [('https://img/p1.jpg', true), ('upload://posters/x', false)]);
    await plex.setArtwork(movie, ArtworkKind.poster, posters[1]);
    expect(calls.last, 'PUT /library/metadata/42/poster {url: upload://posters/x}');

    await expectLater(plex.refreshMetadata(movie),
        throwsA(isA<BackendException>().having((e) => e.message, 'message',
            contains('server owner'))));

    final playlist = plex.parse(
        {'ratingKey': '9', 'type': 'playlist', 'title': 'Mine'});
    await plex.addToPlaylist(playlist, movie);
    expect(calls.last, 'PUT /playlists/9/items '
        '{uri: server://mach/com.plexapp.plugins.library/library/metadata/42}');
    await plex.createPlaylist('Friday', movie);
    expect(calls.last, startsWith('POST /playlists {type: video, title: Friday, smart: 0'));
  });

  test('Plex removes a playlist entry by its playlistItemID', () async {
    final calls = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://h'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls.add('${o.method} ${o.path}');
        final data = o.path == '/playlists/9/items'
            ? {'MediaContainer': {'Metadata': [
                // The same video twice: only the chosen entry may go.
                {'ratingKey': '42', 'playlistItemID': 540, 'type': 'movie', 'title': 'Heat'},
                {'ratingKey': '42', 'playlistItemID': 541, 'type': 'movie', 'title': 'Heat'},
              ]}}
            : {'MediaContainer': {}};
        h.resolve(Response(
            requestOptions: o, data: jsonDecode(jsonEncode(data)), statusCode: 200));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't', machineId: 'mach'),
        dio: dio);
    final playlist = plex.parse(
        {'ratingKey': '9', 'type': 'playlist', 'title': 'Mine', 'leafCount': 2});
    expect(await plex.manageActions(playlist),
        {ManageAction.removeFromPlaylist, ManageAction.deletePlaylist});

    final entries = await plex.children(playlist);
    expect(entries.map((e) => e.playlistEntryId), ['540', '541']);
    await plex.removeFromPlaylist(playlist, entries[1]);
    expect(calls.last, 'DELETE /playlists/9/items/541');

    // Smart playlists are filled by a rule; empty ones have nothing to remove.
    final smart = plex.parse({'ratingKey': '8', 'type': 'playlist',
        'title': 'Rule', 'smart': true, 'leafCount': 3});
    expect(smart.smart, isTrue);
    expect(await plex.manageActions(smart), {ManageAction.deletePlaylist});
    final empty = plex.parse(
        {'ratingKey': '7', 'type': 'playlist', 'title': 'Empty', 'leafCount': 0});
    expect(await plex.manageActions(empty), {ManageAction.deletePlaylist});

    // An item that wasn't read from a playlist has no entry to remove.
    final loose = plex.parse({'ratingKey': '42', 'type': 'movie', 'title': 'Heat'});
    await expectLater(plex.removeFromPlaylist(playlist, loose), throwsStateError);
  });

  test('Jellyfin removes a playlist entry by its PlaylistItemId', () async {
    final calls = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls.add('${o.method} ${o.path} ${o.queryParameters}');
        final data = o.path == '/Playlists/p1/Items'
            ? {'Items': [
                {'Id': 'm1', 'Name': 'Heat', 'Type': 'Movie', 'PlaylistItemId': 'e1'},
                {'Id': 'm1', 'Name': 'Heat', 'Type': 'Movie', 'PlaylistItemId': 'e2'},
              ]}
            : <String, dynamic>{};
        h.resolve(Response(
            requestOptions: o, data: jsonDecode(jsonEncode(data)), statusCode: 200));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    final playlist = jf.parse(
        {'Id': 'p1', 'Name': 'Mine', 'Type': 'Playlist', 'ChildCount': 2});
    expect(await jf.manageActions(playlist),
        {ManageAction.removeFromPlaylist, ManageAction.deletePlaylist});
    final entries = await jf.children(playlist);
    expect(entries.map((e) => e.playlistEntryId), ['e1', 'e2']);
    await jf.removeFromPlaylist(playlist, entries[1]);
    expect(calls.last, 'DELETE /Playlists/p1/Items {entryIds: e2}');
  });

  test('Plex edit sends sort title, year and genre changes with locks',
      () async {
    final calls = <Map<String, dynamic>>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://h'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'PUT') calls.add({'path': o.path, ...o.queryParameters});
        h.resolve(Response(requestOptions: o, data: <String, dynamic>{}, statusCode: 200));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't'),
        dio: dio);
    final movie = plex.parse({'ratingKey': '102035', 'type': 'movie',
        'title': 'True Lies', 'year': 1994, 'librarySectionID': 1,
        'Genre': [{'tag': 'Action'}, {'tag': 'Thriller'}, {'tag': 'Comedy'}]});

    await plex.editDetails(movie, title: 'True Lies', summary: '',
        sortTitle: 'Lies, True', year: 1995, genres: ['Action', 'Drama']);
    final q = calls.single;
    expect(q['path'], '/library/sections/1/all');
    expect(q['titleSort.value'], 'Lies, True');
    expect(q['titleSort.locked'], 1);
    expect(q['year.value'], 1995);
    expect(q['year.locked'], 1);
    expect(q['genre[0].tag.tag'], 'Drama'); // only the new one is added
    expect(q['genre[].tag.tag-'], 'Thriller,Comedy'); // dropped ones removed
    expect(q['genre.locked'], 1);

    // Fields left alone aren't sent (or locked).
    calls.clear();
    await plex.editDetails(movie, title: 'True Lies', summary: '');
    expect(calls.single.keys.where((k) => k.startsWith('genre') ||
        k.startsWith('year') || k.startsWith('titleSort')), isEmpty);
  });

  test('Jellyfin edit sets sort name, year and genres in the whole record',
      () async {
    Object? posted;
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'POST') posted = o.data;
        final data = o.method == 'GET'
            ? {'Id': 'm1', 'Name': 'Heat', 'Overview': 'x', 'Studios': ['S'],
               'Genres': ['Crime'], 'ProductionYear': 1995, 'LockedFields': []}
            : <String, dynamic>{};
        h.resolve(Response(
            requestOptions: o, data: jsonDecode(jsonEncode(data)), statusCode: 200));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    final movie = jf.parse({'Id': 'm1', 'Name': 'Heat', 'Type': 'Movie'});
    await jf.editDetails(movie, title: 'Heat', summary: 'x',
        sortTitle: 'Heat (1995)', year: 1996, genres: ['Crime', 'Drama']);
    final dto = posted! as Map;
    expect(dto['ForcedSortName'], 'Heat (1995)');
    expect(dto['ProductionYear'], 1996);
    expect(dto['Genres'], ['Crime', 'Drama']);
    expect(dto['Studios'], ['S']); // the rest of the record is kept
    expect(dto['LockedFields'], containsAll(['Name', 'Overview', 'Genres']));
  });

  Dio fakePlexWithVersions(List<String> deletes, {required bool allow}) =>
      Dio(BaseOptions(baseUrl: 'http://h'))
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          if (o.method == 'DELETE') deletes.add(o.path);
          final data = switch (o.path) {
            '/:/prefs' => {'MediaContainer': {'Setting': [
                {'id': 'allowMediaDeletion', 'value': allow}]}},
            '/library/metadata/42' => {'MediaContainer': {'Metadata': [
                {'ratingKey': '42', 'type': 'movie', 'title': 'Heat',
                 'librarySectionID': 1, 'Media': [
                   {'id': 1, 'videoResolution': '1080', 'width': 1920,
                    'height': 1080, 'Part': [{'id': 11}]},
                   {'id': 2, 'videoResolution': '720', 'width': 1280,
                    'height': 720, 'Part': [{'id': 12}]},
                 ]}]}},
            _ => {'MediaContainer': {}},
          };
          h.resolve(Response(
              requestOptions: o, data: jsonDecode(jsonEncode(data)), statusCode: 200));
        }));

  test('Plex deletes one version only where deletion is allowed', () async {
    final deletes = <String>[];
    PlexBackend plex(bool allow) => PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't'),
        dio: fakePlexWithVersions(deletes, allow: allow));
    final on = plex(true);
    final movie = await on.item('42');
    expect(await on.manageActions(movie), contains(ManageAction.deleteVersion));
    expect(on.deletableVersions(movie).map((v) => v.id), ['1', '2']);
    await on.deleteVersion(movie, movie.versions[1]);
    expect(deletes, ['/library/metadata/42/media/2']);

    final off = plex(false);
    expect(await off.manageActions(await off.item('42')),
        isNot(contains(ManageAction.deleteVersion)));
    final single = on.parse({'ratingKey': '7', 'type': 'movie', 'title': 'One',
        'Media': [{'id': 9, 'Part': [{'id': 90}]}]});
    expect(await on.manageActions(single),
        isNot(contains(ManageAction.deleteVersion)));
  });

  test('Jellyfin offers only the extra versions and deletes that item',
      () async {
    final deletes = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'DELETE') deletes.add(o.path);
        final data = o.path == '/Users/u'
            ? {'Policy': {'IsAdministrator': true, 'EnableContentDeletion': true}}
            : <String, dynamic>{};
        h.resolve(Response(
            requestOptions: o, data: jsonDecode(jsonEncode(data)), statusCode: 200));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    final movie = jf.parse({'Id': 'm1', 'Name': 'Heat', 'Type': 'Movie',
        'MediaSources': [
          {'Id': 'm1', 'Name': '4K', 'Width': 3840, 'Height': 2160},
          {'Id': 'alt1', 'Name': '1080p', 'Width': 1920, 'Height': 1080},
        ]});
    expect(await jf.manageActions(movie), contains(ManageAction.deleteVersion));
    // The primary version is the movie itself: deleting it deletes the movie.
    expect(jf.deletableVersions(movie).map((v) => v.id), ['alt1']);
    await jf.deleteVersion(movie, jf.deletableVersions(movie).single);
    expect(deletes, ['/Items/alt1']);
  });

  test('Jellyfin manage needs an admin and maps its calls', () async {
    var admin = false;
    final calls = <(String, String, Object?)>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls.add((o.method, o.path, o.data));
        final data = switch (o.path) {
          '/Users/u' => {'Policy': {'IsAdministrator': admin}},
          '/Items/RemoteSearch/Movie' => [
              {'Name': 'Heat', 'ProductionYear': 1995,
               'ProviderIds': {'Tmdb': '949'}, 'ImageUrl': 'https://img/h.jpg',
               'SearchProviderName': 'TheMovieDb'}
            ],
          '/Items/m1/RemoteImages' => {
              'Images': [
                {'Url': 'https://img/a.jpg', 'ThumbnailUrl': 'https://img/a_t.jpg',
                 'ProviderName': 'TheMovieDb', 'Width': 1000, 'Height': 1500}
              ]
            },
          _ => <String, dynamic>{},
        };
        h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
      }));
    JellyfinBackend make() => JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    const movie = MediaItem(serverId: 'j', id: 'm1', kind: MediaKind.movie,
        title: 'Heat');

    expect(await make().manageActions(movie), isEmpty);
    admin = true;
    final jf = make();
    expect(await jf.manageActions(movie), contains(ManageAction.match));

    final m = (await jf.searchMatches(movie, title: 'Heat', year: 1995)).single;
    expect((m.id, m.source), ('tmdb:949', 'TheMovieDb'));
    expect(calls.last.$3, containsPair('ItemId', 'm1'));
    await jf.applyMatch(movie, m);
    expect(calls.last.$2, '/Items/RemoteSearch/Apply/m1');
    expect(calls.last.$3, same(m.raw));

    final art = (await jf.artwork(movie, ArtworkKind.background)).single;
    expect((art.id, art.image.template), ('https://img/a.jpg', 'https://img/a_t.jpg'));
    await jf.setArtwork(movie, ArtworkKind.background, art);
    expect(calls.last.$2, '/Items/m1/RemoteImages/Download');

    await jf.createPlaylist('Friday', movie);
    expect((calls.last.$1, calls.last.$2), ('POST', '/Playlists'));
    expect(calls.last.$3,
        {'Name': 'Friday', 'Ids': ['m1'], 'UserId': 'u', 'MediaType': 'Video'});
  });

  Future<void> openDemoMovie(WidgetTester tester, String title,
      {bool tv = false}) async {
    await _pump(tester, const Size(1440, 900), tv: tv);
    await tester.tap(find.text('Libraries').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  testWidgets('Manage: fix match renames, poster can be changed',
      (tester) async {
    await openDemoMovie(tester, 'Night Ferry');
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    for (final a in ['Refresh metadata', 'Fix match…', 'Change poster…',
        'Change background…']) {
      expect(find.text(a), findsOneWidget);
    }
    await tester.tap(find.text('Fix match…'));
    await tester.pumpAndSettle();
    final title = find.descendant(
        of: find.byType(TextField).first, matching: find.byType(EditableText));
    await tester.enterText(title, 'Harbor');
    // "Search" is also a nav tab on desktop; this is the panel's button.
    await tester.tap(find.ancestor(
        of: find.text('Search'),
        matching: find.byWidgetPredicate((w) => w is FilledButton)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Harbor Lights ('));
    await tester.pumpAndSettle();
    expect(find.textContaining('Matched to Harbor Lights'), findsOneWidget);
    expect(find.text('Harbor Lights'), findsWidgets);

    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change poster…'));
    await tester.pumpAndSettle();
    final panel = find.ancestor(
        of: find.text('Change poster'),
        matching: find.byType(SingleChildScrollView));
    final choices =
        find.descendant(of: panel.first, matching: find.byType(Pressable));
    expect(choices, findsNWidgets(8));
    await tester.tap(choices.at(3));
    await tester.pumpAndSettle();
    expect(find.text('Poster updated'), findsOneWidget);
    // A match reloads once more after the server has had time to finish.
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('TV: change poster panel focuses a full-size poster', (tester) async {
    await openDemoMovie(tester, 'Blue Hour', tv: true);
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change poster…'));
    await tester.pumpAndSettle();
    final panel = find.ancestor(
        of: find.text('Change poster'),
        matching: find.byType(SingleChildScrollView));
    final focus = FocusManager.instance.primaryFocus;
    final panelWidget = tester.widget(panel.first);
    var inPanel = false, inPressable = false;
    focus!.context!.visitAncestorElements((e) {
      if (e.widget is Pressable) inPressable = true;
      if (identical(e.widget, panelWidget)) inPanel = true;
      return !inPanel;
    });
    expect(inPanel && inPressable, isTrue);

    // Each choice is a real 2:3 poster, not a strip: Artwork's aspect only
    // picks the image size, so the panel must give the tile its height.
    final tile = tester.getSize(
        find.descendant(of: panel.first, matching: find.byType(Pressable)).first);
    expect(tile.height, closeTo(tile.width * 3 / 2, 1));
  });

  testWidgets('Edit details changes sort title, year and genres',
      (tester) async {
    await openDemoMovie(tester, 'North of Nowhere');
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit details…'));
    await tester.pumpAndSettle();
    TextField field(String label) => tester.widget<TextField>(find.ancestor(
        of: find.text(label), matching: find.byType(TextField)));
    expect(field('Sort title').controller!.text, '');
    expect(field('Year').controller!.text, '2024');
    expect(field('Genres').controller!.text, 'Comedy, Adventure');

    await tester.enterText(find.widgetWithText(TextField, 'Year'), 'nineteen');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the year as four digits.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Year'), '1999');
    await tester.enterText(find.widgetWithText(TextField, 'Genres'), 'Noir,  Drama ,');
    await tester.enterText(find.widgetWithText(TextField, 'Sort title'), 'Nowhere, North of');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Saved changes to North of Nowhere'), findsOneWidget);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final demo = container.read(backendsProvider)['demo']!;
    final saved = (await demo.search('North of Nowhere')).first;
    expect(saved.year, 1999);
    expect(saved.genres, ['Noir', 'Drama']);
    expect(saved.sortTitle, 'Nowhere, North of');
  });

  testWidgets('Add to playlist creates a playlist with the item',
      (tester) async {
    await openDemoMovie(tester, 'Low Sun');
    await tester.tap(find.byTooltip('Add to playlist'));
    await tester.pumpAndSettle();
    expect(find.text('Friday Night'), findsOneWidget);
    await tester.tap(find.text('New playlist…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Rainy day');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Added to "Rainy day"'), findsOneWidget);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final lists = await container.read(playlistsProvider('demo').future);
    final created = lists.firstWhere((p) => p.title == 'Rainy day');
    final items = await container.read(backendsProvider)['demo']!.children(created);
    expect(items.single.title, 'Low Sun');
  });

  testWidgets('Manage panels put the remote on something', (tester) async {
    await openDemoMovie(tester, 'Copper Sky', tv: true);
    String? focusedText() {
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return null;
      final texts = <String>[];
      void visit(Element e) {
        if (e.widget is Text) texts.add((e.widget as Text).data ?? '');
        e.visitChildren(visit);
      }
      (ctx as Element).visitChildren(visit);
      return texts.join(' | ');
    }

    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix match…'));
    await tester.pumpAndSettle();
    // The search runs on open and the first result takes focus.
    expect(focusedText(), contains('Copper Sky ('));
    // ↑ from the results reaches the Search button, not a trapped field.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focusedText(), contains('Search'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.context?.widget,
        isA<Focus>()); // inside the title field
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedText(), contains('Search'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add to playlist'));
    await tester.pumpAndSettle();
    expect(focusedText(), contains('New playlist…'));
  });

  test('Edit details: Plex sets and locks title and summary', () async {
    final calls = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://h'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        final q = Map.of(o.queryParameters)..remove('X-Plex-Token');
        calls.add('${o.method} ${o.path} $q');
        h.resolve(Response(requestOptions: o, statusCode: 200));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't'),
        dio: dio);
    final show = plex.parse({'ratingKey': '7', 'type': 'show',
        'title': 'Old', 'librarySectionID': 2});
    await plex.editDetails(show, title: 'New', summary: 'About it');
    expect(calls.single,
        'PUT /library/sections/2/all {type: 2, id: 7, title.value: New, '
        'title.locked: 1, summary.value: About it, summary.locked: 1}');
  });

  test('Edit details: Jellyfin sends the whole record back with locks',
      () async {
    Object? posted;
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'POST') posted = o.data;
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'Id': 'm1', 'Name': 'Old', 'Overview': 'x', 'Genres': ['Drama'],
          'LockedFields': ['Genres'],
        }));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    await jf.editDetails(
        const MediaItem(serverId: 'j', id: 'm1', kind: MediaKind.movie,
            title: 'Old'),
        title: 'New',
        summary: 'Better');
    expect(posted, {
      'Id': 'm1', 'Name': 'New', 'Overview': 'Better', 'Genres': ['Drama'],
      'LockedFields': ['Genres', 'Name', 'Overview'],
    });
  });

  testWidgets('Edit details changes the title and summary', (tester) async {
    await openDemoMovie(tester, 'Field Notes');
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit details…'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Field Notes (Director\'s Cut)');
    await tester.enterText(fields.at(1), 'A longer, stranger cut.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Saved changes to Field Notes (Director\'s Cut)'),
        findsOneWidget);
    expect(find.text('Field Notes (Director\'s Cut)'), findsWidgets);
    expect(find.text('A longer, stranger cut.'), findsOneWidget);
  });

  testWidgets('Edit panel: remote ↑/↓ leave fields, but not mid-summary',
      (tester) async {
    await openDemoMovie(tester, 'Blue Hour', tv: true);
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit details…'));
    await tester.pumpAndSettle();
    final title = tester.widget<TextField>(find.byType(TextField).at(0));
    final summary = tester.widget<TextField>(find.byType(TextField).at(1));
    bool inField(TextField f) =>
        FocusManager.instance.primaryFocus == f.focusNode ||
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<TextField>() ==
            f;
    expect(inField(title), isTrue); // opens on the title

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(inField(summary), isTrue);
    summary.controller!
      ..text = 'line one\nline two'
      ..selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    // Caret on the first line: ↓ stays in the summary.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(inField(summary), isTrue);
    // From the last line ↓ leaves for the buttons.
    summary.controller!.selection =
        const TextSelection.collapsed(offset: 'line one\nline two'.length);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(inField(summary), isFalse);
    expect(inField(title), isFalse);
  });

  test('Upload poster: Plex sends raw bytes or a link', () async {
    final reqs = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://h'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        reqs.add(o);
        h.resolve(Response(requestOptions: o, statusCode: 200));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't'),
        dio: dio);
    const movie = MediaItem(serverId: 'p', id: '42', kind: MediaKind.movie,
        title: 'Heat');
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await plex.uploadArtwork(movie, ArtworkKind.poster,
        bytes: bytes, mimeType: 'image/png');
    expect((reqs.last.method, reqs.last.path),
        ('POST', '/library/metadata/42/posters'));
    expect(reqs.last.contentType, 'image/png');
    expect(reqs.last.headers[Headers.contentLengthHeader], 4);
    expect(await (reqs.last.data as Stream<List<int>>).expand((c) => c).toList(),
        [1, 2, 3, 4]);

    await plex.uploadArtwork(movie, ArtworkKind.background,
        url: 'https://img/x.jpg');
    expect((reqs.last.path, reqs.last.queryParameters['url']),
        ('/library/metadata/42/arts', 'https://img/x.jpg'));
  });

  test('Upload poster: Jellyfin sends base64 or a link', () async {
    final reqs = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        reqs.add(o);
        h.resolve(Response(requestOptions: o, statusCode: 200));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    const movie = MediaItem(serverId: 'j', id: 'm1', kind: MediaKind.movie,
        title: 'Heat');
    await jf.uploadArtwork(movie, ArtworkKind.poster,
        bytes: Uint8List.fromList([9, 8, 7]), mimeType: 'image/jpeg');
    expect(reqs.last.path, '/Items/m1/Images/Primary');
    expect(reqs.last.data, base64Encode([9, 8, 7]));
    expect(reqs.last.contentType, 'image/jpeg');

    await jf.uploadArtwork(movie, ArtworkKind.poster, url: 'https://img/p.jpg');
    expect(reqs.last.path, '/Items/m1/RemoteImages/Download');
    expect(reqs.last.queryParameters,
        {'type': 'Primary', 'imageUrl': 'https://img/p.jpg'});
  });

  testWidgets('Upload poster from a file or a link', (tester) async {
    final original = pickImageFile;
    addTearDown(() => pickImageFile = original);
    pickImageFile = () async =>
        (bytes: Uint8List.fromList(List.filled(64, 1)), name: 'mine.png');

    await openDemoMovie(tester, 'Saltwater Kings');
    Future<void> openUpload() async {
      await tester.tap(find.byTooltip('Manage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Upload poster…'));
      await tester.pumpAndSettle();
    }

    await openUpload();
    expect(find.text('Use this link'), findsOneWidget);
    await tester.tap(find.text('Choose an image…'));
    await tester.pumpAndSettle();
    expect(find.text('mine.png'), findsOneWidget);
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    expect(find.text('Poster uploaded'), findsOneWidget);

    await openUpload();
    final link = find.ancestor(
        of: find.text('Use this link'),
        matching: find.byWidgetPredicate((w) => w is FilledButton));
    expect(tester.widget<FilledButton>(link).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'not a link');
    await tester.pump();
    expect(tester.widget<FilledButton>(link).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'https://example.com/p.jpg');
    await tester.pump();
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('Poster uploaded'), findsOneWidget);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final movie = (await container
            .read(backendsProvider)['demo']!
            .search('Saltwater Kings'))
        .first;
    expect(movie.poster!.template, 'https://example.com/p.jpg');
  });

  testWidgets('Upload background from a link', (tester) async {
    await openDemoMovie(tester, 'Paper Lanterns');
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload background…'));
    await tester.pumpAndSettle();
    expect(find.text('Upload background'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'https://example.com/bg.jpg');
    await tester.pump();
    await tester.tap(find.text('Use this link'));
    await tester.pumpAndSettle();
    expect(find.text('Background uploaded'), findsOneWidget);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final movie = (await container
            .read(backendsProvider)['demo']!
            .search('Paper Lanterns'))
        .first;
    expect(movie.backdrop!.template, 'https://example.com/bg.jpg');
    expect(movie.poster!.template, isNot('https://example.com/bg.jpg'));
  });

  testWidgets('Upload panel on a TV: starts on Choose, falls back to a link',
      (tester) async {
    final original = pickImageFile;
    addTearDown(() => pickImageFile = original);
    pickImageFile = () async => throw Exception('No activity for intent');

    await openDemoMovie(tester, 'A Quiet Orbit', tv: true);
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload poster…'));
    await tester.pumpAndSettle();
    // Enter alone reaches the picker: the panel opened on "Choose an image…".
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('This device has no file browser. Use an image link instead.'),
        findsOneWidget);
  });

  test('Delete: Plex offers it only when the server allows deletion',
      () async {
    for (final allowed in [false, true]) {
      final calls = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://h'))
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          calls.add('${o.method} ${o.path}');
          if (o.method == 'DELETE' && !allowed) {
            return h.reject(DioException(
                requestOptions: o,
                response: Response(requestOptions: o, statusCode: 403)));
          }
          h.resolve(Response(requestOptions: o, statusCode: 200, data: {
            'MediaContainer': {
              'Setting': [
                {'id': 'allowMediaDeletion', 'value': allowed},
              ]
            }
          }));
        }));
      final plex = PlexBackend(
          const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
              baseUrl: 'http://h', token: 't'),
          dio: dio);
      const movie = MediaItem(serverId: 'p', id: '42',
          kind: MediaKind.movie, title: 'Heat');
      expect((await plex.manageActions(movie)).contains(ManageAction.delete),
          allowed);
      if (allowed) {
        await plex.deleteItem(movie);
        expect(calls.last, 'DELETE /library/metadata/42');
      } else {
        await expectLater(plex.deleteItem(movie),
            throwsA(isA<BackendException>().having(
                (e) => e.message, 'message', contains('allow media deletion'))));
      }
    }
  });

  test('Delete: Jellyfin needs content deletion as well as admin', () async {
    var policy = <String, Object>{'IsAdministrator': true};
    final calls = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls.add('${o.method} ${o.path}');
        h.resolve(Response(
            requestOptions: o, statusCode: 200, data: {'Policy': policy}));
      }));
    JellyfinBackend make() => JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    const show = MediaItem(serverId: 'j', id: 's1', kind: MediaKind.show,
        title: 'Lost');
    expect(await make().manageActions(show), isNot(contains(ManageAction.delete)));
    policy = {'IsAdministrator': true, 'EnableContentDeletion': true};
    final jf = make();
    expect(await jf.manageActions(show), contains(ManageAction.delete));
    await jf.deleteItem(show);
    expect(calls.last, 'DELETE /Items/s1');
  });

  testWidgets('Delete asks first, then removes the movie everywhere',
      (tester) async {
    await openDemoMovie(tester, 'Ember & Ash');
    Future<void> openDelete() async {
      await tester.tap(find.byTooltip('Manage'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
    }

    await openDelete();
    expect(find.text('Delete Ember & Ash?'), findsOneWidget);
    expect(find.textContaining("permanently deletes this movie's files"),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Manage'), findsOneWidget); // still on the page

    await openDelete();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted Ember & Ash'), findsOneWidget);
    // Back on the library grid, which reloaded without it.
    expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
    expect(find.text('Ember & Ash'), findsNothing);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    expect(
        await container.read(backendsProvider)['demo']!.search('Ember'),
        isEmpty);
  });

  testWidgets('Delete dialog on a TV: OK on the default button cancels',
      (tester) async {
    await openDemoMovie(tester, 'Blue Hour', tv: true);
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Delete Blue Hour?'), findsNothing);
    expect(find.byTooltip('Manage'), findsOneWidget);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    expect(
        await container.read(backendsProvider)['demo']!.search('Blue Hour'),
        isNotEmpty);
  });

  test('Delete playlist: offered to any user, with the right request',
      () async {
    final calls = <String>[];
    Dio fake(String base) => Dio(BaseOptions(baseUrl: base))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        calls.add('${o.method} ${o.path}');
        // Not an admin, and Plex doesn't allow media deletion.
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'Policy': {'IsAdministrator': false},
          'MediaContainer': {
            'Setting': [
              {'id': 'allowMediaDeletion', 'value': false}
            ]
          },
        }));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't'),
        dio: fake('http://h'));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: fake('http://jf'));
    const plexList = MediaItem(serverId: 'p', id: '9',
        kind: MediaKind.playlist, title: 'Mine');
    const jfList = MediaItem(serverId: 'j', id: 'pl1',
        kind: MediaKind.playlist, title: 'Mine');

    // Item count unknown is not empty, so removing is offered too.
    const both = {ManageAction.removeFromPlaylist, ManageAction.deletePlaylist};
    expect(await plex.manageActions(plexList), both);
    expect(await jf.manageActions(jfList), both);
    await plex.deletePlaylist(plexList);
    expect(calls.last, 'DELETE /playlists/9');
    await jf.deletePlaylist(jfList);
    expect(calls.last, 'DELETE /Items/pl1');
  });

  testWidgets('a playlist can be deleted from its page', (tester) async {
    await _pump(tester, const Size(1440, 900));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final demo = container.read(backendsProvider)['demo']!;
    final movie = (await demo.search('Wild Meridian')).first;
    await demo.createPlaylist('Road trip', movie);
    container.invalidate(playlistsProvider);

    await tester.tap(find.text('Libraries').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    // On a playlist, only the playlist itself can be managed.
    expect(find.text('Remove from playlist…'), findsOneWidget);
    expect(find.text('Delete playlist…'), findsOneWidget);
    expect(find.text('Delete…'), findsNothing);
    expect(find.text('Refresh metadata'), findsNothing);
    await tester.tap(find.text('Delete playlist…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete the playlist "Road trip"?'), findsOneWidget);
    expect(find.textContaining('stays in your libraries'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Deleted Road trip'), findsOneWidget);
    expect(find.text('Road trip'), findsNothing); // gone from Libraries
    expect(find.text('Friday Night'), findsOneWidget); // others untouched
    expect(await demo.search('Wild Meridian'), isNotEmpty); // media kept
  });

  testWidgets('TV: remove from playlist takes out the focused video',
      (tester) async {
    await _pump(tester, const Size(1920, 1080), tv: true);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final demo = container.read(backendsProvider)['demo']!;
    final orbit = (await demo.search('A Quiet Orbit')).first;
    final copper = (await demo.search('Copper Sky')).first;
    final blue = (await demo.search('Blue Hour')).first;
    await demo.createPlaylist('Cleanup', orbit);
    final cleanup = (await demo.playlists()).firstWhere((p) => p.title == 'Cleanup');
    await demo.addToPlaylist(cleanup, copper);
    await demo.addToPlaylist(cleanup, blue);
    container.invalidate(playlistsProvider);

    await tester.tap(find.text('Libraries').first);
    await tester.pumpAndSettle();
    // Late on the TV page: bring it on screen before tapping.
    await tester.ensureVisible(find.text('Cleanup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cleanup'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from playlist…'));
    await tester.pumpAndSettle();

    final rows = find.byWidgetPredicate((w) =>
        w is Pressable &&
        (w.focusNode?.debugLabel?.startsWith('playlist entry') ?? false));
    String focusedTitle() {
      final ctx = FocusManager.instance.primaryFocus?.context;
      for (var i = 0; i < rows.evaluate().length; i++) {
        final row = tester.element(rows.at(i));
        var inRow = identical(ctx, row);
        ctx?.visitAncestorElements((e) => !(inRow = inRow || identical(e, row)));
        if (inRow) {
          return tester.widget<Text>(find.descendant(
                  of: rows.at(i), matching: find.byType(Text)).first).data!;
        }
      }
      return 'focus outside the rows';
    }

    expect(rows, findsNWidgets(3));
    expect(focusedTitle(), 'A Quiet Orbit');

    // OK on the middle one removes it at once (no confirmation); the panel
    // stays open and focus takes the video that moved up into its place.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedTitle(), 'Copper Sky');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Removed Copper Sky'), findsOneWidget);
    expect(rows, findsNWidgets(2));
    expect(focusedTitle(), 'Blue Hour');

    // Removing the last row moves focus back to the one before it.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(focusedTitle(), 'A Quiet Orbit');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('This playlist is empty.'), findsOneWidget);

    // The page behind updates; the media itself stays.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Copper Sky'), findsNothing);
    expect(find.text('Blue Hour'), findsNothing);
    expect(await demo.search('Copper Sky'), isNotEmpty);
  });

  testWidgets('TV: remove from a long playlist builds only the rows on screen',
      (tester) async {
    await _pump(tester, const Size(1920, 1080), tv: true);
    tester.view.devicePixelRatio = 2; // real TV density: ~6 rows fit
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final demo = container.read(backendsProvider)['demo']!;
    final movies = await demo.libraryItems(
        const Library(serverId: 'demo', id: 'movies', title: 'Movies',
            kind: LibraryKind.movies),
        start: 0, limit: 20);
    await demo.createPlaylist('Marathon', movies.items.first);
    final marathon =
        (await demo.playlists()).firstWhere((p) => p.title == 'Marathon');
    for (var n = 1; n < 40; n++) {
      await demo.addToPlaylist(marathon, movies.items[n % movies.items.length]);
    }
    container.invalidate(playlistsProvider);

    await tester.tap(find.text('Libraries').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Marathon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marathon'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from playlist…'));
    await tester.pumpAndSettle();

    final rows = find.byWidgetPredicate((w) =>
        w is Pressable &&
        (w.focusNode?.debugLabel?.startsWith('playlist entry') ?? false));
    expect(rows, findsWidgets);
    // Only what's on screen (plus a little ahead) is built, so a long
    // playlist doesn't start every thumbnail at once.
    expect(rows.evaluate().length, lessThan(20));

    String? focusedEntry() {
      final ctx = FocusManager.instance.primaryFocus?.context;
      String? id;
      ctx?.visitAncestorElements((e) {
        if (e.widget is Pressable && e.widget.key is ValueKey<String>) {
          id = (e.widget.key! as ValueKey<String>).value;
          return false;
        }
        return true;
      });
      return id;
    }

    expect(focusedEntry(), '0');
    // The remote still reaches rows far down the list.
    for (var n = 0; n < 25; n++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(focusedEntry(), '25');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(focusedEntry(), '26');
  });

  testWidgets('remove from playlist lays out as a phone bottom sheet',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Libraries').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Friday Night'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Friday Night'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from playlist…'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byWidgetPredicate((w) =>
        w is Pressable &&
        (w.focusNode?.debugLabel?.startsWith('playlist entry') ?? false)),
        findsWidgets);
  });

  testWidgets('TV: a refused removal keeps the row, its focus and says why',
      (tester) async {
    Artwork.network = false;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final dio = Dio(BaseOptions(baseUrl: 'http://h'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'DELETE') {
          // A real server takes a moment: the rows rebuild while it runs.
          Future<void>.delayed(const Duration(milliseconds: 300), () =>
              h.reject(DioException(
                  requestOptions: o,
                  response: Response(requestOptions: o, statusCode: 403))));
          return;
        }
        final data = switch (o.path) {
          '/playlists/9' => {'MediaContainer': {'Metadata': [
              {'ratingKey': '9', 'type': 'playlist', 'title': 'Shared',
               'leafCount': 2}]}},
          '/playlists/9/items' => {'MediaContainer': {'Metadata': [
              {'ratingKey': '1', 'playlistItemID': 10, 'type': 'movie', 'title': 'Heat'},
              {'ratingKey': '2', 'playlistItemID': 11, 'type': 'movie', 'title': 'Ronin'},
            ]}},
          _ => {'MediaContainer': {}},
        };
        h.resolve(Response(
            requestOptions: o, data: jsonDecode(jsonEncode(data)), statusCode: 200));
      }));
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't', machineId: 'm'),
        dio: dio);
    final playlist = plex.parse(
        {'ratingKey': '9', 'type': 'playlist', 'title': 'Shared', 'leafCount': 2});
    final storage = await _storage(demo: false);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        deviceIsTvProvider.overrideWithValue(true),
        backendsProvider.overrideWithValue(<String, MediaBackend>{'p': plex}),
      ],
      retry: (_, _) => null,
      child: MaterialApp(
        home: Scaffold(body: Center(child: ManageButton(item: playlist))),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from playlist…'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    // Told why, in a snackbar that shows however far the list is scrolled.
    expect(find.descendant(of: find.byType(SnackBar),
        matching: find.textContaining('Only its owner can')), findsOneWidget);
    final rows = find.byWidgetPredicate((w) =>
        w is Pressable &&
        (w.focusNode?.debugLabel?.startsWith('playlist entry') ?? false));
    expect(rows, findsNWidgets(2));
    // The remote is still on the row it pressed.
    final ctx = FocusManager.instance.primaryFocus?.context;
    final ronin = tester.element(rows.at(1));
    var onRow = identical(ctx, ronin);
    ctx?.visitAncestorElements((e) => !(onRow = onRow || identical(e, ronin)));
    expect(onRow, isTrue, reason: 'focus: ${FocusManager.instance.primaryFocus}');
  });

  testWidgets('TV: delete a version asks first, Cancel focused', (tester) async {
    Artwork.network = false;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final deletes = <String>[];
    final plex = PlexBackend(
        const ServerConfig(id: 'p', kind: ServerKind.plex, name: 'P',
            baseUrl: 'http://h', token: 't'),
        dio: fakePlexWithVersions(deletes, allow: true));
    // Real time: Dio's own timers never fire in the test's fake clock.
    final movie = (await tester.runAsync(() => plex.item('42')))!;
    final storage = await _storage(demo: false);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        deviceIsTvProvider.overrideWithValue(true),
        backendsProvider.overrideWithValue(<String, MediaBackend>{'p': plex}),
      ],
      retry: (_, _) => null,
      child: MaterialApp(
        home: Scaffold(body: Center(child: ManageButton(item: movie))),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete a version…'));
    await tester.pumpAndSettle();

    expect(find.text('Delete a version'), findsOneWidget);
    final rows = find.descendant(
        of: find.ancestor(
            of: find.text('Delete a version'),
            matching: find.byType(SingleChildScrollView)).first,
        matching: find.byType(ListTile));
    expect(rows, findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    // A stray OK on the confirmation cancels: Cancel has focus.
    expect(find.text('Delete the 720p version of Heat?'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(deletes, isEmpty);
    expect(find.text('Delete the 720p version of Heat?'), findsNothing);

    await tester.tap(rows.at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deletes, ['/library/metadata/42/media/2']);
    expect(find.text('Deleted the 720p version'), findsOneWidget);
    expect(find.text('Delete a version'), findsNothing); // panel closed
  });

  test('home or away is decided from the server address', () {
    for (final home in [
      'http://192.168.1.20:32400', 'http://10.0.0.5:8096',
      'https://172.20.1.2:8920', 'http://localhost:8096', 'http://nas:8096',
      'http://media.local:8096', 'http://100.101.1.2:32400',
      'https://192-168-1-10.abc123def.plex.direct:32400',
      'http://[fd00::1]:8096',
    ]) {
      expect(isLocalAddress(home), isTrue, reason: home);
    }
    for (final away in [
      'https://jellyfin.example.com', 'http://203.0.113.9:32400',
      'https://203-0-113-9.abc123def.plex.direct:32400',
      'https://172.32.0.1', 'http://[2001:db8::1]:8096',
    ]) {
      expect(isLocalAddress(away), isFalse, reason: away);
    }
  });

  test('home/away quality: old saves apply one choice to both', () {
    final old = AppSettings.fromJson({'maxBitrateKbps': 8000}, const {});
    expect((old.maxBitrateKbps, old.remoteMaxBitrateKbps), (8000, 8000));
    final both = AppSettings.fromJson(
        {'maxBitrateKbps': null, 'remoteMaxBitrateKbps': 4000}, const {});
    expect(both.maxBitrateFor(local: true), isNull);
    expect(both.maxBitrateFor(local: false), 4000);
    final round = AppSettings.fromJson(
        const AppSettings(remoteMaxBitrateKbps: 2000).toJson(), const {});
    expect((round.maxBitrateKbps, round.remoteMaxBitrateKbps), (null, 2000));
  });

  test('Plex treats the quality as a maximum', () async {
    final plex = PlexBackend(const ServerConfig(id: 'p', kind: ServerKind.plex,
        name: 'P', baseUrl: 'http://h', token: 't'));
    final movie = plex.parse({
      'ratingKey': '42', 'type': 'movie', 'title': 'Heat',
      'Media': [
        {'id': 1, 'bitrate': 6000, 'Part': [
          {'id': 5, 'key': '/library/parts/5/file.mkv',
           'Stream': [{'id': 9, 'streamType': 1, 'codec': 'h264'}]}
        ]}
      ],
    });
    Future<PlaybackSource> play(PlaybackRequest r) => plex.playback(movie, r);

    final fits = await play(const PlaybackRequest(maxBitrateKbps: 8000));
    expect(fits.method, PlayMethod.directPlay);
    final tooBig = await play(const PlaybackRequest(maxBitrateKbps: 4000));
    expect(tooBig.method, PlayMethod.transcode);
    expect(Uri.parse(tooBig.url).queryParameters['maxVideoBitrate'], '4000');
    final forced = await play(const PlaybackRequest(forceTranscode: true));
    expect(forced.method, PlayMethod.transcode);
    expect(Uri.parse(forced.url).queryParameters['maxVideoBitrate'], '20000');
    plex.dispose();
  });

  test('Jellyfin keeps direct play allowed under a maximum', () async {
    final bodies = <Map<String, dynamic>>[];
    var serverSaysDirect = true;
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        bodies.add(o.data as Map<String, dynamic>);
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'PlaySessionId': 's',
          'MediaSources': [
            {'Id': 'm1', 'SupportsDirectPlay': serverSaysDirect,
             'SupportsDirectStream': false,
             'TranscodingUrl': '/videos/m1/master.m3u8?x=1'}
          ],
        }));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    const movie = MediaItem(serverId: 'j', id: 'm1', kind: MediaKind.movie,
        title: 'Heat');

    final under = await jf.playback(movie, const PlaybackRequest(maxBitrateKbps: 8000));
    expect(bodies.last['EnableDirectPlay'], isTrue);
    expect(bodies.last['MaxStreamingBitrate'], 8000000);
    expect(under.method, PlayMethod.directPlay);

    serverSaysDirect = false; // file is over the limit
    final over = await jf.playback(movie, const PlaybackRequest(maxBitrateKbps: 2000));
    expect(over.method, PlayMethod.transcode);
    expect(over.url, 'http://jf/videos/m1/master.m3u8?x=1');

    serverSaysDirect = true;
    final forced = await jf.playback(movie, const PlaybackRequest(forceTranscode: true));
    expect(bodies.last['EnableDirectPlay'], isFalse);
    expect(bodies.last['MaxStreamingBitrate'], 20000000);
    expect(forced.method, PlayMethod.transcode);
  });

  testWidgets('away-from-home quality is its own setting', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maximum quality away from home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p · 4 Mbps').last);
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    final s = container.read(settingsProvider);
    expect((s.maxBitrateKbps, s.remoteMaxBitrateKbps), (null, 4000));
    expect(find.text('Original (no limit)'), findsOneWidget); // home unchanged
  });

  test('HD only: Plex converts HDR and 4K to 1080p, leaves HD alone',
      () async {
    final plex = PlexBackend(const ServerConfig(id: 'p', kind: ServerKind.plex,
        name: 'P', baseUrl: 'http://h', token: 't'));
    MediaItem movie(String id, {required int w, required int h,
            bool dv = false, int kbps = 15000}) =>
        plex.parse({
          'ratingKey': id, 'type': 'movie', 'title': id,
          'Media': [
            {'id': 1, 'bitrate': kbps, 'width': w, 'height': h, 'Part': [
              {'id': 5, 'key': '/library/parts/5/file.mkv', 'Stream': [
                {'id': 9, 'streamType': 1, 'codec': 'hevc',
                 'DOVIPresent': dv, if (!dv && w > 1920) 'colorTrc': 'smpte2084'}
              ]}
            ]}
          ],
        });
    const hdOnly = PlaybackRequest(sdrOnly: true);
    Map<String, String> q(PlaybackSource s) => Uri.parse(s.url).queryParameters;

    final hd = await plex.playback(movie('hd', w: 1920, h: 1080), hdOnly);
    expect(hd.method, PlayMethod.directPlay);

    final dvHd = await plex.playback(movie('dv', w: 1920, h: 1080, dv: true), hdOnly);
    expect(dvHd.method, PlayMethod.transcode);
    expect(q(dvHd)['videoResolution'], '1920x1080');

    final uhd = await plex.playback(
        movie('uhd', w: 3840, h: 2160, kbps: 60000),
        const PlaybackRequest(sdrOnly: true, maxBitrateKbps: 40000));
    expect(uhd.method, PlayMethod.transcode);
    expect((q(uhd)['videoResolution'], q(uhd)['maxVideoBitrate']),
        ('1920x1080', '20000'));

    // With HDR allowed, the same 4K file plays untouched under no limit.
    final allowed = await plex.playback(
        movie('uhd2', w: 3840, h: 2160, kbps: 60000), const PlaybackRequest());
    expect(allowed.method, PlayMethod.directPlay);
    plex.dispose();
  });

  test('HD only: Jellyfin profile limits direct play to SDR 1080p', () async {
    final bodies = <Map<String, dynamic>>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://jf'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        bodies.add(o.data as Map<String, dynamic>);
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'MediaSources': [
            {'Id': 'm1', 'SupportsDirectPlay': true}
          ],
        }));
      }));
    final jf = JellyfinBackend(
        const ServerConfig(id: 'j', kind: ServerKind.jellyfin, name: 'J',
            baseUrl: 'http://jf', token: 't', userId: 'u'),
        dio: dio);
    const movie = MediaItem(serverId: 'j', id: 'm1', kind: MediaKind.movie,
        title: 'Heat');
    List<dynamic> codecProfiles() =>
        (bodies.last['DeviceProfile'] as Map)['CodecProfiles'] as List;

    await jf.playback(movie, const PlaybackRequest());
    expect(codecProfiles(), isEmpty);
    await jf.playback(movie, const PlaybackRequest(sdrOnly: true));
    final conditions = (codecProfiles().single as Map)['Conditions'] as List;
    expect(
        conditions.map((c) => '${c['Property']} ${c['Condition']} ${c['Value']}'),
        ['VideoRangeType EqualsAny SDR', 'Width LessThanEqual 1920',
         'Height LessThanEqual 1080']);
  });

  test('HD only: demo 4K converts; setting saves and defaults on', () async {
    expect(const AppSettings().allowHdr, isTrue);
    expect(AppSettings.fromJson(const {}, const {}).allowHdr, isTrue);
    final off = AppSettings.fromJson(
        const AppSettings(allowHdr: false).toJson(), const {});
    expect(off.allowHdr, isFalse);

    final demo = DemoBackend(demoServer);
    final uhd = (await demo.search('The Long Tide')).first; // a 4K title
    final full = await demo.item(uhd.id);
    expect(full.versions.first.beyondHd, isTrue);
    expect((await demo.playback(full, const PlaybackRequest())).method,
        PlayMethod.directPlay);
    expect(
        (await demo.playback(full, const PlaybackRequest(sdrOnly: true)))
            .method,
        PlayMethod.transcode);
  });

  testWidgets('Play HDR and 4K can be turned off in Settings', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Play HDR and 4K'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play HDR and 4K'));
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MarqueeApp)));
    expect(container.read(settingsProvider).allowHdr, isFalse);
  });

  test('backend errors reach the user verbatim', () {
    expect(friendlyError(const BackendException('That PIN wasn\'t right.')),
        'That PIN wasn\'t right.');
  });
}
