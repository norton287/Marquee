/// When the player's "Up next" card appears and how its countdown runs.
///
/// With a credits marker in the second half, the card comes at the credits
/// and counts down on its own ([PlayerScreen]'s 12 s): skipping the credits
/// is the point. Without one (music videos, anything the server hasn't
/// marked) the card comes [lead] before the end and counts down the time
/// left: the next item starts when this one really ends. A fixed countdown
/// there cut music videos off about 10 s early (the user's TV, 2026-11-24).
class UpNextTiming {
  const UpNextTiming({required this.from, required this.toEnd});

  /// Where the card appears.
  final Duration from;

  /// The countdown is the time left, and the end of the video plays the next.
  final bool toEnd;

  static const lead = Duration(seconds: 25);

  factory UpNextTiming.of(Duration total, Duration? creditsStart) =>
      creditsStart != null && creditsStart > total * 0.5
          ? UpNextTiming(from: creditsStart, toEnd: false)
          : UpNextTiming(from: total - lead, toEnd: true);

  /// How long the position must stand still near the end ([stalledAtEnd]).
  static const endStall = Duration(seconds: 3);

  /// Counting down to the end waits for the player's end of file, which a
  /// stream that stops just short of its stated length never reports: the
  /// position stands still and the countdown hung at 1 (the user's TV,
  /// 2026-11-27). Standing still for [stillFor] ≥ [endStall] while playing,
  /// within 2 s of the end, counts as the end. Not for the credits
  /// countdown, which runs on its own timer. An unknown length (zero while a
  /// reopened stream loads) is never the end.
  bool stalledAtEnd(Duration total, Duration position, Duration stillFor) =>
      toEnd &&
      total > Duration.zero &&
      total - position <= const Duration(seconds: 2) &&
      stillFor >= endStall;

  /// Whole seconds left at [position], rounded up (never below 0).
  int secondsLeft(Duration total, Duration position) {
    final ms = (total - position).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }
}
