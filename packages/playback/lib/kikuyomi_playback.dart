/// `PlaybackCoordinator`, progress store, sleep timer and resume rules.
///
/// The audio engine sits behind an interface so this logic can be tested against a fake engine and
/// a controllable clock.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/engine.dart';
export 'src/progress_tracker.dart';
export 'src/sleep_timer.dart';
export 'src/smart_rewind.dart';
