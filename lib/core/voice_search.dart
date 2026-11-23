import 'package:flutter/services.dart';

/// "Hey Google, play … on Marquee" on the phone (not in the car, where the
/// Assistant talks to the media session directly): Android opens MainActivity
/// with a MEDIA_PLAY_FROM_SEARCH intent. The native side (VoiceSearch.kt)
/// keeps the words until Dart is listening, so this asks once for anything
/// waiting ('take') and then plays each new request it pushes ('play').
///
/// It keeps listening even when that first ask goes unanswered: an engine
/// started by the music service (the car or the system binding it after a
/// stop) is only connected to the native side once MainActivity opens, and
/// the native side then pushes the waiting words. A failed search never
/// escapes ([play] logs its own outcome).
Future<void> listenForVoiceSearch(Future<void> Function(String query) play,
    {MethodChannel channel =
        const MethodChannel('app.marquee.marquee/voice')}) async {
  Future<void> safely(String query) async {
    try {
      await play(query);
    } catch (_) {}
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'play') await safely('${call.arguments ?? ''}');
  });
  try {
    final waiting = await channel.invokeMethod<String>('take');
    if (waiting != null) await safely(waiting);
  } on MissingPluginException {
    // Not connected yet (or no native side at all): pushes may still come.
  } on PlatformException {
    // Same.
  }
}
