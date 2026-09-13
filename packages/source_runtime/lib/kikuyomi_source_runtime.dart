/// QuickJS host, bridges, worker isolate pool, watchdog and output validation.
///
/// Extension output is untrusted. It is decoded into strict types and validated at this boundary
/// before anything else in the app sees it.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;
