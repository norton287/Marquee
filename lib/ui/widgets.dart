import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/backend.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'nav.dart';
import 'theme.dart';

// ---------------------------------------------------------------------------
// Artwork
// ---------------------------------------------------------------------------

IconData kindIcon(MediaKind kind) => switch (kind) {
      MediaKind.movie => Icons.movie_outlined,
      MediaKind.show || MediaKind.season || MediaKind.episode => Icons.tv,
      MediaKind.artist => Icons.person_outline,
      MediaKind.album => Icons.album_outlined,
      MediaKind.track => Icons.music_note_outlined,
      MediaKind.collection => Icons.collections_bookmark_outlined,
      MediaKind.playlist => Icons.queue_music,
      MediaKind.folder => Icons.folder_outlined,
      _ => Icons.play_circle_outline,
    };

/// A network image that never leaves a hole: a tinted placeholder with an
/// icon shows while loading, when there is no art, and on failure.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.image,
    this.aspect = 2 / 3,
    this.icon = Icons.image_outlined,
    this.seed = '',
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.showIcon = true,
  });

  final ImageRef? image;
  final double aspect;
  final IconData icon;
  final String seed;
  final BoxFit fit;
  final Alignment alignment;

  /// Banners sit behind text, so they skip the placeholder icon.
  final bool showIcon;

  /// Widget tests turn this off so nothing reaches for the network.
  static bool network = true;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final placeholder =
          _Placeholder(icon: showIcon ? icon : null, seed: seed);
      final ref = image;
      if (ref == null || !network || !c.maxWidth.isFinite) return placeholder;
      final px = (c.maxWidth * MediaQuery.devicePixelRatioOf(context)).round();
      return CachedNetworkImage(
        imageUrl: ref.url(px, aspect: aspect),
        httpHeaders: ref.headers,
        fit: fit,
        alignment: alignment,
        width: double.infinity,
        height: double.infinity,
        fadeInDuration: const Duration(milliseconds: 180),
        fadeOutDuration: const Duration(milliseconds: 80),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    });
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.seed});
  final IconData? icon;
  final String seed;

  @override
  Widget build(BuildContext context) {
    final hue = (seed.hashCode % 360).abs().toDouble();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.22, 0.20).toColor(),
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.25, 0.11).toColor(),
          ],
        ),
      ),
      child: icon == null
          ? null
          : Center(
              child: Icon(icon,
                  color: Colors.white.withValues(alpha: 0.28), size: 30),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Focus / hover / press
// ---------------------------------------------------------------------------

/// One interaction model for touch, mouse, keyboard and D-pad. The builder
/// gets `active` (focused or hovered) so it can draw its own highlight.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.onLongPress,
    this.autofocus = false,
    this.focusNode,
    this.grow = 1.05,
  });

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget Function(BuildContext context, bool focused, bool hovered)
      builder;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Scale applied while focused.
  final double grow;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.onTap != null,
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => widget.onTap?.call()),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) => widget.onTap?.call()),
      },
      onShowFocusHighlight: (v) {
        setState(() => _focused = v);
        if (v) {
          // Walks every enclosing scrollable, so a card in a horizontal
          // shelf also pulls the vertical page into view.
          context.findRenderObject()?.showOnScreen(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
              );
        }
      },
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onLongPress,
        child: AnimatedScale(
          scale: _focused ? widget.grow : 1,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: widget.builder(context, _focused, _hovered),
        ),
      ),
    );
  }
}

/// Rounded artwork frame with the focus ring and hover lift.
class ArtFrame extends StatelessWidget {
  const ArtFrame({
    super.key,
    required this.child,
    this.focused = false,
    this.hovered = false,
    this.radius = 10,
  });
  final Widget child;
  final bool focused;
  final bool hovered;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: focused
              ? Colors.white
              : (hovered
                  ? Colors.white.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.06)),
          width: focused ? 3 : 1,
        ),
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: focused
            ? const [BoxShadow(color: Colors.black54, blurRadius: 18)]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Badges
// ---------------------------------------------------------------------------

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.filled = false, this.color});
  final String text;
  final bool filled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Palette.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? c : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(5),
        border: filled ? null : Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.25,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
          color: filled ? Palette.bg : c,
        ),
      ),
    );
  }
}

/// Technical badges for a file: resolution, HDR, codec, audio layout.
List<Widget> versionTags(MediaVersion? v, {bool compact = false}) {
  if (v == null) return const [];
  return [
    if (v.resolution != null && (!compact || v.resolution == '4K'))
      Tag(v.resolution!),
    if (v.hdr != null) Tag(v.hdr!),
    if (!compact && v.videoCodec != null) Tag(v.videoCodec!.toUpperCase()),
    if (!compact && v.audioLayout != null) Tag(v.audioLayout!),
  ];
}

class ServerDot extends ConsumerWidget {
  const ServerDot(this.serverId, {super.key, this.size = 8});
  final String serverId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(serversProvider.select((l) =>
        l.where((s) => s.id == serverId).map((s) => s.kind).firstOrNull));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: serverColor(kind),
      ),
    );
  }
}

Color serverColor(ServerKind? kind) => switch (kind) {
      ServerKind.plex => Palette.plex,
      ServerKind.jellyfin => Palette.jellyfin,
      _ => Palette.muted,
    };

// ---------------------------------------------------------------------------
// Media card
// ---------------------------------------------------------------------------

enum CardShape { poster, landscape, square }

double cardAspect(CardShape s) => switch (s) {
      CardShape.poster => 2 / 3,
      CardShape.landscape => 16 / 9,
      CardShape.square => 1,
    };

/// Height of the two text lines under a card at the current text scale.
double cardTextHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(13.5) * 1.3 +
    MediaQuery.textScalerOf(context).scale(12) * 1.3 +
    11;

class MediaCard extends ConsumerWidget {
  const MediaCard({
    super.key,
    required this.item,
    this.shape,
    this.playOnTap = false,
    this.autofocus = false,
    this.contextual = false,
  });

  final MediaItem item;
  final CardShape? shape;

  /// Resume straight away (continue watching); long-press opens details.
  final bool playOnTap;
  final bool autofocus;

  /// Shown inside its parent (a season's page), so use the plain title.
  final bool contextual;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = shape ?? (item.squareArt ? CardShape.square : CardShape.poster);
    final multiServer =
        ref.watch(serversProvider.select((l) => l.length > 1));
    final image = s == CardShape.landscape
        ? (item.thumb ?? item.backdrop ?? item.poster)
        : item.poster;
    final unplayed = item.unplayedCount ?? 0;
    final showCount = !item.kind.isPlayable &&
        !item.kind.isMusic &&
        unplayed > 0 &&
        (item.kind == MediaKind.show || item.kind == MediaKind.season);

    return Pressable(
      autofocus: autofocus,
      onTap: () => playOnTap && item.kind.isPlayable
          ? playItem(context, item)
          : openItem(context, item),
      onLongPress: () => openItem(context, item),
      builder: (context, focused, hovered) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: cardAspect(s),
            child: ArtFrame(
              focused: focused,
              hovered: hovered,
              radius: item.kind == MediaKind.artist ? 999 : 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Artwork(
                    image: image,
                    aspect: cardAspect(s),
                    icon: kindIcon(item.kind),
                    seed: item.title,
                  ),
                  if (s == CardShape.landscape && (focused || hovered || playOnTap))
                    Align(
                      alignment: Alignment.center,
                      child: AnimatedOpacity(
                        opacity: focused || hovered ? 1 : 0,
                        duration: const Duration(milliseconds: 140),
                        child: const CircleAvatar(
                          radius: 22,
                          backgroundColor: Colors.black54,
                          child: Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 30),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Wrap(
                      spacing: 4,
                      children: s == CardShape.poster
                          ? versionTags(item.versions.firstOrNull,
                              compact: true)
                          : const [],
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: showCount
                        ? Tag('$unplayed', filled: true, color: Palette.accent)
                        : (item.played && !item.kind.isMusic
                            ? const CircleAvatar(
                                radius: 9,
                                backgroundColor: Colors.black54,
                                child: Icon(Icons.check,
                                    size: 12, color: Colors.white),
                              )
                            : const SizedBox.shrink()),
                  ),
                  if (item.inProgress)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: ProgressLine(item.progress),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              if (multiServer) ...[
                ServerDot(item.serverId, size: 7),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  contextual ? item.title : item.cardTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.3, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          Text(
            (contextual
                    ? (item.kind == MediaKind.episode
                        ? item.episodeCode
                        : item.year?.toString())
                    : item.cardSubtitle) ??
                '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, height: 1.3, color: Palette.muted),
          ),
        ],
      ),
    );
  }
}

class ProgressLine extends StatelessWidget {
  const ProgressLine(this.value, {super.key, this.height = 4});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black54),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0.02, 1.0),
            child: const ColoredBox(color: Palette.accent),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shelves and grids
// ---------------------------------------------------------------------------

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(l.gutter, 22, l.gutter, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: l.tv ? 24 : (l.phone ? 18 : 20),
                  ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Generic horizontal row of fixed-width tiles.
class HorizontalShelf extends StatelessWidget {
  const HorizontalShelf({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemWidth,
    required this.itemHeight,
    required this.itemBuilder,
    this.trailing,
  });

  final String title;
  final int itemCount;
  final double itemWidth;
  final double itemHeight;
  final IndexedWidgetBuilder itemBuilder;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title, trailing: trailing),
        SizedBox(
          // Room above and below for the focus scale.
          height: itemHeight + 24,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: EdgeInsets.symmetric(horizontal: l.gutter, vertical: 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => SizedBox(width: l.shelfGap),
            itemBuilder: (context, i) => SizedBox(
              width: itemWidth,
              child: itemBuilder(context, i),
            ),
          ),
        ),
      ],
    );
  }
}

class MediaShelf extends StatelessWidget {
  const MediaShelf({
    super.key,
    required this.title,
    required this.items,
    this.shape,
    this.playOnTap = false,
    this.autofocusFirst = false,
  });

  final String title;
  final List<MediaItem> items;
  final CardShape? shape;
  final bool playOnTap;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final l = AppLayout.of(context);
    final s = shape ??
        (items.first.squareArt ? CardShape.square : CardShape.poster);
    final w = switch (s) {
      CardShape.poster => l.posterWidth,
      CardShape.landscape => l.landscapeWidth,
      CardShape.square => l.squareWidth,
    };
    return HorizontalShelf(
      title: title,
      itemCount: items.length,
      itemWidth: w,
      itemHeight: w / cardAspect(s) + cardTextHeight(context),
      itemBuilder: (context, i) => MediaCard(
        item: items[i],
        shape: s,
        playOnTap: playOnTap,
        autofocus: autofocusFirst && i == 0,
      ),
    );
  }
}

/// A shelf fed by a provider: skeleton while loading, nothing when empty or
/// failed (the page stays useful even if one row can't load).
class AsyncMediaShelf extends StatelessWidget {
  const AsyncMediaShelf({
    super.key,
    required this.title,
    required this.value,
    this.shape,
    this.playOnTap = false,
  });
  final String title;
  final AsyncValue<List<MediaItem>> value;
  final CardShape? shape;
  final bool playOnTap;

  @override
  Widget build(BuildContext context) {
    final items = value.value;
    if (items != null) {
      return MediaShelf(
          title: title, items: items, shape: shape, playOnTap: playOnTap);
    }
    if (value.hasError) return const SizedBox.shrink();
    return ShelfSkeleton(title: title, shape: shape ?? CardShape.poster);
  }
}

class ShelfSkeleton extends StatelessWidget {
  const ShelfSkeleton({super.key, required this.title, required this.shape});
  final String title;
  final CardShape shape;

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    final w = switch (shape) {
      CardShape.poster => l.posterWidth,
      CardShape.landscape => l.landscapeWidth,
      CardShape.square => l.squareWidth,
    };
    return HorizontalShelf(
      title: title,
      itemCount: 8,
      itemWidth: w,
      itemHeight: w / cardAspect(shape) + cardTextHeight(context),
      itemBuilder: (_, _) => Align(
        alignment: Alignment.topCenter,
        child: AspectRatio(
          aspectRatio: cardAspect(shape),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: Palette.surface,
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Responsive grid of media cards as a sliver.
class MediaSliverGrid extends StatelessWidget {
  const MediaSliverGrid({
    super.key,
    required this.items,
    this.shape,
    this.contextual = false,
    this.autofocusFirst = false,
  });
  final List<MediaItem> items;
  final CardShape? shape;
  final bool contextual;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    final l = AppLayout.of(context);
    final s = shape ??
        (items.isNotEmpty && items.first.squareArt
            ? CardShape.square
            : CardShape.poster);
    final target = switch (s) {
      CardShape.poster => l.posterWidth,
      CardShape.landscape => l.landscapeWidth,
      CardShape.square => l.squareWidth,
    };
    final gap = l.shelfGap + 2;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(l.gutter, 12, l.gutter, 32),
      sliver: SliverLayoutBuilder(builder: (context, c) {
        final cols =
            ((c.crossAxisExtent + gap) / (target + gap)).floor().clamp(2, 12);
        final w = (c.crossAxisExtent - gap * (cols - 1)) / cols;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: gap,
            mainAxisSpacing: gap + 4,
            mainAxisExtent: w / cardAspect(s) + cardTextHeight(context),
          ),
          itemCount: items.length,
          itemBuilder: (context, i) => MediaCard(
            item: items[i],
            shape: s,
            contextual: contextual,
            autofocus: autofocusFirst && i == 0,
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

String friendlyError(Object error) {
  if (error is BackendException) return error.message;
  if (error is DioException) {
    final code = error.response?.statusCode;
    if (code == 401 || code == 403) {
      return 'The server rejected this sign-in. Remove the server in Settings and add it again.';
    }
    if (code == 404) return 'The server no longer has this.';
    if (code != null) return 'The server answered with an error ($code).';
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'The server took too long to answer.',
      _ => 'Can\'t reach the server. Check that it is on and that this device is on the right network.',
    };
  }
  if (error is StateError) return error.message;
  if (error is FormatException) return error.message;
  return '$error';
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;

  factory MessageView.error(Object error, {VoidCallback? onRetry}) =>
      MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Something went wrong',
        body: friendlyError(error),
        action: onRetry == null ? null : 'Try again',
        onAction: onRetry,
      );

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: Palette.muted),
              const SizedBox(height: 16),
              Text(title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(body!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Palette.muted)),
              ],
              if (action != null) ...[
                const SizedBox(height: 20),
                FilledButton(onPressed: onAction, child: Text(action!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
}

/// Bottom sheet on phones, side panel on wide screens.
Future<T?> showPanel<T>(BuildContext context,
    {required WidgetBuilder builder, double width = 400}) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  if (!wide) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: builder(context),
      ),
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Palette.surface,
        child: SafeArea(
          child: SizedBox(
            width: width,
            height: double.infinity,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: builder(context),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

/// "★ 7.8" with a real icon, so it never depends on a font having the glyph.
InlineSpan ratingSpan(double rating, {Color color = Palette.text, double size = 15}) =>
    TextSpan(children: [
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Icon(Icons.star_rounded, size: size, color: const Color(0xFFFFC857)),
      ),
      TextSpan(text: ' ${rating.toStringAsFixed(1)}'),
    ]);

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

String formatClock(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

// ---------------------------------------------------------------------------
// Menus
// ---------------------------------------------------------------------------

class SelectMenuItem {
  const SelectMenuItem({
    required this.label,
    required this.onPressed,
    this.icon,
    this.selected = false,
  });
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  /// The current choice. Focus lands here when the menu opens.
  final bool selected;
}

/// A drop-down menu that works with a remote: opening it moves focus onto the
/// current choice (MenuAnchor alone leaves focus on the button, so the D-pad
/// keeps driving the page underneath), and closing it puts focus back on the
/// button.
class SelectMenu extends StatefulWidget {
  const SelectMenu({
    super.key,
    required this.items,
    required this.builder,
    this.alignmentOffset,
  });
  final List<SelectMenuItem> items;

  /// Builds the button. Attach [focusNode] to it and call [toggle] on press.
  final Widget Function(
      BuildContext context, FocusNode focusNode, VoidCallback toggle) builder;
  final Offset? alignmentOffset;

  @override
  State<SelectMenu> createState() => _SelectMenuState();
}

class _SelectMenuState extends State<SelectMenu> {
  final _button = FocusNode(debugLabel: 'menu button');
  final _controller = MenuController();
  List<FocusNode> _items = [];

  @override
  void initState() {
    super.initState();
    _syncNodes();
  }

  @override
  void didUpdateWidget(SelectMenu old) {
    super.didUpdateWidget(old);
    _syncNodes();
  }

  void _syncNodes() {
    while (_items.length > widget.items.length) {
      _items.removeLast().dispose();
    }
    _items = [
      ..._items,
      for (var i = _items.length; i < widget.items.length; i++)
        FocusNode(debugLabel: 'menu item $i'),
    ];
  }

  @override
  void dispose() {
    _button.dispose();
    for (final n in _items) {
      n.dispose();
    }
    super.dispose();
  }

  void _focusCurrent() {
    if (_items.isEmpty) return;
    final i = widget.items.indexWhere((it) => it.selected);
    // The menu's items are built in the overlay on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.isOpen) _items[i < 0 ? 0 : i].requestFocus();
    });
  }

  void _toggle() =>
      _controller.isOpen ? _controller.close() : _controller.open();

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      childFocusNode: _button,
      alignmentOffset: widget.alignmentOffset,
      onOpen: _focusCurrent,
      menuChildren: [
        for (var i = 0; i < widget.items.length; i++)
          MenuItemButton(
            focusNode: _items[i],
            leadingIcon: Icon(widget.items[i].icon, size: 18),
            onPressed: widget.items[i].onPressed,
            child: Text(widget.items[i].label),
          ),
      ],
      builder: (context, _, _) => widget.builder(context, _button, _toggle),
    );
  }
}
