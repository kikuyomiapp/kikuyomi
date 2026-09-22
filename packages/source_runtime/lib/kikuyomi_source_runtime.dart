/// QuickJS host, bridges, worker isolate pool, watchdog and output validation.
///
/// Extension output is untrusted. It is decoded into strict types and validated at this boundary
/// before anything else in the app sees it.
///
/// Pure Dart. This package must never import Flutter or a platform plugin. The engine itself sits
/// behind [ScriptEngine] (ADR-0001), and the implementation over the vendored QuickJS binding lives
/// in `platform_adapters`, which is allowed to depend on plugins.
library;

export 'src/bridges/crypto_bridge.dart';
export 'src/bridges/host_bridge.dart';
export 'src/bridges/html_bridge.dart';
export 'src/bridges/http_bridge.dart';
export 'src/bridges/log_bridge.dart';
export 'src/bridges/storage_bridge.dart';
export 'src/engine/script_engine.dart';
export 'src/extension/extension_runtime.dart';
export 'src/extension/js_source_adapter.dart';
export 'src/extension/prelude.dart';
