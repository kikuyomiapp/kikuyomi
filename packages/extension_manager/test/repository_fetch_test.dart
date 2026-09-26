// Reading a repository, against a server on this machine. Never the internet: a test that needs a
// site to be up is a test that fails for reasons that have nothing to do with the code.
//
// The behaviour worth holding onto is the caching one. A listener with a dozen repositories
// refreshes them all on the same schedule and almost nothing has changed, so an unchanged index has
// to cost a conditional request and no body — while `repo.json` is read every time regardless,
// because a key rotation is exactly what must not be missed behind a cached index (§3.8).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';
import 'package:kikuyomi_networking/kikuyomi_networking.dart';
import 'package:test/test.dart';

final aKey = base64Encode(List.filled(32, 7));

const aHash =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

String repoJson = jsonEncode({'name': 'Kikuyomi official', 'publicKey': aKey});

String indexJson({String id = 'org.example.librivox'}) => jsonEncode({
  'extensions': [
    {
      'id': id,
      'name': 'LibriVox',
      'version': '1.4.0',
      'versionCode': 14,
      'apiVersion': '1.0',
      'minAppVersion': '1.0.0',
      'contentRating': 'everyone',
      'domains': ['librivox.org'],
      'sources': [
        {'key': 'librivox', 'name': 'LibriVox', 'lang': 'en', 'versionId': 1},
      ],
      'package': {'url': 'https://example.org/a.zip', 'sha256': aHash},
      'signature': base64Encode(List.filled(64, 1)),
    },
  ],
});

const _policy = NetworkPolicy(
  userAgent: 'Kikuyomi/1.0 (test)',
  minimumInterval: Duration.zero,
  requestTimeout: Duration(seconds: 5),
  connectTimeout: Duration(seconds: 5),
);

/// What a request asked for, kept so a test can say what was sent rather than only what came back.
final class Asked {
  Asked(this.path, this.ifNoneMatch);

  final String path;
  final String? ifNoneMatch;
}

void main() {
  late HttpServer server;
  late RepositoryFetcher fetcher;
  late RepositoryLocation at;
  late List<Asked> asked;

  /// Answers each path however the test says.
  Future<void> serving(
    Map<String, FutureOr<void> Function(HttpResponse)> routes,
  ) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        asked.add(
          Asked(request.uri.path, request.headers.value('if-none-match')),
        );
        final route = routes[request.uri.path];
        if (route == null) {
          request.response.statusCode = 404;
        } else {
          await route(request.response);
        }
        await request.response.close();
      }),
    );
    at = RepositoryLocation(Uri.parse('http://127.0.0.1:${server.port}/'));
  }

  void write(HttpResponse response, String body, {String? etag}) {
    if (etag != null) response.headers.set('etag', etag);
    response.headers.contentType = ContentType.json;
    response.write(body);
  }

  setUp(() {
    asked = [];
    fetcher = RepositoryFetcher(
      NetworkService(policy: _policy).clientFor('org.kikuyomi.repositories'),
    );
  });

  tearDown(() => server.close(force: true));

  group('a repository that answers', () {
    setUp(
      () => serving({
        '/repo.json': (r) => write(r, repoJson),
        '/index.json': (r) => write(r, indexJson(), etag: '"v1"'),
      }),
    );

    test('gives who it is and what it offers', () async {
      final fetched = await fetcher.fetch(at);

      expect(fetched.info.name, 'Kikuyomi official');
      expect(fetched.info.publicKey, aKey);
      expect(fetched.index!.entries.single.id, 'org.example.librivox');
      expect(fetched.unchanged, isFalse);
    });

    test('keeps the tag to send back next time', () async {
      expect((await fetcher.fetch(at)).etag, '"v1"');
    });

    test('asks for both documents', () async {
      await fetcher.fetch(at);

      expect(
        [for (final one in asked) one.path],
        ['/repo.json', '/index.json'],
      );
    });

    test('sends no condition when it has nothing to compare against', () async {
      // An `If-None-Match` of nothing is a header some servers answer 304 to, which would leave the
      // app holding an index it never had.
      await fetcher.fetch(at);

      expect(asked.last.ifNoneMatch, isNull);
    });

    test('sends the tag back when it has one', () async {
      await fetcher.fetch(at, etag: '"v1"');

      expect(asked.last.ifNoneMatch, '"v1"');
    });
  });

  group('a repository that has not changed', () {
    setUp(
      () => serving({
        '/repo.json': (r) => write(r, repoJson),
        '/index.json': (r) => r.statusCode = 304,
      }),
    );

    test('says so rather than saying it is empty', () async {
      final fetched = await fetcher.fetch(at, etag: '"v1"');

      expect(fetched.unchanged, isTrue);
      expect(fetched.index, isNull);
      expect(
        fetched.etag,
        '"v1"',
        reason: 'the tag it was given is still the one to send',
      );
    });

    test('is still read for its signing key', () async {
      // §3.8: a key rotation is precisely what must not be missed because a cached index looked
      // unchanged.
      final fetched = await fetcher.fetch(at, etag: '"v1"');

      expect(fetched.info.publicKey, aKey);
      expect([for (final one in asked) one.path], contains('/repo.json'));
    });
  });

  group('a repository that is not one', () {
    test('has no repo.json, and is told so plainly', () async {
      await serving({'/index.json': (r) => write(r, indexJson())});

      await expectLater(
        fetcher.fetch(at),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            allOf(contains('repo.json'), contains('does not look like')),
          ),
        ),
      );
    });

    test('has no index.json', () async {
      await serving({'/repo.json': (r) => write(r, repoJson)});

      await expectLater(
        fetcher.fetch(at),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            contains('index.json'),
          ),
        ),
      );
    });

    test('answers something that is not an answer', () async {
      await serving({
        '/repo.json': (r) => write(r, repoJson),
        '/index.json': (r) => r.statusCode = 500,
      });

      await expectLater(
        fetcher.fetch(at),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            contains('500'),
          ),
        ),
      );
    });

    test('serves a page where the index should be', () async {
      // What a listener gets for pasting the GitHub page of something that is not a repository.
      await serving({
        '/repo.json': (r) => write(r, repoJson),
        '/index.json': (r) => r.write('<!doctype html><html>'),
      });

      await expectLater(fetcher.fetch(at), throwsA(isA<RepositoryException>()));
    });

    test('serves an index this build cannot read', () async {
      await serving({
        '/repo.json': (r) => write(r, repoJson),
        '/index.json': (r) =>
            write(r, jsonEncode({'formatVersion': 99, 'extensions': []})),
      });

      await expectLater(
        fetcher.fetch(at),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            contains('Update Kikuyomi'),
          ),
        ),
      );
    });
  });

  test(
    'a host that never answers is a repository problem, not a crash',
    () async {
      await serving({});
      final gone = RepositoryLocation(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      await server.close(force: true);
      // Bound again so the tearDown has something to close.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      await expectLater(
        fetcher.fetch(gone),
        throwsA(isA<RepositoryException>()),
      );
    },
  );
}
