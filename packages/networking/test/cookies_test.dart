// One extension's cookie jar: what a site may set, and what is sent back to it. Not a browser, and
// honest about it — there is no public-suffix list here, so the rule is that a site may set a
// cookie for itself or for a parent domain of at least two labels.

import 'package:kikuyomi_networking/kikuyomi_networking.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 9, 23, 12);
  CookieJar jar() => CookieJar(now: () => now);

  test('sends back what a site set, for the paths it set it for', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/login'), [
        'session=abc; Path=/',
        'reader=dark; Path=/books',
      ]);

    expect(cookies.headerFor(Uri.parse('https://example.org/')), 'session=abc');
    expect(
      cookies.headerFor(Uri.parse('https://example.org/books/12')),
      // Longest path first, as RFC 6265 orders them.
      'reader=dark; session=abc',
    );
  });

  test('a cookie with no domain goes back only to the host that set it', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/'), ['a=1']);

    expect(cookies.headerFor(Uri.parse('https://example.org/')), 'a=1');
    expect(cookies.headerFor(Uri.parse('https://www.example.org/')), isNull);
  });

  test('a cookie set for a parent domain goes to its subdomains', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://www.example.org/'), [
        'a=1; Domain=example.org',
      ]);

    expect(cookies.headerFor(Uri.parse('https://www.example.org/')), 'a=1');
    expect(cookies.headerFor(Uri.parse('https://cdn.example.org/')), 'a=1');
    expect(cookies.headerFor(Uri.parse('https://example.org/')), 'a=1');
  });

  test('a site cannot set a cookie for someone else, or for a whole tld', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/'), [
        'a=1; Domain=example.net',
        'b=2; Domain=org',
        'c=3; Domain=',
      ]);

    expect(cookies.cookies, isEmpty);
  });

  test('a Secure cookie is not sent over plain http', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/'), [
        'a=1; Secure',
        'b=2',
      ]);

    expect(cookies.headerFor(Uri.parse('https://example.org/')), 'a=1; b=2');
    expect(cookies.headerFor(Uri.parse('http://example.org/')), 'b=2');
  });

  test('an expired cookie is not sent, and Max-Age wins over Expires', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/'), [
        'gone=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
        'soon=2; Max-Age=60; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
      ]);

    expect(cookies.headerFor(Uri.parse('https://example.org/')), 'soon=2');

    now = now.add(const Duration(minutes: 2));
    expect(cookies.headerFor(Uri.parse('https://example.org/')), isNull);
  });

  test('a site can take back a cookie it set', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/'), ['a=1'])
      ..storeFromResponse(Uri.parse('https://example.org/'), ['a=; Max-Age=0']);

    expect(cookies.cookies, isEmpty);
  });

  test('a cookie set on a page path defaults to that directory', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/books/12'), ['a=1']);

    expect(cookies.headerFor(Uri.parse('https://example.org/books/13')), 'a=1');
    expect(cookies.headerFor(Uri.parse('https://example.org/other')), isNull);
  });

  test('a server cannot set cookies without end', () {
    final cookies = CookieJar(now: () => now, maxCookies: 3);
    for (var i = 0; i < 10; i++) {
      cookies.storeFromResponse(Uri.parse('https://example.org/'), ['c$i=$i']);
    }

    expect(cookies.cookies, hasLength(3));
    expect(
      cookies.headerFor(Uri.parse('https://example.org/')),
      'c7=7; c8=8; c9=9',
    );
  });

  test('nonsense is dropped rather than failing the request', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/'), [
        'no-equals-sign',
        '=novalue',
        'ok=1; Expires=not a date',
      ]);

    expect(cookies.cookies.map((c) => c.name), ['ok']);
    expect(cookies.headerFor(Uri.parse('https://example.org/')), 'ok=1');
  });

  test('signing out forgets everything', () {
    final cookies = jar()
      ..storeFromResponse(Uri.parse('https://example.org/'), ['a=1'])
      ..clear();

    expect(cookies.headerFor(Uri.parse('https://example.org/')), isNull);
  });
}
