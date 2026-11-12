import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/backend.dart';
import 'core/providers.dart';
import 'core/storage.dart';

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

  runApp(ProviderScope(
    overrides: [
      storageProvider.overrideWithValue(storage),
      deviceIsTvProvider.overrideWithValue(isTv),
    ],
    // Failures show a Retry button instead of retrying behind the user's back.
    retry: (_, _) => null,
    child: const MarqueeApp(),
  ));
}
