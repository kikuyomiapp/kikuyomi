/// A position or duration as a clock: `m:ss`, or `h:mm:ss` from an hour up.
String formatClock(int milliseconds) {
  final totalSeconds = (milliseconds < 0 ? 0 : milliseconds) ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

/// A length as a person says it: `5 h 15 m`, `42 m`, or `< 1 m` for anything shorter.
///
/// Apart from [formatClock], which is for a position ticking beside a scrubber. A book's length in a
/// grid of covers is read at a glance, not followed second by second.
String formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 1) return '< 1 m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest m';
  return rest == 0 ? '$hours h' : '$hours h $rest m';
}
