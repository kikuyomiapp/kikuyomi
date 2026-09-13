/// What the operating system does to the app's audio, as §6.5's focus and interruption rules need
/// it. The platform adapter translates its audio session's events into these, and the coordinator
/// decides what each one means for the open book.
sealed class SystemAudioEvent {
  const SystemAudioEvent();
}

/// Something else took the audio: a phone call, a navigation prompt, another app starting to play.
final class AudioInterruptionBegan extends SystemAudioEvent {
  const AudioInterruptionBegan();
}

/// The interruption is over.
final class AudioInterruptionEnded extends SystemAudioEvent {
  const AudioInterruptionEnded({required this.mayResume});

  /// Whether the system considers it appropriate to start again. It does when a call ends, and does
  /// not when another app has taken the audio for good.
  final bool mayResume;
}

/// The audio output went away: headphones unplugged, or a Bluetooth device disconnected.
final class AudioOutputLost extends SystemAudioEvent {
  const AudioOutputLost();
}
