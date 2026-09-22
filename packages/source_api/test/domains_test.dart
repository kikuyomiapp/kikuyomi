// The domains on the permissions screen are a promise: these are every host the source can make the
// app contact. Everything here is a way that promise could be got around.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

void main() {
  final list = DomainAllowlist([
    'librivox.org',
    'archive.org',
    '*.us.archive.org',
  ]);

  group('building the list', () {
    test(
      'keeps the entries for the permissions screen, in the manifest\'s order',
      () {
        expect(list.domains, [
          'librivox.org',
          'archive.org',
          '*.us.archive.org',
        ]);
      },
    );

    test('normalises case and a trailing dot, and drops repeats', () {
      final normalised = DomainAllowlist([
        'Example.ORG.',
        'example.org',
        '*.CDN.example.org',
      ]);
      expect(normalised.domains, ['example.org', '*.cdn.example.org']);
    });

    test('refuses an entry that is not a domain', () {
      for (final entry in [
        'com', // a whole top-level domain
        '*.com',
        '*', // every host there is
        '*example.org',
        'a.*.org',
        'example.org:8080', // a port is not a domain
        'https://example.org',
        'example.org/books',
        '127.0.0.1',
        '0x7f000001',
        '[::1]',
        'localhost',
        '*.localhost',
        'bücher.example', // an A-label is what the app can compare
        'exa mple.org',
        'a..b',
        '-example.org',
        '',
      ]) {
        expect(
          () => DomainAllowlist([entry]),
          throwsFormatException,
          reason: entry,
        );
      }
    });

    test('allows nothing when it is empty', () {
      expect(DomainAllowlist.none.allowsHost('example.org'), isFalse);
      expect(DomainAllowlist([]).allowsHost('example.org'), isFalse);
    });
  });

  group('matching a host', () {
    test('matches an exact entry, ignoring case and a trailing dot', () {
      expect(list.allowsHost('librivox.org'), isTrue);
      expect(list.allowsHost('LibriVox.ORG'), isTrue);
      expect(list.allowsHost('librivox.org.'), isTrue);
    });

    test('does not match a subdomain of an exact entry', () {
      expect(list.allowsHost('www.librivox.org'), isFalse);
    });

    test('matches a wildcard at any depth', () {
      expect(list.allowsHost('ia800300.us.archive.org'), isTrue);
      expect(list.allowsHost('a.b.us.archive.org'), isTrue);
    });

    test('does not match the wildcard\'s own domain, so both are listed to allow both', () {
      expect(list.allowsHost('us.archive.org'), isFalse);
      expect(
        DomainAllowlist(['us.archive.org', '*.us.archive.org'])
            .allowsHost('us.archive.org'),
        isTrue,
      );
    });

    test('does not match a host that merely ends with the entry', () {
      expect(list.allowsHost('evilarchive.org'), isFalse);
      // Ends with "us.archive.org", but the label boundary is what a wildcard matches on.
      expect(list.allowsHost('notus.archive.org'), isFalse);
      expect(list.allowsHost('us.archive.org.evil.com'), isFalse);
    });
  });

  group('checking a URL', () {
    Uri check(String url) => list.checkUrl(url);

    test('takes an http or https URL on an allowed host', () {
      expect(
        check('https://librivox.org/x').toString(),
        'https://librivox.org/x',
      );
      expect(
        check('http://ia800300.us.archive.org/a.mp3').host,
        'ia800300.us.archive.org',
      );
    });

    test('hands back the parsed URL, not the text, so the host checked is the host contacted', () {
      // Two parsers can read these differently; what leaves here is one normalised form.
      expect(
        check('HTTPS://LibriVox.ORG/Path').toString(),
        'https://librivox.org/Path',
      );
      expect(check('https://ia800300.us.archive%2Eorg/x'), isNotNull);
    });

    test('keeps the port, and any port is allowed on an allowed host', () {
      expect(check('https://librivox.org:8443/x').port, 8443);
    });

    test('refuses a host that is not on the list', () {
      expect(
        () => check('https://cdn.example.net/x'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('is not among the extension\'s domains'),
          ),
        ),
      );
    });

    test('refuses everything but http and https', () {
      for (final url in [
        'ftp://librivox.org/x',
        'file:///c:/books/a.mp3',
        'data:audio/mpeg;base64,AAAA',
        'javascript:alert(1)',
        'content://media/external/audio/1',
      ]) {
        expect(() => check(url), throwsFormatException, reason: url);
      }
    });

    test('refuses a relative URL: an extension resolves one against the page first', () {
      expect(() => check('/covers/1.jpg'), throwsFormatException);
      expect(() => check('//librivox.org/x'), throwsFormatException);
    });

    test('refuses a user name or password, which hides the real host from a reader', () {
      expect(
        () => check('https://librivox.org@evil.com/x'),
        throwsFormatException,
      );
      expect(
        () => check('https://user:pw@librivox.org/x'),
        throwsFormatException,
      );
    });

    test('refuses whitespace, control characters and backslashes', () {
      for (final url in [
        'https://librivox.org/a\nb',
        'https://librivox.org/a\tb',
        ' https://librivox.org/x',
        'https://librivox.org/x ',
        r'https://librivox.org\@evil.com/',
        'https://librivox.org/\u0000',
      ]) {
        expect(() => check(url), throwsFormatException, reason: url);
      }
    });

    test('percent-encodes a space inside a path rather than refusing it', () {
      expect(
        check('https://librivox.org/a b.mp3').toString(),
        'https://librivox.org/a%20b.mp3',
      );
    });

    test('refuses an IP address, even one an allowlist names', () {
      for (final url in [
        'https://127.0.0.1/x',
        'https://[::1]/x',
        'https://0x7f000001/x',
        'https://2130706433/x',
      ]) {
        expect(() => check(url), throwsFormatException, reason: url);
      }
    });

    test('refuses localhost, which is the listener\'s own device', () {
      expect(() => check('http://localhost:8080/x'), throwsFormatException);
      expect(() => check('http://api.localhost/x'), throwsFormatException);
    });

    test('refuses an internationalised host that is not in its xn-- form', () {
      expect(() => check('https://bücher.example/x'), throwsFormatException);
      final punycode = DomainAllowlist(['xn--bcher-kva.example']);
      expect(punycode.checkUrl('https://xn--bcher-kva.example/x'), isNotNull);
    });

    test('refuses a port that is not a port', () {
      expect(
        () => check('https://librivox.org:99999/x'),
        throwsFormatException,
      );
    });

    test('refuses a URL with no host at all', () {
      expect(() => check('https:///x'), throwsFormatException);
      expect(() => check('https://'), throwsFormatException);
    });

    test('says the same thing through allows() as through checkUrl()', () {
      expect(list.allows(Uri.parse('https://librivox.org/x')), isTrue);
      expect(list.allows(Uri.parse('https://evil.com/x')), isFalse);
      expect(list.problemWith(Uri.parse('https://librivox.org/x')), isNull);
      expect(
        list.problemWith(Uri.parse('https://evil.com/x')),
        contains('not among'),
      );
    });
  });
}
