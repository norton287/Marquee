import 'package:flutter/services.dart';

import 'car_log.dart';

/// Diagnostics for Android Auto: a native watcher (CarWatch.kt) looks at
/// Marquee's media session from the outside, as the car does, and each change
/// it sees becomes a "car sees …" line in the car log. Comparing those with
/// the handler's own "state …" lines shows what actually reached Android and
/// in which order. Phones only; elsewhere there's no native side.
///
/// [errors]: audio_service's `AudioService.asyncError`. It catches every
/// native failure (play state, song info, queue) and reports it only there,
/// so a session that failed to start (e.g. Android refusing the foreground
/// service, which also skips making the session active) left no trace.
Future<void> watchCarSession(CarLog log,
    {MethodChannel channel = const MethodChannel('app.marquee.marquee/car_watch'),
    Stream<Object>? errors}) async {
  errors?.listen((e) => log.add('session error: $e'));
  channel.setMethodCallHandler((call) async {
    if (call.method == 'log') log.add('car sees ${call.arguments}');
  });
  // Logged so a log without "car sees" lines tells an old build (no line)
  // from a watch that couldn't start (says why).
  log.add('session watch: starting');
  try {
    await channel.invokeMethod<void>('start');
  } on MissingPluginException {
    channel.setMethodCallHandler(null);
    log.add('session watch unavailable: no native side');
  } on PlatformException catch (e) {
    channel.setMethodCallHandler(null);
    log.add('session watch unavailable: ${e.message}');
  }
}
