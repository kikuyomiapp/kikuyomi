import 'dart:math' as math;

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// One step of the smart rewind policy: after a pause of at least [pausedAtLeast], step back by
/// [rewind].
typedef RewindTier = ({Duration pausedAtLeast, Duration rewind});

/// §6.4 smart rewind: no rewind after a short pause, a few seconds after a longer one, and up to 30
/// seconds after a long break.
///
/// The section fixes the shape and the 30-second ceiling but not the thresholds, so the defaults in
/// [defaultTiers] are a judgement call and the tiers are configurable, as the section requires.
final class SmartRewind {
  /// Throws [ArgumentError] unless [tiers] have non-negative durations and strictly increasing
  /// pause thresholds. Pauses shorter than the first tier get no rewind.
  SmartRewind({List<RewindTier> tiers = defaultTiers})
    : tiers = List.unmodifiable(tiers) {
    for (var i = 0; i < tiers.length; i++) {
      final tier = tiers[i];
      if (tier.pausedAtLeast.isNegative || tier.rewind.isNegative) {
        throw ArgumentError.value(
          tiers,
          'tiers',
          'durations cannot be negative',
        );
      }
      if (i > 0 && tier.pausedAtLeast <= tiers[i - 1].pausedAtLeast) {
        throw ArgumentError.value(
          tiers,
          'tiers',
          'pause thresholds must strictly increase',
        );
      }
    }
  }

  static const List<RewindTier> defaultTiers = [
    (pausedAtLeast: Duration.zero, rewind: Duration.zero),
    (pausedAtLeast: Duration(seconds: 10), rewind: Duration(seconds: 3)),
    (pausedAtLeast: Duration(minutes: 5), rewind: Duration(seconds: 10)),
    (pausedAtLeast: Duration(hours: 1), rewind: Duration(seconds: 30)),
  ];

  final List<RewindTier> tiers;

  /// How far to step back after a pause of [pause].
  ///
  /// A negative pause, as happens when the device clock is set back, is treated as no pause.
  Duration rewindAfter(Duration pause) {
    var rewind = Duration.zero;
    for (final tier in tiers) {
      if (pause >= tier.pausedAtLeast) {
        rewind = tier.rewind;
      } else {
        break;
      }
    }
    return rewind;
  }

  /// Where to resume a saved position after a pause of [pause].
  ///
  /// Never crosses back into the previous chapter: someone resuming chapter five near its start
  /// expects the start of chapter five, not the closing seconds of chapter four.
  ChapterPosition resumeFrom(ChapterPosition saved, Duration pause) =>
      ChapterPosition(
        chapterId: saved.chapterId,
        offsetMs: math.max(
          0,
          saved.offsetMs - rewindAfter(pause).inMilliseconds,
        ),
      );
}
