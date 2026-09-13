/// Per-OS implementations of the interfaces the pure packages declare.
///
/// Audio backend, media session, download transport, storage locations, folder access, secure
/// storage, WebView challenge, power policy and diagnostics. Platform differences live here, so
/// features never contain a `Platform.isX` check.
///
/// Depends on Flutter by design; see docs/architecture.md section 2.4.
library;

export 'src/audio/just_audio_engine.dart';
