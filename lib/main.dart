import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/audio_handler.dart';
import 'core/backend.dart';
import 'core/car_library.dart';
import 'core/models.dart';
import 'core/providers.dart';
import 'core/storage.dart';
import 'ui/music.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final storage = AppStorage(await DeviceStore.open());
  await storage.load();
  ClientInfo.clientId = storage.clientId;

  var isTv = false;
  if (!kIsWeb) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        ClientInfo.platform = 'Android';
        try {
          final info = await DeviceInfoPlugin().androidInfo;
          ClientInfo.deviceName = info.model;
          isTv = info.systemFeatures.contains('android.software.leanback') ||
              info.systemFeatures.contains('amazon.hardware.fire_tv');
        } catch (_) {}
      case TargetPlatform.iOS:
        ClientInfo.platform = 'iOS';
        try {
          ClientInfo.deviceName = (await DeviceInfoPlugin().iosInfo).name;
        } catch (_) {}
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        ClientInfo.platform = switch (defaultTargetPlatform) {
          TargetPlatform.macOS => 'macOS',
          TargetPlatform.windows => 'Windows',
          _ => 'Linux',
        };
        ClientInfo.deviceName = '${ClientInfo.product} for ${ClientInfo.platform}';
        // Full screen and the mini-player window.
        await windowManager.ensureInitialized();
      default:
        break;
    }
  }

  // Phones and tablets get the music session: lock screen, headset buttons
  // and Android Auto. A TV keeps music in the app only.
  final musicSession =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android && !isTv;
  AudioSession? audio;
  if (musicSession) {
    try {
      audio = await AudioSession.instance;
      await audio.configure(const AudioSessionConfiguration.music());
    } catch (_) {
      audio = null;
    }
  }
  final focus = audio;

  // One container for the app and the music session: on an Android Auto cold
  // start main() runs with no window, and the car needs the same servers and
  // music engine the app uses.
  final container = ProviderContainer(
    overrides: [
      storageProvider.overrideWithValue(storage),
      deviceIsTvProvider.overrideWithValue(isTv),
      // Music asks for audio focus first: other apps pause or duck.
      if (focus != null)
        musicFocusProvider.overrideWithValue(() => focus.setActive(true)),
    ],
    // Failures show a Retry button instead of retrying behind the user's back.
    retry: (_, _) => null,
  );
  if (musicSession) await _startMusicSession(container, focus);
  runApp(UncontrolledProviderScope(
    container: container,
    child: const MarqueeApp(),
  ));
}

Future<void> _startMusicSession(
    ProviderContainer container, AudioSession? focus) async {
  final engine = container.read(musicEngineProvider);
  // The car's Bluetooth dropped (car off) or headphones came out: pause
  // rather than play from the phone's speaker.
  focus?.becomingNoisyEventStream.listen((_) => engine.pause());
  // Calls and other music apps pause us; Android ducks for navigation on
  // its own. Resume after a pause-type interruption if we were playing.
  var resume = false;
  focus?.interruptionEventStream.listen((e) {
    if (e.type == AudioInterruptionType.duck) return;
    if (e.begin) {
      resume = engine.state.playing && e.type == AudioInterruptionType.pause;
      engine.pause();
    } else if (resume) {
      resume = false;
      engine.play();
    }
  });

  /// The car reads visible libraries; a failed load is retried on the next
  /// look instead of staying an error (the container doesn't retry).
  Future<List<Library>> libraries(String serverId) async {
    try {
      return await container.read(librariesProvider(serverId).future);
    } catch (_) {
      container.invalidate(librariesProvider(serverId));
      rethrow;
    }
  }

  try {
    final handler = await AudioService.init(
      builder: () => MarqueeAudioHandler(
        engine,
        CarLibrary(
          () => container.read(backendsProvider),
          libraries,
          reconnect: (id) => container.read(serversProvider.notifier).revalidate(id),
        ),
        // ignore: deprecated_member_use
        notifyChanged: (id) => AudioServiceBackground.notifyChildrenChanged(id),
        // A private copy: artwork links carry the server token.
        localArt: (remote) async => Uri.file(
            (await AudioService.cacheManager.getSingleFile(remote.toString())).path),
      ),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'app.marquee.marquee.music',
        androidNotificationChannelName: 'Music',
        // Stays in the foreground while paused: Android 12+ refuses to
        // restart a background service on resume. Stop closes it.
        androidStopForegroundOnPause: false,
        // Shows the car's search button (voice works either way).
        androidBrowsableRootExtras: {'android.media.browse.SEARCH_SUPPORTED': true},
      ),
    );
    // A car that asked for the menu before Dart was ready may have an empty
    // one; and servers, libraries or the profile changing changes every list.
    await handler.refreshRoot();
    container.listen(backendsProvider, (_, _) => handler.refreshAll());
  } catch (e) {
    // Music still plays in the app without the session.
    debugPrint('Music session unavailable: $e');
  }
}
