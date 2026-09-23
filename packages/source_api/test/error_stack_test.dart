// Where an error the extension did not mean to throw came from.
//
// A bare "TypeError: not a function" is true and useless: it names neither the function nor the line,
// and an author reading it in the extension console has nothing to go on. QuickJS puts both in the
// error's stack, the prelude hands the stack over as data, and the decoder keeps the frames nearest the
// failure. The rules below are the ones that keep that useful without turning every message into a
// wall of frames.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  /// A thrown JavaScript error, as `describeThrow` hands one over.
  Map<String, Object?> accident({Object? stack}) => {
    'name': 'TypeError',
    'message': 'not a function',
    if (stack != null) 'stack': stack,
  };

  test('an accidental error says where it came from', () {
    final error = decoder.decodeError(
      accident(
        stack:
            '    at parseBookCards (main.js:284)\n'
            '    at getPopular (main.js:612)\n'
            '    at <anonymous> (kikuyomi:call)',
      ),
    );

    expect(error, isA<ParseException>());
    expect(error.message, startsWith('TypeError: not a function ('));
    expect(error.message, contains('parseBookCards (main.js:284)'));
    expect(error.message, contains('getPopular (main.js:612)'));
  });

  test('only the frames nearest the failure are kept', () {
    // A message is cut to length, so the far frames would crowd out the near ones.
    final error = decoder.decodeError(
      accident(
        stack: [
          for (var frame = 1; frame <= 20; frame++)
            '    at f$frame (main.js:$frame)',
        ].join('\n'),
      ),
    );

    expect(error.message, contains('f1 (main.js:1)'));
    expect(error.message, contains('f3 (main.js:3)'));
    expect(error.message, isNot(contains('f4 ')));
  });

  test('an error with no stack reads as it did before', () {
    expect(
      decoder.decodeError(accident()).message,
      'TypeError: not a function',
    );
  });

  test('a stack that is not text, or holds no frame, is ignored', () {
    expect(
      decoder.decodeError(accident(stack: 42)).message,
      'TypeError: not a function',
    );
    expect(
      decoder.decodeError(accident(stack: '   \n  \n')).message,
      'TypeError: not a function',
    );
  });

  test('a kind thrown on purpose keeps its own sentence alone', () {
    // The author wrote that message deliberately, and the app shows it to a listener under a sentence
    // of its own. Frames underneath would be noise where no one can act on them.
    final error = decoder.decodeError({
      'kind': 'NotFound',
      'message': 'book 42 is gone',
      'stack': '    at getBookDetails (main.js:100)',
    });

    expect(error, isA<NotFoundException>());
    expect(error.message, 'book 42 is gone');
  });

  test('a stack survives a message the extension did not give', () {
    final error = decoder.decodeError({
      'name': 'ReferenceError',
      'stack': '    at search (main.js:31)',
    });

    expect(error.message, 'ReferenceError (at search (main.js:31))');
  });
}
