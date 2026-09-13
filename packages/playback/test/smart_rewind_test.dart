import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';
import 'package:test/test.dart';

Duration sec(int n) => Duration(seconds: n);

void main() {
  final rewind = SmartRewind();

  group('default tiers', () {
    test('a short pause does not rewind', () {
      expect(rewind.rewindAfter(sec(2)), Duration.zero);
    });

    test('a longer pause rewinds a few seconds', () {
      expect(rewind.rewindAfter(sec(30)), sec(3));
    });

    test('a pause of some minutes rewinds further', () {
      expect(rewind.rewindAfter(const Duration(minutes: 10)), sec(10));
    });

    test('a long break rewinds the full 30 seconds §6.4 allows', () {
      expect(rewind.rewindAfter(const Duration(hours: 3)), sec(30));
    });

    test('a threshold is inclusive', () {
      expect(rewind.rewindAfter(sec(10)), sec(3));
      expect(
        rewind.rewindAfter(const Duration(milliseconds: 9999)),
        Duration.zero,
      );
    });

    test('a negative pause, from a clock set back, is no pause', () {
      expect(rewind.rewindAfter(const Duration(minutes: -5)), Duration.zero);
    });
  });

  group('resuming', () {
    test('steps back within the chapter', () {
      final saved = const ChapterPosition(chapterId: 5, offsetMs: 60000);
      expect(
        rewind.resumeFrom(saved, const Duration(hours: 3)),
        const ChapterPosition(chapterId: 5, offsetMs: 30000),
      );
    });

    test('never crosses back into the previous chapter', () {
      final saved = const ChapterPosition(chapterId: 5, offsetMs: 2000);
      expect(
        rewind.resumeFrom(saved, const Duration(hours: 3)),
        const ChapterPosition(chapterId: 5, offsetMs: 0),
      );
    });
  });

  group('configuration', () {
    test('custom tiers are honoured', () {
      final custom = SmartRewind(
        tiers: [(pausedAtLeast: sec(1), rewind: sec(20))],
      );
      expect(custom.rewindAfter(Duration.zero), Duration.zero);
      expect(custom.rewindAfter(sec(1)), sec(20));
    });

    test('no tiers means no rewind', () {
      expect(
        SmartRewind(tiers: const []).rewindAfter(const Duration(days: 1)),
        Duration.zero,
      );
    });

    test('thresholds must strictly increase', () {
      expect(
        () => SmartRewind(
          tiers: [
            (pausedAtLeast: sec(10), rewind: sec(3)),
            (pausedAtLeast: sec(10), rewind: sec(5)),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('durations cannot be negative', () {
      expect(
        () => SmartRewind(tiers: [(pausedAtLeast: sec(0), rewind: sec(-1))]),
        throwsArgumentError,
      );
    });
  });
}
