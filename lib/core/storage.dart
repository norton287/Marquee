import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

@immutable
class AppSettings {
  const AppSettings({
    this.maxBitrateKbps,
    this.remoteMaxBitrateKbps,
    this.autoPlayNext = true,
    this.autoSkipIntro = false,
    this.allowHdr = true,
    this.audioLanguage,
    this.subtitleLanguage,
    this.tvMode = 'auto',
    this.trueBlack = false,
    this.seerrUrl,
    this.seerrApiKey,
    this.seerrCookie,
    this.hiddenLibraries = const {},
    this.skipBackSeconds = 10,
    this.skipForwardSeconds = 30,
  });

  /// Choices offered for [skipBackSeconds] and [skipForwardSeconds].
  static const skipOptions = [5, 10, 15, 20, 30, 45, 60];

  /// Maximum streaming quality on the home network; null = original (no
  /// limit). Files at or under the limit play untouched.
  final int? maxBitrateKbps;

  /// Maximum streaming quality when the server is reached over the internet.
  final int? remoteMaxBitrateKbps;

  /// The maximum that applies to a server at home ([local]) or away.
  int? maxBitrateFor({required bool local}) =>
      local ? maxBitrateKbps : remoteMaxBitrateKbps;
  final bool autoPlayNext;
  final bool autoSkipIntro;

  /// Off: HDR / Dolby Vision and above-1080p videos never direct play; the
  /// server converts them to 1080p SDR (lighter to stream and decode).
  final bool allowHdr;

  /// ISO 639 codes such as 'eng'. null = whatever the file marks as default.
  final String? audioLanguage;

  /// null = subtitles off unless forced.
  final String? subtitleLanguage;

  /// 'auto', 'on' or 'off'.
  final String tvMode;
  final bool trueBlack;
  final String? seerrUrl;
  final String? seerrApiKey;
  final String? seerrCookie;

  /// How far the player jumps back / forward: on-screen buttons, remote
  /// rewind / fast-forward, ←/→ with the controls hidden, double-tap.
  final int skipBackSeconds;
  final int skipForwardSeconds;

  /// Library ids the user hid, per server id.
  final Map<String, Set<String>> hiddenLibraries;

  Set<String> hiddenOn(String serverId) =>
      hiddenLibraries[serverId] ?? const {};

  bool isHidden(String serverId, String libraryId) =>
      hiddenOn(serverId).contains(libraryId);

  AppSettings withLibraryHidden(
      String serverId, String libraryId, bool hidden) {
    final ids = {...hiddenOn(serverId)};
    hidden ? ids.add(libraryId) : ids.remove(libraryId);
    return copyWith(hiddenLibraries: {
      ...hiddenLibraries,
      serverId: ids,
    }..removeWhere((_, v) => v.isEmpty));
  }

  bool get hasSeerr =>
      (seerrUrl ?? '').isNotEmpty &&
      ((seerrApiKey ?? '').isNotEmpty || (seerrCookie ?? '').isNotEmpty);

  static const _keep = Object();

  AppSettings copyWith({
    Object? maxBitrateKbps = _keep,
    Object? remoteMaxBitrateKbps = _keep,
    bool? autoPlayNext,
    bool? autoSkipIntro,
    bool? allowHdr,
    Object? audioLanguage = _keep,
    Object? subtitleLanguage = _keep,
    String? tvMode,
    bool? trueBlack,
    Object? seerrUrl = _keep,
    Object? seerrApiKey = _keep,
    Object? seerrCookie = _keep,
    Map<String, Set<String>>? hiddenLibraries,
    int? skipBackSeconds,
    int? skipForwardSeconds,
  }) =>
      AppSettings(
        maxBitrateKbps: maxBitrateKbps == _keep
            ? this.maxBitrateKbps
            : maxBitrateKbps as int?,
        remoteMaxBitrateKbps: remoteMaxBitrateKbps == _keep
            ? this.remoteMaxBitrateKbps
            : remoteMaxBitrateKbps as int?,
        autoPlayNext: autoPlayNext ?? this.autoPlayNext,
        autoSkipIntro: autoSkipIntro ?? this.autoSkipIntro,
        allowHdr: allowHdr ?? this.allowHdr,
        audioLanguage: audioLanguage == _keep
            ? this.audioLanguage
            : audioLanguage as String?,
        subtitleLanguage: subtitleLanguage == _keep
            ? this.subtitleLanguage
            : subtitleLanguage as String?,
        tvMode: tvMode ?? this.tvMode,
        trueBlack: trueBlack ?? this.trueBlack,
        seerrUrl: seerrUrl == _keep ? this.seerrUrl : seerrUrl as String?,
        seerrApiKey:
            seerrApiKey == _keep ? this.seerrApiKey : seerrApiKey as String?,
        seerrCookie:
            seerrCookie == _keep ? this.seerrCookie : seerrCookie as String?,
        hiddenLibraries: hiddenLibraries ?? this.hiddenLibraries,
        skipBackSeconds: skipBackSeconds ?? this.skipBackSeconds,
        skipForwardSeconds: skipForwardSeconds ?? this.skipForwardSeconds,
      );

  Map<String, dynamic> toJson() => {
        'maxBitrateKbps': maxBitrateKbps,
        'remoteMaxBitrateKbps': remoteMaxBitrateKbps,
        'autoPlayNext': autoPlayNext,
        'autoSkipIntro': autoSkipIntro,
        'allowHdr': allowHdr,
        'audioLanguage': audioLanguage,
        'subtitleLanguage': subtitleLanguage,
        'tvMode': tvMode,
        'trueBlack': trueBlack,
        'seerrUrl': seerrUrl,
        'skipBackSeconds': skipBackSeconds,
        'skipForwardSeconds': skipForwardSeconds,
        'hiddenLibraries': {
          for (final e in hiddenLibraries.entries) e.key: e.value.toList(),
        },
      };

  Map<String, dynamic> secrets() =>
      {'seerrApiKey': seerrApiKey, 'seerrCookie': seerrCookie};

  /// A saved skip length, or [fallback] if it's missing or not one we offer.
  static int _skip(Object? v, int fallback) {
    final s = asInt(v);
    return s != null && skipOptions.contains(s) ? s : fallback;
  }

  factory AppSettings.fromJson(
          Map<String, dynamic> j, Map<String, dynamic> secrets) =>
      AppSettings(
        maxBitrateKbps: asInt(j['maxBitrateKbps']),
        // Saved before home/away existed: the one choice applied everywhere.
        remoteMaxBitrateKbps: j.containsKey('remoteMaxBitrateKbps')
            ? asInt(j['remoteMaxBitrateKbps'])
            : asInt(j['maxBitrateKbps']),
        autoPlayNext: j['autoPlayNext'] as bool? ?? true,
        autoSkipIntro: j['autoSkipIntro'] as bool? ?? false,
        allowHdr: j['allowHdr'] as bool? ?? true,
        audioLanguage: j['audioLanguage'] as String?,
        subtitleLanguage: j['subtitleLanguage'] as String?,
        tvMode: j['tvMode'] as String? ?? 'auto',
        trueBlack: j['trueBlack'] as bool? ?? false,
        seerrUrl: j['seerrUrl'] as String?,
        seerrApiKey: secrets['seerrApiKey'] as String?,
        seerrCookie: secrets['seerrCookie'] as String?,
        skipBackSeconds: _skip(j['skipBackSeconds'], 10),
        skipForwardSeconds: _skip(j['skipForwardSeconds'], 30),
        hiddenLibraries: {
          for (final e in ((j['hiddenLibraries'] as Map?) ?? const {}).entries)
            '${e.key}': {...((e.value as List?) ?? const []).map((v) => '$v')},
        },
      );
}

/// Key/value persistence. Tokens go through [writeSecret].
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
  Future<String?> readSecret(String key);
  Future<void> writeSecret(String key, String? value);
}

class MemoryStore implements KeyValueStore {
  final _data = <String, String>{};
  @override
  Future<String?> read(String key) async => _data[key];
  @override
  Future<void> write(String key, String? value) async =>
      value == null ? _data.remove(key) : _data[key] = value;
  @override
  Future<String?> readSecret(String key) => read('secret:$key');
  @override
  Future<void> writeSecret(String key, String? value) =>
      write('secret:$key', value);
}

/// Preferences for ordinary values, the platform keychain/keystore for
/// tokens. If no keychain is available (some Linux desktops have no secret
/// service running) tokens fall back to preferences so sign-in still works.
class DeviceStore implements KeyValueStore {
  DeviceStore(this._prefs);
  final SharedPreferences _prefs;
  static const _secure = FlutterSecureStorage();
  bool _secureBroken = false;

  static Future<DeviceStore> open() async =>
      DeviceStore(await SharedPreferences.getInstance());

  @override
  Future<String?> read(String key) async => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
  }

  @override
  Future<String?> readSecret(String key) async {
    if (!_secureBroken) {
      try {
        final v = await _secure.read(key: key);
        if (v != null) return v;
      } catch (_) {
        _secureBroken = true;
      }
    }
    return _prefs.getString('fallback_secret_$key');
  }

  @override
  Future<void> writeSecret(String key, String? value) async {
    if (!_secureBroken) {
      try {
        if (value == null) {
          await _secure.delete(key: key);
        } else {
          await _secure.write(key: key, value: value);
        }
        await _prefs.remove('fallback_secret_$key');
        return;
      } catch (_) {
        _secureBroken = true;
      }
    }
    await write('fallback_secret_$key', value);
  }
}

/// Loads everything once at startup so the first frame already knows which
/// servers exist.
class AppStorage {
  AppStorage(this._store);
  final KeyValueStore _store;

  List<ServerConfig> servers = const [];
  AppSettings settings = const AppSettings();
  String clientId = '';

  Map<String, dynamic> _json(String? s) {
    if (s == null || s.isEmpty) return {};
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> load() async {
    clientId = await _store.read('clientId') ?? '';
    if (clientId.isEmpty) {
      clientId = const Uuid().v4();
      await _store.write('clientId', clientId);
    }
    settings = AppSettings.fromJson(
      _json(await _store.read('settings')),
      _json(await _store.readSecret('settings')),
    );
    final raw = await _store.read('servers');
    final out = <ServerConfig>[];
    if (raw != null) {
      try {
        for (final j in jsonDecode(raw) as List) {
          final m = j as Map<String, dynamic>;
          out.add(ServerConfig.fromJson(
              m, _json(await _store.readSecret('server_${m['id']}'))));
        }
      } catch (_) {
        // Corrupt list: start clean rather than crash on launch.
      }
    }
    servers = out;
  }

  Future<void> saveServers(List<ServerConfig> next) async {
    final removed = servers
        .where((old) => next.every((n) => n.id != old.id))
        .map((s) => s.id)
        .toList();
    servers = next;
    await _store.write(
        'servers', jsonEncode([for (final s in next) s.toJson()]));
    for (final s in next) {
      await _store.writeSecret('server_${s.id}', jsonEncode(s.secrets()));
    }
    for (final id in removed) {
      await _store.writeSecret('server_$id', null);
    }
  }

  Future<void> saveSettings(AppSettings next) async {
    settings = next;
    await _store.write('settings', jsonEncode(next.toJson()));
    await _store.writeSecret('settings', jsonEncode(next.secrets()));
  }
}
