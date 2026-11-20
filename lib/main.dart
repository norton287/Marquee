import 'dart:async';
import 'dart:io';

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
import 'core/car_log.dart';
import 'core/car_watch.dart';
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
  // What the car asks and Marquee answers, kept across restarts.
  final carLog = CarLog(save: storage.saveCarLog)..load(await storage.readCarLog());

  final container = ProviderContainer(
    overrides: [
      storageProvider.overrideWithValue(storage),
      carLogProvider.overrideWithValue(carLog),
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

/// The car's own art folder (`<cache>/car_art`), served by ArtProvider.kt.
/// Only car art goes in it (the app's image cache holds everything else the
/// user looked at), under unguessable names (`carArtName`).
String? _carArtDir;
var _carArtCopies = 0;

/// The car's list art: [remote] downloaded (through audio_service's image
/// cache) and copied into the car folder, as a `content://` link.
Future<Uri?> _carArt(Uri remote, {required CarArtMode mode}) async {
  final name = carArtName(remote.toString());
  final link = Uri(
      scheme: 'content', host: 'app.marquee.marquee.art', pathSegments: [name]);
  final known = _carArtDir;
  if (known != null && File('$known/$name').existsSync()) return link;
  if (mode == CarArtMode.cachedOnly) return null;
  Future<Uri?> fetch() async {
    final file = await AudioService.cacheManager.getSingleFile(remote.toString());
    // The image cache lives in <cache>/libCachedImageData.
    final dir = _carArtDir ??= '${file.parent.parent.path}/car_art';
    await Directory(dir).create(recursive: true);
    await file.copy('$dir/$name');
    if (++_carArtCopies % 50 == 0) unawaited(_pruneCarArt(dir));
    return link;
  }

  if (mode == CarArtMode.background) {
    // Ready for the next time this list is shown.
    unawaited(fetch().then((_) {}, onError: (Object _) {}));
    return null;
  }
  return fetch();
}

/// Keeps the car folder to the 1500 most recently fetched images.
Future<void> _pruneCarArt(String dir) async {
  try {
    final files = Directory(dir).listSync().whereType<File>().toList();
    if (files.length <= 1500) return;
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final f in files.skip(1500)) {
      f.deleteSync();
    }
  } catch (_) {}
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

  // The car's lists from the last run: there for the car's first request.
  final storage = container.read(storageProvider);
  final lastLists = await storage.readCarLists();
  try {
    final handler = await AudioService.init(
      builder: () => MarqueeAudioHandler(
        engine,
        CarLibrary(
          () => container.read(backendsProvider),
          (serverId) => freshLibraries(container, serverId),
          reconnect: (id) => container.read(serversProvider.notifier).revalidate(id),
          // Settings → Android Auto: one library, or all.
          only: () => container.read(settingsProvider).carMusicLibrary,
          isHidden: (server, library) =>
              container.read(settingsProvider).hiddenOn(server).contains(library),
        ),
        // Not audio_service's own notifyChildrenChanged: it sends null
        // options, which androidx refuses (see notifyCarListChanged).
        notifyChanged: notifyCarListChanged,
        // A private copy: artwork links carry the server token.
        localArt: (remote) async => Uri.file(
            (await AudioService.cacheManager.getSingleFile(remote.toString())).path),
        carArt: _carArt,
        log: container.read(carLogProvider),
        remember: storage.saveCarLists,
        // The lists belong to this car library, these servers and profiles.
        rememberKey: () {
          final library = container.read(settingsProvider).carMusicLibrary ?? 'all';
          final servers = [
            for (final s in container.read(serversProvider)) '${s.id}:${s.userId ?? ''}',
          ]..sort();
          return '$library|${servers.join(',')}';
        },
      )..restore(lastLists),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'app.marquee.marquee.music',
        androidNotificationChannelName: 'Music',
        // Stays in the foreground while paused: Android 12+ refuses to
        // restart a background service on resume. Stop closes it.
        androidStopForegroundOnPause: false,
        // Shows the car's search button (voice works either way).
        androidBrowsableRootExtras: MarqueeAudioHandler.rootExtras,
      ),
    );
    // What the car actually receives, for the car log: first, so nothing
    // after it can keep the diagnostics from starting.
    await watchCarSession(container.read(carLogProvider),
        errors: AudioService.asyncError);
    // A car that asked for the menu before Dart was ready may have an empty
    // one (never throws); and servers, libraries or the profile changing
    // changes every list.
    await handler.refreshRoot();
    container.listen(backendsProvider, (_, _) => handler.refreshAll());
    container.listen(settingsProvider.select((s) => s.carMusicLibrary),
        (_, _) => handler.refreshAll(clear: true));
  } catch (e) {
    // Music still plays in the app without the session.
    debugPrint('Music session unavailable: $e');
  }
}
