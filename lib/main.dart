import 'package:audio_service/audio_service.dart';
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

  // One container for the app and the music session: on an Android Auto cold
  // start main() runs with no window, and the car needs the same servers and
  // music engine the app uses.
  final container = ProviderContainer(
    overrides: [
      storageProvider.overrideWithValue(storage),
      deviceIsTvProvider.overrideWithValue(isTv),
    ],
    // Failures show a Retry button instead of retrying behind the user's back.
    retry: (_, _) => null,
  );
  // Phones and tablets: lock screen, headset buttons and Android Auto. A TV
  // keeps music in the app only.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && !isTv) {
    await _startMusicSession(container);
  }
  runApp(UncontrolledProviderScope(
    container: container,
    child: const MarqueeApp(),
  ));
}

Future<void> _startMusicSession(ProviderContainer container) async {
  try {
    final handler = await AudioService.init(
      builder: () => MarqueeAudioHandler(
        container.read(musicEngineProvider),
        CarLibrary(() => container.read(backendsProvider),
            (serverId) => container.read(librariesProvider(serverId).future)),
        // ignore: deprecated_member_use
        notifyChanged: (id) => AudioServiceBackground.notifyChildrenChanged(id),
      ),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'app.marquee.marquee.music',
        androidNotificationChannelName: 'Music',
        // Stays in the foreground while paused: Android 12+ refuses to
        // restart a background service on resume.
        androidStopForegroundOnPause: false,
      ),
    );
    // A car that asked for the menu before Dart was ready got an empty one.
    await handler.refreshRoot();
  } catch (e) {
    // Music still plays in the app without the session.
    debugPrint('Music session unavailable: $e');
  }
}
