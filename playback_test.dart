// Drives real playback on a desktop build against a local stand-in server.
// Run with: flutter test integration_test/playback_test.dart -d linux
//   --dart-define=JF_URL=http://127.0.0.1:8096 --dart-define=SHOTS=/some/dir
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:marquee/app.dart';
import 'package:marquee/core/models.dart';
import 'package:marquee/core/providers.dart';
import 'package:marquee/core/storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

const _url = String.fromEnvironment('JF_URL');
const _shots = String.fromEnvironment('SHOTS');

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  if (_shots.isEmpty) return;
  await Process.run('import', ['-window', 'root', '$_shots/$name.png']);
}

/// Real time has to pass for video; pump frames while it does.
Future<void> _wait(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Brings the player controls up if they have auto-hidden.
Future<void> _wake(WidgetTester tester) async {
  if (find.byTooltip('Quality and playback').evaluate().isNotEmpty) return;
  await tester.tapAt(const Offset(400, 200));
  // Single taps wait out the double-tap window.
  await _wait(tester, const Duration(milliseconds: 700));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('resume, tracks, chapters, transcode, next episode',
      (tester) async {
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    final storage = AppStorage(MemoryStore());
    await storage.load();
    await storage.saveServers(const [
      ServerConfig(
        id: 'jf',
        kind: ServerKind.jellyfin,
        name: 'Fake',
        baseUrl: _url,
        token: 'tok',
        userId: 'u1',
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [storageProvider.overrideWithValue(storage)],
      retry: (_, _) => null,
      child: const MarqueeApp(),
    ));
    await _wait(tester, const Duration(seconds: 2));
    expect(find.text('Resume'), findsOneWidget);
    await _shot(tester, '01_home');

    // Resume from the hero: should direct play from ~20s.
    await tester.tap(find.text('Resume'));
    await _wait(tester, const Duration(seconds: 5));
    await _shot(tester, '02_playing_resumed');
    expect(find.text('DIRECT PLAY'), findsOneWidget);

    // The intro marker (22–32s) should offer a skip.
    await _wait(tester, const Duration(seconds: 2));
    await _shot(tester, '03_skip_intro');
    expect(find.text('Skip intro'), findsOneWidget);
    await tester.tap(find.text('Skip intro'));
    await _wait(tester, const Duration(seconds: 2));

    // Audio and subtitles.
    await _wake(tester);
    await _shot(tester, '03b_controls');
    await tester.tap(find.byTooltip('Audio and subtitles'));
    await _wait(tester, const Duration(seconds: 1));
    await _shot(tester, '04_tracks_panel');
    expect(find.textContaining('SPA'), findsOneWidget);
    await tester.tap(find.textContaining('ENG').last); // the subtitle track
    await _wait(tester, const Duration(seconds: 2));
    await _shot(tester, '05_subtitles_on');

    // Chapters.
    await _wake(tester);
    await tester.tap(find.byTooltip('Chapters'));
    await _wait(tester, const Duration(seconds: 1));
    await _shot(tester, '06_chapters_panel');
    await tester.tap(find.text('Opening'));
    await _wait(tester, const Duration(seconds: 2));
    await _shot(tester, '07_after_chapter_seek');

    // Switch to a transcoded quality; position should carry over.
    await _wake(tester);
    await tester.tap(find.byTooltip('Quality and playback'));
    await _wait(tester, const Duration(seconds: 1));
    await _shot(tester, '08_quality_panel');
    await tester.tap(find.text('720p · 4 Mbps'));
    await _wait(tester, const Duration(seconds: 5));
    await _wake(tester);
    await _shot(tester, '09_transcoding');
    expect(find.text('TRANSCODING'), findsOneWidget);

    // Jump near the end: up-next should appear and roll into episode 2.
    await _wake(tester);
    await tester.tap(find.byTooltip('Chapters'));
    await _wait(tester, const Duration(seconds: 1));
    await tester.tap(find.text('Finale'));
    await _wait(tester, const Duration(seconds: 1));
    await _wait(tester, const Duration(seconds: 3));
    await _shot(tester, '10_up_next');
    expect(find.text('Play now'), findsOneWidget);
    await tester.tap(find.text('Play now'));
    await _wait(tester, const Duration(seconds: 5));
    await _wake(tester);
    await _shot(tester, '11_next_episode');
    expect(find.textContaining('Episode 2'), findsWidgets);

    // Leave: the final position must be reported.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _wait(tester, const Duration(seconds: 2));
    await _shot(tester, '12_back_home');
  });
}
