/// Download queue, scheduler, state machine, post-processing and storage accounting.
///
/// Queue items are physical files, not chapters. URLs are resolved just in time, because many
/// sources hand out links that expire. The transport itself sits behind an interface.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/post/downloaded_files.dart';
export 'src/post/file_check.dart';
export 'src/queue/backoff.dart';
export 'src/queue/driver.dart';
export 'src/queue/rates.dart';
export 'src/queue/scheduler_policy.dart';
export 'src/queue/transitions.dart';
export 'src/transport.dart';
