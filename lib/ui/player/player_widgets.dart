import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets.dart';

/// Scrubber with buffered range, chapter ticks, a time bubble while
/// scrubbing, and left/right key support for remotes.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.buffer,
    required this.duration,
    required this.onSeek,
    this.chapters = const [],
    this.onInteract,
    this.step = const Duration(seconds: 10),
    this.backStep,
  });

  final ValueListenable<Duration> position;
  final ValueListenable<Duration> buffer;
  final Duration duration;
  final List<Duration> chapters;
  final ValueChanged<Duration> onSeek;

  /// Called on any interaction so the controls can stay visible.
  final VoidCallback? onInteract;
  /// Arrow-key step forward; [backStep] (defaults to [step]) going back.
  final Duration step;
  final Duration? backStep;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _scrub; // 0..1 while dragging
  double? _hover;
  bool _focused = false;

  Duration _at(double f) => Duration(
      milliseconds: (widget.duration.inMilliseconds * f.clamp(0.0, 1.0)).round());

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final dir = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => 0,
    };
    if (dir == 0) return KeyEventResult.ignored;
    widget.onInteract?.call();
    final target = widget.position.value +
        (dir < 0 ? (widget.backStep ?? widget.step) : widget.step) * dir;
    widget.onSeek(target < Duration.zero
        ? Duration.zero
        : (target > widget.duration ? widget.duration : target));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.duration > Duration.zero;
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (v) => setState(() => _focused = v),
      child: Semantics(
        slider: true,
        label: 'Seek',
        child: LayoutBuilder(builder: (context, c) {
          final width = c.maxWidth;
          double frac(Offset local) => (local.dx / width).clamp(0.0, 1.0);
          final bubbleAt = _scrub ?? _hover;
          return MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onHover: (e) => setState(() => _hover = frac(e.localPosition)),
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: enabled
                  ? (d) {
                      widget.onInteract?.call();
                      widget.onSeek(_at(frac(d.localPosition)));
                    }
                  : null,
              onHorizontalDragStart: enabled
                  ? (d) => setState(() => _scrub = frac(d.localPosition))
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (d) {
                      widget.onInteract?.call();
                      setState(() => _scrub = frac(d.localPosition));
                    }
                  : null,
              onHorizontalDragEnd: enabled
                  ? (_) {
                      final s = _scrub;
                      setState(() => _scrub = null);
                      if (s != null) widget.onSeek(_at(s));
                    }
                  : null,
              onHorizontalDragCancel: () => setState(() => _scrub = null),
              child: SizedBox(
                height: 36,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: ListenableBuilder(
                        listenable:
                            Listenable.merge([widget.position, widget.buffer]),
                        builder: (context, _) {
                          final total = widget.duration.inMilliseconds;
                          double f(Duration d) => total <= 0
                              ? 0
                              : (d.inMilliseconds / total).clamp(0.0, 1.0);
                          return CustomPaint(
                            painter: _SeekPainter(
                              progress: _scrub ?? f(widget.position.value),
                              buffered: f(widget.buffer.value),
                              ticks: [
                                for (final ch in widget.chapters)
                                  if (ch > Duration.zero) f(ch),
                              ],
                              active:
                                  _focused || _scrub != null || _hover != null,
                              focused: _focused,
                            ),
                          );
                        },
                      ),
                    ),
                    if (bubbleAt != null && enabled)
                      Positioned(
                        left: (bubbleAt * width - 34).clamp(0.0, width - 68),
                        bottom: 34,
                        child: Container(
                          width: 68,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            formatClock(_at(bubbleAt)),
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({
    required this.progress,
    required this.buffered,
    required this.ticks,
    required this.active,
    required this.focused,
  });
  final double progress;
  final double buffered;
  final List<double> ticks;
  final bool active;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final h = active ? 6.0 : 4.0;
    final y = size.height / 2;
    RRect bar(double from, double to) => RRect.fromLTRBR(
        size.width * from, y - h / 2, size.width * to, y + h / 2,
        Radius.circular(h / 2));
    canvas.drawRRect(bar(0, 1), Paint()..color = Colors.white24);
    canvas.drawRRect(
        bar(0, buffered.clamp(progress, 1.0)), Paint()..color = Colors.white38);
    canvas.drawRRect(bar(0, progress), Paint()..color = Palette.accent);
    final tick = Paint()..color = Colors.black.withValues(alpha: 0.7);
    for (final t in ticks) {
      canvas.drawRect(
          Rect.fromLTWH(size.width * t - 1, y - h / 2, 2, h), tick);
    }
    final center = Offset(size.width * progress, y);
    if (focused) {
      canvas.drawCircle(center, 12, Paint()..color = Colors.white);
    }
    canvas.drawCircle(
        center, active ? 8 : 6, Paint()..color = Palette.accent);
  }

  @override
  bool shouldRepaint(_SeekPainter old) =>
      old.progress != progress ||
      old.buffered != buffered ||
      old.active != active ||
      old.focused != focused ||
      !listEquals(old.ticks, ticks);
}

/// Round control used over video. Always has a tooltip (and so a label).
class PlayerButton extends StatelessWidget {
  const PlayerButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 26,
    this.filled = false,
    this.focusNode,
    this.autofocus = false,
    this.iconWidget,
  });
  final IconData icon;

  /// Drawn instead of [icon] when set (e.g. a [SkipIcon]).
  final Widget? iconWidget;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final bool filled;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      focusNode: focusNode,
      autofocus: autofocus,
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: size,
      padding: EdgeInsets.all(filled ? 14 : 10),
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? Colors.white30 : Colors.white),
        backgroundColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.focused)) return Colors.white24;
          return filled ? Colors.black45 : Colors.transparent;
        }),
        side: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused)
                ? const BorderSide(color: Colors.white, width: 2.5)
                : null),
      ),
      icon: iconWidget ?? Icon(icon),
    );
  }
}

/// Circular-arrow skip icon showing [seconds]. Uses Material's numbered
/// icons where they exist (5, 10, 30) and draws the number otherwise.
class SkipIcon extends StatelessWidget {
  const SkipIcon({
    super.key,
    required this.seconds,
    required this.forward,
    this.size = 34,
  });
  final int seconds;
  final bool forward;
  final double size;

  @override
  Widget build(BuildContext context) {
    final numbered = switch ((forward, seconds)) {
      (false, 5) => Icons.replay_5_rounded,
      (false, 10) => Icons.replay_10_rounded,
      (false, 30) => Icons.replay_30_rounded,
      (true, 5) => Icons.forward_5_rounded,
      (true, 10) => Icons.forward_10_rounded,
      (true, 30) => Icons.forward_30_rounded,
      _ => null,
    };
    if (numbered != null) return Icon(numbered, size: size);
    final color = IconTheme.of(context).color;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // replay_rounded is the bare arrow; mirrored it points forward.
          Transform.flip(
            flipX: forward,
            child: Icon(Icons.replay_rounded, size: size),
          ),
          Padding(
            padding: EdgeInsets.only(top: size * 0.12),
            child: Text(
              '$seconds',
              style: TextStyle(
                color: color,
                fontSize: size * 0.3,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Titled list used for the audio, subtitle, quality and chapter panels.
class OptionPanel extends StatelessWidget {
  const OptionPanel({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Built eagerly rather than as a lazy ListView: a row that starts below
    // the fold would otherwise not exist yet, so its `autofocus` never fires
    // and a remote is left with nothing focused. These lists are short.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          ...children,
        ],
      ),
    );
  }
}

class OptionHeading extends StatelessWidget {
  const OptionHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11.5,
            letterSpacing: 1.3,
            fontWeight: FontWeight.w800,
            color: Palette.muted,
          ),
        ),
      );
}

class OptionTile extends StatelessWidget {
  const OptionTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
    this.autofocus = false,
  });
  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    // Arrow-key moves scroll the list already; this also covers the row
    // that takes focus when the panel opens, which may start off screen.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) {
          Scrollable.ensureVisible(context,
              alignment: 0.5, duration: const Duration(milliseconds: 150));
        }
      },
      child: _tile(),
    );
  }

  Widget _tile() {
    return ListTile(
      dense: true,
      autofocus: autofocus,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      focusColor: Palette.surfaceHigh,
      leading: Icon(
        selected ? Icons.check_rounded : null,
        color: Palette.accent,
        size: 20,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: Palette.text,
        ),
      ),
      trailing: detail == null
          ? null
          : Text(detail!,
              style: const TextStyle(color: Palette.muted, fontSize: 12.5)),
      onTap: onTap,
    );
  }
}
