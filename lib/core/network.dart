import 'dart:io' show InternetAddress, InternetAddressType;

/// Whether [url] points at the home network rather than across the internet.
/// Decides which maximum streaming quality applies (home or away).
///
/// Home: private and link-local IPv4/IPv6 ranges, loopback, `.local` and
/// single-word host names (e.g. `nas`), and Plex's `*.plex.direct` names when
/// the address encoded in them is private. Anything else counts as away;
/// a public domain that happens to loop back inside the house can't be told
/// apart without probing.
bool isLocalAddress(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.local')) return true;

  // https://192-168-1-10.<hash>.plex.direct:32400 carries its IP in the name.
  if (host.endsWith('.plex.direct')) {
    final label = host.split('.').first;
    final ip = label.contains(':') || label.split('-').length > 4
        ? label.replaceAll('-', ':') // IPv6 uses dashes for colons
        : label.replaceAll('-', '.');
    return _isPrivateIp(ip);
  }
  final ip = InternetAddress.tryParse(host);
  if (ip != null) return _isPrivateIp(host);
  return !host.contains('.'); // a bare LAN name such as "nas"
}

bool _isPrivateIp(String text) {
  final ip = InternetAddress.tryParse(text);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127); // CGNAT / Tailscale
  }
  return (b[0] & 0xfe) == 0xfc; // IPv6 unique local fc00::/7
}
