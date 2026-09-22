// What an extension throws. The app reacts to the kind — a browser for a challenge, backing off for
// a rate limit, marking a book gone — so keeping the kind, and never inventing one, is the point.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('reads each kind the contract has', () {
    expect(
      decoder.decodeError({
        'kind': 'LoginRequired',
        'message': 'sign in first',
      }),
      isA<LoginRequiredException>().having(
        (e) => e.message,
        'message',
        'sign in first',
      ),
    );
    expect(decoder.decodeError({'kind': 'NotFound'}), isA<NotFoundException>());
    expect(
      decoder.decodeError({'kind': 'SourceOutdated'}),
      isA<SourceOutdatedException>(),
    );
    expect(decoder.decodeError({'kind': 'Network'}), isA<NetworkException>());
    expect(decoder.decodeError({'kind': 'Parse'}), isA<ParseException>());
  });

  test(
    'keeps the page a challenge points at, when the extension may point there',
    () {
      final error = decoder.decodeError({
        'kind': 'ChallengeRequired',
        'url': 'https://example.org/checking-your-browser',
        'message': 'anti-bot check',
      });
      expect(
        error,
        isA<ChallengeRequiredException>()
            .having(
              (e) => e.url,
              'url',
              Uri.parse('https://example.org/checking-your-browser'),
            )
            .having((e) => e.message, 'message', 'anti-bot check'),
      );
      expect(error.toString(), contains('ChallengeRequired'));
    },
  );

  test('will not open a challenge on a host the extension never declared', () {
    // Otherwise a source could send a listener to any page it liked, with the app's blessing.
    expect(
      decoder.decodeError({
        'kind': 'ChallengeRequired',
        'url': 'https://evil.com/login',
      }),
      isA<ParseException>().having(
        (e) => e.message,
        'message',
        contains('not among'),
      ),
    );
    expect(
      decoder.decodeError({'kind': 'ChallengeRequired'}),
      isA<ParseException>().having(
        (e) => e.message,
        'message',
        contains('without a url'),
      ),
    );
  });

  test('keeps a rate limit even when its retry figure cannot be read', () {
    // Losing the kind would mean hammering a site that has just asked for a pause.
    for (final retry in [null, 'soon', -1, 1.5, double.nan]) {
      final error = decoder.decodeError({
        'kind': 'RateLimited',
        'retryAfterMs': retry,
      });
      expect(
        error,
        isA<RateLimitedException>().having(
          (e) => e.retryAfterMs,
          'retryAfterMs',
          isNull,
        ),
        reason: '$retry',
      );
    }
    expect(
      decoder.decodeError({'kind': 'RateLimited', 'retryAfterMs': 5000}),
      isA<RateLimitedException>().having(
        (e) => e.retryAfterMs,
        'retryAfterMs',
        5000,
      ),
    );
    expect(
      decoder.decodeError({'kind': 'RateLimited', 'retryAfterMs': 5000.0}),
      isA<RateLimitedException>().having(
        (e) => e.retryAfterMs,
        'retryAfterMs',
        5000,
      ),
    );
  });

  test('reads a kind a later version added as Parse, which is what keeps adding kinds additive', () {
    final error = decoder.decodeError({
      'kind': 'CaptchaSolved',
      'message': 'try again',
    });
    expect(error, isA<ParseException>());
    expect(error.message, contains('CaptchaSolved'));
    expect(error.message, contains('try again'));
  });

  test('reads a plain JavaScript error as Parse, keeping what it said', () {
    final error = decoder.decodeError({
      'name': 'TypeError',
      'message': 'doc.selectFirst(...) is null',
    });
    expect(error, isA<ParseException>());
    expect(error.message, 'TypeError: doc.selectFirst(...) is null');
  });

  test('reads anything else thrown as Parse, and never throws itself', () {
    expect(decoder.decodeError('went wrong').message, 'went wrong');
    expect(decoder.decodeError(null), isA<ParseException>());
    expect(decoder.decodeError(7), isA<ParseException>());
    expect(decoder.decodeError(['a']).message, contains('an array'));
    expect(decoder.decodeError({'kind': 7}), isA<ParseException>());
  });

  test('hands back an error the app raised itself unchanged', () {
    const already = NotFoundException('gone');
    expect(decoder.decodeError(already), same(already));
  });

  test('cuts a message down to something that can be shown and logged', () {
    final error = decoder.decodeError({
      'kind': 'Network',
      'message': text(5000),
    });
    expect(error.message.length, lessThanOrEqualTo(1001));
    expect(error.message, endsWith('…'));
  });

  test('takes the control characters out of a message rather than losing the kind for them', () {
    final error = decoder.decodeError({
      'kind': 'Network',
      'message': 'timed out\n\tat fetch\u0000',
    });
    expect(error, isA<NetworkException>());
    expect(error.message, 'timed out  at fetch');
  });

  group('the kinds themselves', () {
    test(
      'say what they are, for the console and for the extension\'s health',
      () {
        expect(const NotFoundException().kind, 'NotFound');
        expect(const RateLimitedException().kind, 'RateLimited');
        expect(const ParseException('items[0].title: is empty').kind, 'Parse');
        expect(
          const ParseException('items[0].title: is empty').toString(),
          'Parse: items[0].title: is empty',
        );
        expect(const LoginRequiredException().toString(), 'LoginRequired');
        expect(
          const RateLimitedException(retryAfterMs: 5000).toString(),
          contains('retry after 5000ms'),
        );
      },
    );

    test(
      'are one sealed family, so the app can be made to react to every one',
      () {
        const errors = <SourceException>[
          LoginRequiredException(),
          RateLimitedException(),
          NotFoundException(),
          SourceOutdatedException(),
          NetworkException(),
          ParseException(),
        ];
        for (final error in errors) {
          final reaction = switch (error) {
            ChallengeRequiredException() => 'open a browser',
            LoginRequiredException() => 'say a login is needed',
            RateLimitedException() => 'back off',
            NotFoundException() => 'mark it unavailable',
            SourceOutdatedException() => 'suggest an update',
            NetworkException() || ParseException() => 'retry',
          };
          expect(reaction, isNotEmpty);
        }
      },
    );
  });
}
