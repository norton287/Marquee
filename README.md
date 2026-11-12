# Marquee

A Flutter client for Plex and Jellyfin: phone, tablet, desktop and TV from one codebase.

## Run it

Requires Flutter 3.50 (Dart 3.14).

```
flutter pub get
flutter run            # pick a device: Android / Android TV, iOS, macOS, Windows, Linux
```

Linux needs `libmpv-dev`, `libgtk-3-dev`, `libsecret-1-dev` and `libjsoncpp-dev`.

On first launch choose **Connect Plex**, **Connect Jellyfin**, or the built-in demo library
(artwork from picsum.photos, playback from a public test stream).

## What's inside

| | |
|---|---|
| `lib/core/backend.dart` | The one interface every screen talks to |
| `lib/core/plex.dart` | plex.tv link-code sign-in, server discovery, Plex Media Server, Plex Watchlist |
| `lib/core/jellyfin.dart` | Address discovery, password and Quick Connect sign-in, Jellyfin 10.9+ |
| `lib/core/seerr.dart` | Seerr / Overseerr / Jellyseerr: trending, search, requests |
| `lib/core/demo.dart` | Offline sample library |
| `lib/core/providers.dart` | Riverpod state: servers, settings, merged shelves, search |
| `lib/ui/` | Screens, the adaptive shell, shared cards and shelves |
| `lib/ui/player/` | Video player built on media_kit (libmpv) |
| `lib/ui/music.dart` | Music queue, mini player, now playing |

Layout adapts by width and device: bottom bar on phones, side rail on tablets and desktops,
and a larger, focus-driven layout on Android TV / Fire TV (auto-detected; can be forced in Settings).

## Playback

- Direct play by default (libmpv handles nearly every container and codec). If a file fails to
  start, the player falls back to a server transcode by itself.
- Quality menu switches to an HLS transcode at a chosen bitrate and keeps your position.
- Audio and subtitle switching (embedded and sidecar), language defaults, speed, fit/fill.
- Resume, progress reporting every 10 s, chapters (list, ticks on the scrubber, previous/next),
  intro skipping from server markers, up-next with countdown.
- Picture in picture on Android (button, and automatically when you leave the app while
  playing). Desktop has a mini-player window that stays on top.

## Tests

```
flutter test                      # layouts on phone/tablet/desktop/TV sizes, API mapping, storage
```

A real-playback test drives the Linux build against a small stand-in Jellyfin server:

```
tool/make_test_media.sh           # needs ffmpeg
python3 tool/fake_jellyfin.py 8096 &
flutter test integration_test/playback_test.dart -d linux \
  --dart-define=JF_URL=http://127.0.0.1:8096
```

## Known limits

- iOS has no picture in picture (media_kit renders through a texture, which iOS PiP can't use).
- Apple TV isn't supported by Flutter; "TV" means Android TV, Google TV and Fire TV.
- Music has no lock-screen / media-session controls yet.
- Plex Home user switching and photo libraries aren't included.
- Plex sign-in uses the classic link-code token rather than the newer JWT device flow.
- Flutter 3.50 deprecates `package:flutter/material.dart` in favour of `material_ui`. The app stays
  on the former because the plugins it uses still do, so `flutter analyze` prints an info per file.
