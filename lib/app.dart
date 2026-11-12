import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'ui/nav.dart';
import 'ui/theme.dart';

class MarqueeApp extends ConsumerWidget {
  const MarqueeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final tv = ref.watch(tvProvider);
    final trueBlack = ref.watch(settingsProvider.select((s) => s.trueBlack));
    return MaterialApp.router(
      title: 'Marquee',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(trueBlack: trueBlack),
      routerConfig: router,
      scrollBehavior: const _AppScrollBehavior(),
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        // TV remotes and game controllers: OK / A activates the focused item.
        const SingleActivator(LogicalKeyboardKey.select):
            const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.gameButtonA):
            const ActivateIntent(),
      },
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return AppLayout(
          width: mq.size.width,
          tv: tv,
          child: MediaQuery(
            // Ten-foot viewing wants slightly larger type.
            data: tv
                ? mq.copyWith(
                    textScaler: TextScaler.linear(
                        (mq.textScaler.scale(1) * 1.1).clamp(1.0, 1.6)))
                : mq,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

/// Lets a mouse or trackpad drag the horizontal shelves on desktop.
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}
