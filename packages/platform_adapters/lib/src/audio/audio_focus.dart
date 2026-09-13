import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';

/// §6.5's audio focus and interruptions, through `audio_session`.
///
/// Configures the audio session for spoken audio, then reports what the system does to the audio as
/// [SystemAudioEvent]s for the coordinator to act on. On iOS the session uses the playback category,
/// the spoken-audio mode and long-form route sharing, as Appendix A asks. On Android it declares
/// speech content, so that a navigation prompt pauses the book instead of talking over it.
///
/// Windows has no audio session: configuring does nothing there, and [events] never emits.
final class AudioFocus {
  AudioFocus._(this._session);

  /// Configures the session. Run once at start, before anything plays.
  static Future<AudioFocus> configure() async {
    final session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration.speech().copyWith(
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.longFormAudio,
      ),
    );
    return AudioFocus._(session);
  }

  final AudioSession _session;

  /// Interruptions and lost outputs, as they happen.
  Stream<SystemAudioEvent> get events => Stream.multi((controller) {
    final subscriptions = [
      _session.interruptionEventStream.listen(
        (event) => controller.add(_translate(event)),
      ),
      _session.becomingNoisyEventStream.listen(
        (_) => controller.add(const AudioOutputLost()),
      ),
    ];
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
  });

  /// audio_session reports the end of an interruption that may resume as `pause` or `duck`, and
  /// one that should not as `unknown`: on iOS, `unknown` means the system did not offer to resume.
  static SystemAudioEvent _translate(AudioInterruptionEvent event) =>
      event.begin
      ? const AudioInterruptionBegan()
      : AudioInterruptionEnded(
          mayResume: event.type != AudioInterruptionType.unknown,
        );
}
