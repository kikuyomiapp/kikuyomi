// The rules that hold wherever a value appears: what plain data is, how numbers must be written,
// what happens to whitespace and control characters, and what a refusal tells the author.
//
// These are the mistakes an extension author actually makes: a scraped number left as a string, a
// duration divided rather than multiplied, `selectFirst` returning null, a title with a newline in
// it. Each one should name the field it happened in.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('a refusal', () {
    test(
      'names the field, in the notation the author would use to reach it',
      () {
        expect(
          () => decoder.decodeBookPage(
            page([summary(), summary(key: 'b2', title: '')]),
          ),
          rejects('items[1].title'),
        );
        expect(
          () => decoder.decodeMediaResolution(
            resolution(
              segments: [
                segment(
                  and: {
                    'variants': [
                      {
                        'label': '64 kbps',
                        'request': request(
                          and: {
                            'headers': {'Referer': 7},
                          },
                        ),
                      },
                    ],
                  },
                ),
              ],
            ),
          ),
          rejects('segments[0].variants[0].request.headers["Referer"]'),
        );
      },
    );

    test('is a Parse failure, whatever the rule broken', () {
      expect(
        () => decoder.decodeChapters('nothing'),
        throwsA(
          isA<ParseException>().having((error) => error.kind, 'kind', 'Parse'),
        ),
      );
    });
  });

  group('plain data', () {
    test('is what the contract says it is, and nothing else', () {
      for (final value in [
        'Moby-Dick',
        7,
        true,
        <Object?>[],
        <String, Object?>{},
        null,
        DateTime.utc(2026),
        BigInt.one,
        Uri.parse('https://example.org/'),
      ]) {
        // Anything that is not an object fails the same way, naming what arrived instead.
        expect(
          () => decoder.decodeBookDetails(value),
          value is Map
              ? rejects('key')
              : rejects('the result', 'expected an object'),
          reason: '$value',
        );
      }
    });

    test('is read from an object however its keys are typed', () {
      final loose = <Object?, Object?>{'key': 'b1', 'title': 'Moby-Dick'};
      expect(
        decoder
            .decodeBookPage({
              'items': [loose],
              'hasNextPage': false,
            })
            .items
            .single
            .key,
        'b1',
      );
    });

    test('ignores nesting inside a field the contract does not have', () {
      Object? nest(int depth) {
        Object? value = 'deep';
        for (var i = 0; i < depth; i++) {
          value = {'next': value};
        }
        return value;
      }

      expect(
        decoder.decodeBookDetails(details(and: {'extras': nest(5000)})).title,
        'Moby-Dick',
      );
    });
  });

  group('numbers', () {
    test('are read from the whole doubles JavaScript writes them as', () {
      final book = decoder.decodeBookDetails(
        details(and: {'totalDurationMs': 87000000.0}),
      );
      expect(book.totalDurationMs, 87000000);
    });

    test(
      'are refused when they are not whole, because milliseconds are whole',
      () {
        expect(
          () =>
              decoder.decodeBookDetails(details(and: {'totalDurationMs': 1.5})),
          rejects('totalDurationMs', 'is not a whole number'),
        );
      },
    );

    test('are refused when they are NaN or infinite, which is what a bad division gives', () {
      expect(
        () => decoder.decodeBookDetails(
          details(and: {'totalDurationMs': double.nan}),
        ),
        rejects('totalDurationMs', 'NaN'),
      );
      expect(
        () => decoder.decodeBookDetails(
          details(and: {'totalDurationMs': double.infinity}),
        ),
        rejects('totalDurationMs', 'finite'),
      );
    });

    test('are refused when they are negative', () {
      expect(
        () => decoder.decodeBookDetails(details(and: {'totalDurationMs': -1})),
        rejects('totalDurationMs', 'negative'),
      );
    });

    test('are refused beyond the whole numbers JavaScript holds exactly', () {
      expect(
        decoder
            .decodeBookDetails(
              details(and: {'totalDurationMs': SourceLimits.maxSafeInteger}),
            )
            .totalDurationMs,
        SourceLimits.maxSafeInteger,
      );
      expect(
        () => decoder.decodeBookDetails(
          details(and: {'totalDurationMs': SourceLimits.maxSafeInteger + 1}),
        ),
        rejects('totalDurationMs', 'holds exactly'),
      );
      expect(
        () =>
            decoder.decodeBookDetails(details(and: {'totalDurationMs': 1e300})),
        rejects('totalDurationMs', 'holds exactly'),
      );
    });

    test('are refused when they are text, however numeric the text looks', () {
      expect(
        () => decoder.decodeBookDetails(
          details(and: {'totalDurationMs': '87000000'}),
        ),
        rejects('totalDurationMs', 'expected a number, got a string'),
      );
    });
  });

  group('text', () {
    test('is trimmed, and folded onto one line', () {
      final book = decoder.decodeBookDetails(
        details(and: {'publisher': '  Harper\n&\tBrothers  '}),
      );
      expect(book.publisher, 'Harper & Brothers');
    });

    test('keeps a description\'s line breaks, and writes them all one way', () {
      final book = decoder.decodeBookDetails(
        details(and: {'description': 'One.\r\nTwo.\rThree.\nFour.\t '}),
      );
      expect(book.description, 'One.\nTwo.\nThree.\nFour.');
    });

    test('is absent when the source gave nothing but whitespace', () {
      expect(
        decoder.decodeBookDetails(details(and: {'subtitle': '   '})).subtitle,
        isNull,
      );
      expect(
        decoder.decodeBookDetails(details(and: {'subtitle': ''})).subtitle,
        isNull,
      );
    });

    test('is refused when a required field holds nothing but whitespace', () {
      expect(
        () => decoder.decodeBookDetails(details(and: {'title': ' \n '})),
        rejects('title', 'is empty'),
      );
    });

    test('holds 1,000 characters, and refuses 1,001', () {
      expect(
        decoder.decodeBookDetails(details(and: {'title': text(1000)})).title,
        hasLength(1000),
      );
      expect(
        () => decoder.decodeBookDetails(details(and: {'title': text(1001)})),
        rejects('title', 'longer than 1,000 characters'),
      );
    });

    test('measures a limit the way JavaScript measures a string', () {
      // An emoji is two code units in JavaScript and here alike, so an author checking length in the
      // extension gets the same answer the app does.
      final emoji = '🐋' * 500;
      expect(emoji.length, 1000);
      expect(
        decoder.decodeBookDetails(details(and: {'title': emoji})).title,
        hasLength(1000),
      );
      expect(
        () => decoder.decodeBookDetails(details(and: {'title': '$emoji!'})),
        rejects('title', 'longer than 1,000'),
      );
    });

    test('refuses a control character other than a tab or a line break', () {
      expect(
        () => decoder.decodeBookDetails(
          details(and: {'title': 'Moby\u0007Dick'}),
        ),
        rejects('title', 'control character (U+0007)'),
      );
      expect(
        () => decoder.decodeBookDetails(
          details(and: {'description': 'a\u007fb'}),
        ),
        rejects('description', 'control character (U+007F)'),
      );
    });

    test('keeps the characters a badly encoded site produces, which are not control characters', () {
      // U+0092 comes of reading Windows-1252 as Latin-1. It is mojibake, not a threat, and refusing
      // a whole page over one would take the book away for a wrong apostrophe.
      expect(
        decoder
            .decodeBookDetails(details(and: {'title': 'Moby\u0092s Dick'}))
            .title,
        'Moby\u0092s Dick',
      );
    });
  });

  group('a key', () {
    test('is 1 to 512 characters', () {
      expect(
        decoder.decodeBookDetails(details(and: {'key': text(512)})).key,
        hasLength(512),
      );
      expect(
        () => decoder.decodeBookDetails(details(and: {'key': text(513)})),
        rejects('key', 'longer than 512 characters'),
      );
      expect(
        () => decoder.decodeBookDetails(details(and: {'key': ''})),
        rejects('key', 'is empty'),
      );
    });

    test('holds no control characters, tabs and line breaks included', () {
      expect(
        () => decoder.decodeBookDetails(details(and: {'key': 'b\t1'})),
        rejects('key', 'control character (U+0009)'),
      );
    });
  });
}
