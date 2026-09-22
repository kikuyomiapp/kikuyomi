// Resolving a chapter's audio, and the requests that fetch it. These URLs reach the download engine
// and the player, and these headers go on the wire, so this is where the domain rule and the header
// rules are enforced.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('a resolution', () {
    test('reads every field of a segment', () {
      final expires = DateTime.utc(2026, 3, 14, 9, 30);
      final media = decoder.decodeMediaResolution(
        resolution(
          segments: [
            segment(
              and: {
                'format': 'm4b',
                'range': {'startMs': 60000, 'endMs': 930000},
                'durationMs': 87000000,
                'sizeBytes': 734003200,
                'variants': [
                  {
                    'label': '64 kbps',
                    'bitrateKbps': 64,
                    'request': request(
                      url: 'https://a.cdn.example.org/64/a.mp3',
                    ),
                  },
                ],
              },
            ),
          ],
          and: {'expiresAt': expires.millisecondsSinceEpoch},
        ),
      );

      expect(media.expiresAt, expires);
      final part = media.segments.single;
      expect(part.fileKey, 'f1');
      expect(part.request.url, Uri.parse('https://example.org/a.mp3'));
      expect(part.request.method, HttpMethod.get);
      expect(part.format, MediaFormat.m4b);
      expect(part.range, const MediaRange(startMs: 60000, endMs: 930000));
      expect(part.durationMs, 87000000);
      expect(part.sizeBytes, 734003200);
      expect(part.variants.single.label, '64 kbps');
      expect(part.variants.single.bitrateKbps, 64);
      expect(part.variants.single.request.url.host, 'a.cdn.example.org');
    });

    test('reads a whole-file segment as one with no range', () {
      final media = decoder.decodeMediaResolution(resolution());
      expect(media.segments.single.range, isNull);
      expect(media.segments.single.format, MediaFormat.unknown);
      expect(media.segments.single.variants, isEmpty);
      expect(media.expiresAt, isNull);
    });

    test('lets chapters of one M4B share a file key with different ranges', () {
      final media = decoder.decodeMediaResolution(
        resolution(
          segments: [
            segment(
              and: {
                'range': {'startMs': 0, 'endMs': 60000},
              },
            ),
            segment(
              and: {
                'range': {'startMs': 60000},
              },
            ),
          ],
        ),
      );
      expect([for (final part in media.segments) part.fileKey], ['f1', 'f1']);
      expect(media.segments.last.range, const MediaRange(startMs: 60000));
    });

    test('needs at least one segment', () {
      expect(
        () => decoder.decodeMediaResolution(resolution(segments: [])),
        rejects('segments', 'at least one segment'),
      );
      expect(
        () => decoder.decodeMediaResolution(<String, Object?>{}),
        rejects('segments', 'missing'),
      );
    });

    test('holds 2,000 segments, and refuses 2,001', () {
      List<Object?> segments(int count) => [
        for (var i = 0; i < count; i++) segment(),
      ];
      expect(
        decoder
            .decodeMediaResolution(resolution(segments: segments(2000)))
            .segments,
        hasLength(2000),
      );
      expect(
        () =>
            decoder.decodeMediaResolution(resolution(segments: segments(2001))),
        rejects('segments', 'at most 2,000'),
      );
    });

    test('holds 10 variants of a segment, and refuses 11', () {
      List<Object?> variants(int count) => [
        for (var i = 0; i < count; i++) {'label': 'v$i', 'request': request()},
      ];
      expect(
        decoder
            .decodeMediaResolution(
              resolution(
                segments: [
                  segment(and: {'variants': variants(10)}),
                ],
              ),
            )
            .segments
            .single
            .variants,
        hasLength(10),
      );
      expect(
        () => decoder.decodeMediaResolution(
          resolution(
            segments: [
              segment(and: {'variants': variants(11)}),
            ],
          ),
        ),
        rejects('segments[0].variants', 'at most 10'),
      );
    });

    test('reads a format this app does not know, or none, as unknown', () {
      for (final format in [null, 'wav', 'MP3', 'unknown']) {
        expect(
          decoder
              .decodeMediaResolution(
                resolution(
                  segments: [
                    segment(and: {'format': format}),
                  ],
                ),
              )
              .segments
              .single
              .format,
          MediaFormat.unknown,
          reason: '$format',
        );
      }
      expect(
        decoder
            .decodeMediaResolution(
              resolution(
                segments: [
                  segment(and: {'format': 'ogg'}),
                ],
              ),
            )
            .segments
            .single
            .format,
        MediaFormat.ogg,
      );
    });

    test('refuses a range that ends where it starts or before it', () {
      for (final range in [
        {'startMs': 60000, 'endMs': 60000},
        {'startMs': 60000, 'endMs': 59000},
      ]) {
        expect(
          () => decoder.decodeMediaResolution(
            resolution(
              segments: [
                segment(and: {'range': range}),
              ],
            ),
          ),
          rejects('segments[0].range.endMs', 'not after startMs'),
          reason: '$range',
        );
      }
    });

    test('refuses a range with no start, or a negative one', () {
      expect(
        () => decoder.decodeMediaResolution(
          resolution(
            segments: [
              segment(
                and: {
                  'range': {'endMs': 60000},
                },
              ),
            ],
          ),
        ),
        rejects('segments[0].range.startMs', 'missing'),
      );
      expect(
        () => decoder.decodeMediaResolution(
          resolution(
            segments: [
              segment(
                and: {
                  'range': {'startMs': -1},
                },
              ),
            ],
          ),
        ),
        rejects('segments[0].range.startMs', 'negative'),
      );
    });

    test('refuses a segment without a file key or a request', () {
      expect(
        () => decoder.decodeMediaResolution(
          resolution(
            segments: [
              {'request': request()},
            ],
          ),
        ),
        rejects('segments[0].fileKey', 'missing'),
      );
      expect(
        () => decoder.decodeMediaResolution(
          resolution(
            segments: [
              {'fileKey': 'f1'},
            ],
          ),
        ),
        rejects('segments[0].request', 'expected an object, got nothing'),
      );
    });

    test('refuses a variant without a label or a request', () {
      expect(
        () => decoder.decodeMediaResolution(
          resolution(
            segments: [
              segment(
                and: {
                  'variants': [
                    {'request': request()},
                  ],
                },
              ),
            ],
          ),
        ),
        rejects('segments[0].variants[0].label', 'missing'),
      );
    });
  });

  group('a request', () {
    HttpRequest read(Map<String, Object?> data) =>
        decoder.decodeHttpRequest(data);

    test('is a GET without a method', () {
      final fetched = read(request());
      expect(fetched.method, HttpMethod.get);
      expect(fetched.headers, isEmpty);
      expect(fetched.body, isNull);
    });

    test('reads a POST with headers and a body', () {
      final fetched = read(
        request(
          url: 'https://example.org/search',
          and: {
            'method': 'POST',
            'headers': {'Referer': 'https://example.org/', 'X-Token': 'abc'},
            'body': 'q=whales&page=1',
          },
        ),
      );
      expect(fetched.method, HttpMethod.post);
      expect(fetched.headers, {
        'Referer': 'https://example.org/',
        'X-Token': 'abc',
      });
      expect(fetched.body, 'q=whales&page=1');
    });

    test('keeps a body exactly as it was written', () {
      final fetched = read(
        request(and: {'method': 'POST', 'body': '  a\nb  '}),
      );
      expect(fetched.body, '  a\nb  ');
    });

    test('refuses a method the contract does not have', () {
      for (final method in ['PUT', 'get', 'DELETE', 7]) {
        expect(
          () => read(request(and: {'method': method})),
          rejects('method'),
          reason: '$method',
        );
      }
    });

    test('refuses a body on a GET, which no client would send', () {
      expect(
        () => read(request(and: {'body': 'q=whales'})),
        rejects('body', 'only a POST'),
      );
    });

    test('refuses a URL off the extension\'s domains, wherever it sits', () {
      expect(
        () => read(request(url: 'https://evil.com/a.mp3')),
        rejects('url', 'not among'),
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
                      'request': request(url: 'https://evil.com/64.mp3'),
                    },
                  ],
                },
              ),
            ],
          ),
        ),
        rejects('segments[0].variants[0].request.url', 'not among'),
      );
    });

    group('headers', () {
      Map<String, String> read(Map<Object?, Object?> headers) =>
          decoder.decodeHttpRequest(request(and: {'headers': headers})).headers;

      test('hold a name of 256 characters and a value of 8,192, and refuse one more of either', () {
        expect(read({text(256): 'x'}), hasLength(1));
        expect(read({'X-Token': text(8192)}), hasLength(1));
        expect(
          () => read({text(257): 'x'}),
          rejects('headers["${text(40)}…"]', 'header name of 1 to 256'),
        );
        expect(
          () => read({'X-Token': text(8193)}),
          rejects('headers["X-Token"]', 'longer than 8,192'),
        );
      });

      test('refuse the names the app sets itself', () {
        for (final name in [
          'Host',
          'host',
          'Content-Length',
          'Connection',
          'Transfer-Encoding',
          'TRANSFER-ENCODING',
        ]) {
          expect(
            () => read({name: 'x'}),
            rejects('headers["$name"]', 'set by the app itself'),
            reason: name,
          );
        }
      });

      test('refuse a name that is not a header name', () {
        for (final name in [
          'X Token',
          'X:Token',
          'Réferer',
          '',
          'X-Token\n',
          ':authority',
        ]) {
          expect(
            () => read({name: 'x'}),
            throwsA(isA<ParseException>()),
            reason: name,
          );
        }
      });

      test('refuse a value carrying a line break, which would smuggle a second header', () {
        expect(
          () => read({'X-Token': 'abc\r\nX-Admin: true'}),
          rejects('headers["X-Token"]', 'control character'),
        );
        expect(
          () => read({'X-Token': 'a\u0000b'}),
          rejects('headers["X-Token"]'),
        );
      });

      test('allow a tab in a value, which HTTP does', () {
        expect(read({'X-Token': 'a\tb'}), {'X-Token': 'a\tb'});
      });

      test('refuse two names that differ only in case', () {
        expect(
          () => read({
            'Referer': 'https://example.org/',
            'referer': 'https://example.org/x',
          }),
          rejects('headers["referer"]', 'differs from it only in case'),
        );
      });

      test('refuse a name or a value that is not a string', () {
        expect(
          () => read({'X-Token': 7}),
          rejects('headers["X-Token"]', 'not a string'),
        );
        expect(() => read({7: 'x'}), rejects('headers', 'not a string'));
      });
    });
  });
}
