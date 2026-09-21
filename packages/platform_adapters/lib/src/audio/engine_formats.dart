import 'dart:io';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// The audio formats the playback engine can play on this device: its row of §7.3's capability
/// matrix, so that features never ask which platform they run on.
///
/// The engine is `JustAudioEngine`, whose `just_audio` plays through a different player on each
/// platform (§6.2), and the player decides:
///
/// - Android: ExoPlayer, which plays every format here, Ogg Vorbis and Ogg Opus included. FLAC and
///   Opus go to the platform's own decoders; Android has had its Opus decoder since 5.0, and its
///   FLAC decoder, as far as is known here, since 8.1, while the app's minimum is 7.0. Nothing asks
///   the running version yet, so FLAC counts as playable on every Android device.
/// - Windows, and Linux: mpv, through `just_audio_media_kit`, which `JustAudioEngine.initialize`
///   turns on there, and whose FFmpeg decodes every format here.
/// - iOS, and macOS: AVFoundation, which plays MP3, MPEG-4 and FLAC, but neither Vorbis nor Opus in
///   an Ogg file (Appendix A).
abstract final class EngineFormats {
  /// The formats the engine can play on this device.
  static PlayableFormats forThisDevice() => on(Platform.operatingSystem);

  /// The formats the engine can play on the platform [operatingSystem] names, in the words of
  /// `Platform.operatingSystem`. A platform the engine has no player for is given only MP3 and
  /// MPEG-4, which every player has.
  static PlayableFormats on(String operatingSystem) =>
      switch (operatingSystem) {
        'android' || 'windows' || 'linux' => PlayableFormats.all,
        'ios' || 'macos' => avFoundation,
        _ => const PlayableFormats({AudioFormat.mp3, AudioFormat.mp4}),
      };

  /// What AVFoundation plays, on iOS and macOS.
  static const avFoundation = PlayableFormats({
    AudioFormat.mp3,
    AudioFormat.mp4,
    AudioFormat.flac,
  });
}
