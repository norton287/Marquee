import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One line of the car log.
@immutable
class CarLogEntry {
  const CarLogEntry(this.at, this.message);
  final DateTime at;
  final String message;
}

/// What Android Auto asked Marquee for and what Marquee answered (Settings →
/// Android Auto → Car log), so a car problem can be seen after the drive.
/// Keeps the newest [max] entries and saves them shortly after changes, so
/// they survive Android closing the app. Never keeps tokens or server
/// addresses.
class CarLog {
  CarLog({
    this.max = 600,
    this.save,
    this.saveAfter = const Duration(milliseconds: 500),
    this.saveAtLeastEvery = const Duration(seconds: 3),
  });

  final int max;
  final Future<void> Function(String json)? save;

  /// Saves this long after the last change, but never later than
  /// [saveAtLeastEvery] after the first unsaved one (a busy car would put it
  /// off forever, and the last moments before Android closes the app are the
  /// ones that matter).
  final Duration saveAfter;
  final Duration saveAtLeastEvery;
  DateTime? _unsavedSince;
  bool _closed = false;

  final _entries = <CarLogEntry>[];
  final _changes = StreamController<void>.broadcast();
  Timer? _saving;

  List<CarLogEntry> get entries => List.unmodifiable(_entries);

  /// Fires when entries are added or cleared (the Settings view redraws).
  Stream<void> get changes => _changes.stream;

  void add(String message) {
    if (_closed) return;
    // One line per entry (errors span several).
    final line = scrub(message).replaceAll(RegExp(r'\s+'), ' ').trim();
    _entries.add(CarLogEntry(DateTime.now(), line));
    if (_entries.length > max) _entries.removeRange(0, _entries.length - max);
    _changed();
  }

  void clear() {
    _entries.clear();
    _changed();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
    if (save == null) return;
    final now = DateTime.now();
    final since = _unsavedSince ??= now;
    _saving?.cancel();
    if (now.difference(since) >= saveAtLeastEvery) {
      _flush();
    } else {
      _saving = Timer(saveAfter, _flush);
    }
  }

  void _flush() {
    _saving?.cancel();
    _saving = null;
    _unsavedSince = null;
    final save = this.save;
    if (save == null) return;
    // A failed save must never break the app; the next change tries again.
    unawaited(Future(() => save(_toJson())).catchError((Object _) {}));
  }

  String _toJson() => jsonEncode([
        for (final e in _entries) [e.at.millisecondsSinceEpoch, e.message],
      ]);

  /// Restores saved entries (bad data is ignored).
  void load(String? json) {
    if (json == null) return;
    try {
      _entries
        ..clear()
        ..addAll([
          for (final e in jsonDecode(json) as List)
            CarLogEntry(DateTime.fromMillisecondsSinceEpoch((e as List)[0] as int),
                e[1] as String),
        ]);
    } catch (_) {
      _entries.clear();
    }
  }

  /// Links, hosts, addresses, tokens, keys and cookies out.
  static String scrub(String s) => s
      .replaceAll(RegExp(r'[a-z][a-z0-9+.-]*://\S+', caseSensitive: false), '<link>')
      // Plex's per-server names carry the IP and the certificate hash.
      .replaceAll(RegExp(r'[\w.-]+\.plex\.direct(:\d+)?', caseSensitive: false), '<host>')
      .replaceAll(RegExp(r"Failed host lookup: '[^']*'", caseSensitive: false),
          'Failed host lookup: <host>')
      .replaceAll(RegExp(r'address = \S+, port = \d+'), 'address = <address>')
      .replaceAll(RegExp(r'host: \S+, port: \d+'), 'host: <host>')
      // IPv4 (with a port) and IPv6.
      .replaceAll(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b'), '<address>')
      .replaceAll(
          RegExp(r'\[?\b[0-9a-f]{1,4}(:[0-9a-f]{0,4}){2,7}\]?(:\d+)?', caseSensitive: false),
          '<address>')
      .replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer <hidden>')
      .replaceAllMapped(RegExp(r'(cookie|sid|session)(["\x27]?\s*[=:]\s*)[^\s;,]+',
              caseSensitive: false),
          (m) => '${m[1]}${m[2]}<hidden>')
      .replaceAllMapped(
          RegExp(r'(token|api_key|apikey|password)(["\x27]?\s*[=:]\s*["\x27]?)[^\s"\x27&,]+',
              caseSensitive: false),
          (m) => '${m[1]}${m[2]}<hidden>');

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Oldest first, one line each: "16:05:12.345 tap …".
  String toText() => [
        for (final e in _entries)
          '${_two(e.at.hour)}:${_two(e.at.minute)}:${_two(e.at.second)}.'
              '${e.at.millisecond.toString().padLeft(3, '0')} ${e.message}',
      ].join('\n');

  /// What Copy sends: newest first and only the last [last], so a long
  /// paste that gets cut keeps the part that matters.
  String toShareText({int last = 200}) =>
      toText().split('\n').reversed.take(last).join('\n');

  /// Saves what's pending, then ignores further entries.
  void dispose() {
    if (_closed) return;
    if (_saving != null) _flush();
    _closed = true;
    _changes.close();
  }
}
