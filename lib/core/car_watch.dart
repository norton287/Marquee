import 'package:flutter/services.dart';

import 'car_log.dart';

/// Diagnostics for Android Auto: a native watcher (CarWatch.kt) looks at
/// Marquee's media session from the outside, as the car does, and each change
/// it sees becomes a "car sees …" line in the car log. Comparing those with
/// the handler's own "state …" lines shows what actually reached Android and
/// in which order. Phones only; elsewhere there's no native side.
Future<void> watchCarSession(CarLog log,
    {MethodChannel channel = const MethodChannel('app.marquee.marquee/car_watch')}) async {
  channel.setMethodCallHandler((call) async {
    if (call.method == 'log') log.add('car sees ${call.arguments}');
  });
  try {
    await channel.invokeMethod<void>('start');
  } on MissingPluginException {
    channel.setMethodCallHandler(null);
  } on PlatformException {
    channel.setMethodCallHandler(null);
  }
}
