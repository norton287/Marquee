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
    this.max = 300,
    this.save,
    this.saveAfter = const Duration(seconds: 2),
  });

  final int max;
  final Future<void> Function(String json)? save;
  final Duration saveAfter;

  final _entries = <CarLogEntry>[];
  final _changes = StreamController<void>.broadcast();
  Timer? _saving;

  List<CarLogEntry> get entries => List.unmodifiable(_entries);

  /// Fires when entries are added or cleared (the Settings view redraws).
  Stream<void> get changes => _changes.stream;

  void add(String message) {
    _entries.add(CarLogEntry(DateTime.now(), scrub(message)));
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
    _saving?.cancel();
    _saving = Timer(saveAfter, () => save!(_toJson()));
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

  /// Links, tokens and keys out: they hold the server address and secrets.
  static String scrub(String s) => s
      .replaceAll(RegExp(r'[a-z][a-z0-9+.-]*://\S+', caseSensitive: false), '<link>')
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

  void dispose() {
    _saving?.cancel();
    _changes.close();
  }
}
