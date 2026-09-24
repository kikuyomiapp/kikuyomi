/// Per-OS implementations of the interfaces the pure packages declare.
///
/// Audio backend, media session, download transport, storage locations, folder access, secure
/// storage, WebView challenge, power policy and diagnostics. Platform differences live here, so
/// features never contain a `Platform.isX` check.
///
/// Depends on Flutter by design; see docs/architecture.md section 2.4.
library;

export 'src/audio/audio_focus.dart';
export 'src/audio/audio_service_bridge.dart';
export 'src/audio/cached_audio_source.dart';
export 'src/downloads/background_transport.dart';
export 'src/audio/engine_formats.dart';
export 'src/audio/just_audio_engine.dart';
export 'src/audio/stream_audio_cache.dart';
export 'src/audio/system_media_controls.dart';
export 'src/drop/file_drop_target.dart' show FileDropTarget;
export 'src/scripting/quickjs_script_engine.dart';
export 'src/storage/device_folders.dart';
export 'src/storage/shared_preferences_settings_store.dart';
export 'src/storage/storage_locations.dart';
