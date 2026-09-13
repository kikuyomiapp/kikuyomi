/// Entities, use cases, repository and service interfaces, and the Timeline.
///
/// The Timeline maps logical chapters onto physical audio files, which are not the same thing for
/// most audiobooks. Progress is stored chapter-relative; global position is derived here.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/clock.dart';
export 'src/timeline/positions.dart';
export 'src/timeline/timeline.dart';
export 'src/timeline/timeline_input.dart';
