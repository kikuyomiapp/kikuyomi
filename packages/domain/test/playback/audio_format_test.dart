import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:test/test.dart';

void main() {
  group('playable formats', () {
    test('play what they list and nothing else', () {
      const apple = PlayableFormats({
        AudioFormat.mp3,
        AudioFormat.mp4,
        AudioFormat.flac,
      });
      expect(apple.canPlay(AudioFormat.flac), isTrue);
      expect(apple.canPlay(AudioFormat.oggVorbis), isFalse);
      expect(apple.canPlay(AudioFormat.oggOpus), isFalse);
    });

    test('all play every format there is', () {
      for (final format in AudioFormat.values) {
        expect(
          PlayableFormats.all.canPlay(format),
          isTrue,
          reason: format.name,
        );
      }
    });
  });

  group('a book refused for its format', () {
    test('names the format', () {
      final error = UnplayableFormatException([AudioFormat.oggOpus]);
      expect(error.message, 'this device cannot play Ogg Opus audio');
      expect(error.toString(), contains('Ogg Opus'));
    });

    test('names each of several formats once, in a fixed order', () {
      final error = UnplayableFormatException([
        AudioFormat.oggOpus,
        AudioFormat.oggVorbis,
        AudioFormat.oggOpus,
      ]);
      expect(error.formats, [AudioFormat.oggVorbis, AudioFormat.oggOpus]);
      expect(
        error.message,
        'this device cannot play Ogg Vorbis or Ogg Opus audio',
      );
      expect(
        UnplayableFormatException([
          AudioFormat.oggOpus,
          AudioFormat.flac,
          AudioFormat.oggVorbis,
        ]).message,
        'this device cannot play FLAC, Ogg Vorbis or Ogg Opus audio',
      );
    });

    test('must name a format', () {
      expect(() => UnplayableFormatException(const []), throwsArgumentError);
    });
  });
}
