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

  /// Whole seconds left at [position], rounded up (never below 0).
  int secondsLeft(Duration total, Duration position) {
    final ms = (total - position).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }
}
