/// Entities, use cases, repository and service interfaces, and the Timeline.
///
/// The Timeline maps logical chapters onto physical audio files, which are not the same thing for
/// most audiobooks. Progress is stored chapter-relative; global position is derived here.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/backup/library_snapshot.dart';
export 'src/backup/library_store.dart';
export 'src/backup/restore_plan.dart';
export 'src/clock.dart';
export 'src/downloads/download_state.dart';
export 'src/extensions/installed_extension.dart';
export 'src/library/book_field.dart';
export 'src/library/contributor_role.dart';
export 'src/playback/audio_format.dart';
export 'src/playback/listening_session.dart';
export 'src/playback/media_resolver.dart';
export 'src/playback/playback_store.dart';
export 'src/settings/app_settings.dart';
export 'src/settings/settings_store.dart';
export 'src/storage/user_folder.dart';
export 'src/timeline/positions.dart';
export 'src/timeline/timeline.dart';
export 'src/timeline/timeline_input.dart';
