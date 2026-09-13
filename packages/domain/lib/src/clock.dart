/// Time, behind an interface.
///
/// §2.1 puts the clock behind an interface alongside the other external boundaries, so logic that
/// depends on elapsed time — throttled progress writes, smart rewind, sleep timers — can be tested
/// deterministically instead of by sleeping.
abstract interface class Clock {
  DateTime now();
}

/// The real clock.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
