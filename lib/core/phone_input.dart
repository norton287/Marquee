import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'network.dart';

/// Typing on a phone for a field on the TV: the phone opens [url] in its
/// browser, types, and sends; [value] completes with the text.
abstract class PhoneInput {
  String get url;
  Future<String> get value;
  Future<void> close();
}

/// A tiny web page served from the TV while one field waits for text.
///
/// Only up while the dialog is open, on the home network. The address
/// carries a random 6-character code (any case); one answer ends it, as do
/// 20 wrong requests or [close]. Answers are capped at 64 KB.
class PhoneInputSession implements PhoneInput {
  PhoneInputSession._(
    this._server,
    this.url,
    this._code,
    this._label,
    this._obscure,
    this._multiline,
    this._initial,
  ) {
    _server.listen(_handle, onError: (_) {});
  }

  /// Starts listening. [initial] pre-fills the phone's field (never for
  /// [obscure] ones). [host] is the address put in [url]; by default the
  /// TV's home-network IPv4 address (tests pass loopback).
  static Future<PhoneInputSession> start({
    required String label,
    bool obscure = false,
    bool multiline = false,
    String initial = '',
    InternetAddress? host,
  }) async {
    final ip = host ?? await _homeAddress();
    if (ip == null) {
      throw StateError(
        "This TV isn't on a home network, so a phone can't reach it.",
      );
    }
    final server = await HttpServer.bind(host ?? InternetAddress.anyIPv4, 0);
    final code = _newCode();
    return PhoneInputSession._(
      server,
      'http://${ip.address}:${server.port}/$code',
      code,
      label,
      obscure,
      multiline,
      // A password never goes back out to the phone.
      obscure ? '' : initial,
    );
  }

  final HttpServer _server;
  @override
  final String url;
  final String _code;
  final String _label;
  final bool _obscure;
  final bool _multiline;
  final String _initial;
  final _value = Completer<String>();
  var _misses = 0;

  @override
  Future<String> get value => _value.future;

  // No 0/O/1/I: easy to read off a TV and type on a phone.
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const _maxBytes = 64 * 1024;

  static String _newCode() {
    final r = Random.secure();
    return [
      for (var n = 0; n < 6; n++) _alphabet[r.nextInt(_alphabet.length)],
    ].join();
  }

  /// The TV's own address on the home network (Wi-Fi or Ethernet).
  static Future<InternetAddress?> _homeAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final picked = pickHomeAddress([
        for (final i in interfaces)
          for (final a in i.addresses) (i.name, a.address),
      ]);
      return picked == null ? null : InternetAddress(picked);
    } on SocketException {
      return null;
    }
  }

  /// From (interface name, IPv4) pairs, the address a phone on the same
  /// Wi-Fi can most likely reach: wlan/eth first; VPN (tun, wg, 100.64/10),
  /// Wi-Fi Direct (p2p), hotspot/USB (ap, rndis) and link-local (169.254)
  /// last. Only home-network addresses count.
  @visibleForTesting
  static String? pickHomeAddress(List<(String, String)> candidates) {
    int rank((String, String) c) {
      final (name, ip) = c;
      if (ip.startsWith('169.254.')) return 3;
      final second = int.tryParse(ip.split('.').elementAtOrNull(1) ?? '');
      if (ip.startsWith('100.') &&
          second != null &&
          second >= 64 &&
          second < 128) {
        return 2;
      }
      if (RegExp(r'^(tun|p2p|ap|rndis|ppp|wg)').hasMatch(name)) return 2;
      if (RegExp(r'^(wlan|eth|en|wl)').hasMatch(name)) return 0;
      return 1;
    }

    final usable = [
      for (final c in candidates)
        if (!c.$2.startsWith('127.') && isLocalAddress('http://${c.$2}')) c,
    ]..sort((a, b) => rank(a).compareTo(rank(b)));
    return usable.firstOrNull?.$2;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      // Phones type the address in lowercase; the code alphabet is all
      // uppercase, so ignoring case costs nothing.
      if (req.uri.path.toUpperCase() != '/$_code') {
        res.statusCode = HttpStatus.notFound;
        res.headers.contentType = ContentType.text;
        res.write('Not found. Check the address shown on the TV.');
        await res.close();
        if (++_misses >= 20) {
          // Someone is guessing: stop.
          if (!_value.isCompleted) {
            _value.completeError(StateError('Too many wrong addresses.'));
          }
          await close();
        }
        return;
      }
      if (req.method == 'POST') {
        final bytes = <int>[];
        await for (final chunk in req.timeout(const Duration(seconds: 20))) {
          bytes.addAll(chunk);
          if (bytes.length > _maxBytes) break;
        }
        if (bytes.length > _maxBytes) {
          res.statusCode = HttpStatus.requestEntityTooLarge;
          res.headers.contentType = ContentType.text;
          res.write('That is too long to send.');
          await res.close();
          return;
        }
        final form = Uri.splitQueryString(
          utf8.decode(bytes, allowMalformed: true),
        );
        // Browsers send <textarea> line breaks as CRLF.
        final text = (form['v'] ?? '').replaceAll('\r\n', '\n');
        res.headers.contentType = ContentType.html;
        res.write(_page(sent: true));
        await res.close();
        // Stop listening first: once the TV has the text, nothing else can
        // reach it.
        await _server.close(force: true);
        if (!_value.isCompleted) _value.complete(text);
        return;
      }
      res.headers.contentType = ContentType.html;
      res.write(_page(sent: false));
      await res.close();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  String _page({required bool sent}) {
    const escape = HtmlEscape();
    final label = escape.convert(_label);
    final initial = escape.convert(_initial);
    final field = _multiline
        ? '<textarea name="v" rows="8" autofocus>$initial</textarea>'
        : '<input name="v" type="${_obscure ? 'password' : 'text'}" '
              'value="$initial" autocomplete="off" autocapitalize="off" '
              'autofocus>';
    final body = sent
        ? '<p class="ok">Sent to the TV. You can close this page.</p>'
        : '<form method="post"><label>$label</label>$field'
              '<button type="submit">Send to TV</button></form>';
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Marquee</title><style>
body{font-family:system-ui,sans-serif;background:#0B0C0F;color:#eee;margin:0;padding:24px}
h1{font-size:20px;margin:0 0 20px}label{display:block;margin-bottom:8px;color:#aaa}
input,textarea{box-sizing:border-box;width:100%;font-size:18px;padding:12px;border-radius:10px;
border:1px solid #333;background:#15171C;color:#eee}
button{margin-top:16px;width:100%;font-size:18px;padding:14px;border:0;border-radius:10px;
background:#FF6A3D;color:#fff}.ok{font-size:18px}
</style></head><body><h1>Marquee</h1>$body</body></html>''';
  }

  @override
  Future<void> close() async {
    if (!_value.isCompleted) {
      _value.completeError(StateError('Closed.'));
      // Nobody may be listening for the error once the dialog is gone.
      unawaited(_value.future.catchError((_) => ''));
    }
    await _server.close(force: true);
  }
}
