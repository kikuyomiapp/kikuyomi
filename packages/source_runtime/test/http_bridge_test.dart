// The only way an extension reaches the network. The transport answers from this file rather than
// from a socket, because what is under test is the allowlist, the shapes and the error kinds, and
// because the allowlist refuses IP addresses and `localhost` on purpose — a source names domains.
// The transport itself is tested against a real server in packages/networking.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kikuyomi_networking/kikuyomi_networking.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A transport that answers each request from [answer], recording what it was asked.
final class StubTransport {
  StubTransport(this.answer);

  final http.Response Function(http.Request request) answer;
  final asked = <http.Request>[];

  http.Client get client => MockClient((request) async {
    asked.add(request);
    return answer(request);
  });
}

HttpBridge _bridge(StubTransport transport) => HttpBridge(
  client: SourceHttpClient.forTest(
    policy: const NetworkPolicy(
      userAgent: 'Kikuyomi/1.0 (test)',
      minimumInterval: Duration.zero,
    ),
    transport: transport.client,
  ),
  domains: testDomains,
);

http.Response _ok(String body, {Map<String, String> headers = const {}}) =>
    http.Response(body, 200, headers: headers);

/// The error a bridge answers with instead of throwing, so its kind survives the crossing.
Map<Object?, Object?> _error(Object? answer) =>
    (answer! as Map)[hostErrorMarker]! as Map;

void main() {
  test('fetches a page and gives back what the site said', () async {
    final transport = StubTransport((request) => _ok('<html>hi</html>'));
    final bridge = _bridge(transport);

    final response = await bridge.call('fetch', [
      {'url': 'https://example.org/book/12'},
    ]) as Map<Object?, Object?>;

    expect(response['status'], 200);
    expect(response['url'], 'https://example.org/book/12');
    expect(response['body'], '<html>hi</html>');
    expect(transport.asked.single.method, 'GET');
    expect(transport.asked.single.headers['user-agent'], 'Kikuyomi/1.0 (test)');
  });

  test('sends the method, headers and body the extension asked for', () async {
    final transport = StubTransport((request) => _ok('ok'));
    final bridge = _bridge(transport);

    await bridge.call('fetch', [
      {
        'url': 'https://example.org/search',
        'method': 'POST',
        'headers': {'X-Requested-With': 'XMLHttpRequest'},
        'body': 'q=whale',
      },
    ]);

    final sent = transport.asked.single;
    expect(sent.method, 'POST');
    expect(sent.body, 'q=whale');
    expect(sent.headers['x-requested-with'], 'XMLHttpRequest');
  });

  group('what comes back', () {
    test('json is parsed, and text is decoded as the site said', () async {
      final bridge = _bridge(
        StubTransport(
          (request) => _ok(
            '{"books":[{"key":"b1"}]}',
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      final response = await bridge.call('fetch', [
        {'url': 'https://example.org/api', 'responseType': 'json'},
      ]) as Map<Object?, Object?>;

      expect(response['body'], {
        'books': [
          {'key': 'b1'},
        ],
      });
    });

    test('bytes come back as bytes', () async {
      final bridge = _bridge(StubTransport((request) => _ok('abc')));

      final response = await bridge.call('fetch', [
        {'url': 'https://example.org/cover.jpg', 'responseType': 'bytes'},
      ]) as Map<Object?, Object?>;

      expect(response['body'], isA<Uint8List>());
      expect(utf8.decode(response['body']! as Uint8List), 'abc');
    });

    test('a page that is not JSON fails the call as Parse', () async {
      final bridge = _bridge(StubTransport((request) => _ok('<html>')));

      final answer = await bridge.call('fetch', [
        {'url': 'https://example.org/api', 'responseType': 'json'},
      ]);

      expect(_error(answer)['kind'], 'Parse');
      expect(_error(answer)['message'], contains('is not JSON'));
    });

    test('a responseType that does not exist is the extension\'s mistake', () {
      final bridge = _bridge(StubTransport((request) => _ok('x')));

      expect(
        () => bridge.call('fetch', [
          {'url': 'https://example.org/api', 'responseType': 'xml'},
        ]),
        throwsA(isA<HostCallException>()),
      );
    });

    test('any status is an answer, not a failure', () async {
      for (final status in [404, 429, 500]) {
        final bridge = _bridge(
          StubTransport((request) => http.Response('no', status)),
        );

        final response = await bridge.call('fetch', [
          {'url': 'https://example.org/gone'},
        ]) as Map<Object?, Object?>;

        expect(response['status'], status);
      }
    });
  });

  group('the extension\'s domains', () {
    test('a URL outside them is refused before anything is sent', () async {
      final transport = StubTransport((request) => _ok('x'));
      final bridge = _bridge(transport);

      final answer = await bridge.call('fetch', [
        {'url': 'https://tracker.example.net/pixel.gif'},
      ]);

      expect(_error(answer)['kind'], 'Parse');
      expect(transport.asked, isEmpty);
    });

    test('a wildcard domain is reached, its parent is not', () async {
      final transport = StubTransport((request) => _ok('x'));
      final bridge = _bridge(transport);

      await bridge.call('fetch', [
        {'url': 'https://files.cdn.example.org/a.mp3'},
      ]);
      final refused = await bridge.call('fetch', [
        {'url': 'https://cdn.example.org/a.mp3'},
      ]);

      expect(transport.asked, hasLength(1));
      expect(_error(refused)['kind'], 'Parse');
    });

    test('a redirect to a host it never named stops the request', () async {
      final transport = StubTransport(
        (request) => request.url.host == 'example.org'
            ? http.Response(
                '',
                302,
                headers: {'location': 'https://elsewhere.example.net/book'},
              )
            : _ok('should not be read'),
      );
      final bridge = _bridge(transport);

      expect(
        () => bridge.call('fetch', [
          {'url': 'https://example.org/book/12'},
        ]),
        throwsA(
          isA<HostCallException>().having(
            (e) => e.message,
            'message',
            contains('not among the extension\'s domains'),
          ),
        ),
      );
    });

    test('a redirect within them is followed', () async {
      final transport = StubTransport(
        (request) => request.url.path == '/book/12'
            ? http.Response(
                '',
                302,
                headers: {'location': 'https://files.cdn.example.org/12'},
              )
            : _ok('arrived'),
      );
      final bridge = _bridge(transport);

      final response = await bridge.call('fetch', [
        {'url': 'https://example.org/book/12'},
      ]) as Map<Object?, Object?>;

      expect(response['body'], 'arrived');
      expect(response['url'], 'https://files.cdn.example.org/12');
    });
  });

  group('when it goes wrong', () {
    test('a site that cannot be reached is a Network error', () async {
      final bridge = HttpBridge(
        client: SourceHttpClient.forTest(
          policy: const NetworkPolicy(
            userAgent: 'Kikuyomi/1.0 (test)',
            minimumInterval: Duration.zero,
          ),
          transport: MockClient((request) => throw const SocketishFailure()),
        ),
        domains: testDomains,
      );

      final answer = await bridge.call('fetch', [
        {'url': 'https://example.org/book/12'},
      ]);

      expect(_error(answer)['kind'], 'Network');
    });

    test('an answer larger than the cap fails the call as Parse', () async {
      final bridge = HttpBridge(
        client: SourceHttpClient.forTest(
          policy: const NetworkPolicy(
            userAgent: 'Kikuyomi/1.0 (test)',
            minimumInterval: Duration.zero,
            maxBodyBytes: 1024,
          ),
          transport: MockClient((request) async => _ok('x' * 4096)),
        ),
        domains: testDomains,
      );

      final answer = await bridge.call('fetch', [
        {'url': 'https://example.org/big'},
      ]);

      expect(_error(answer)['kind'], 'Parse');
      expect(_error(answer)['message'], contains('larger than'));
    });

    test('a request the contract refuses never leaves the app', () async {
      final transport = StubTransport((request) => _ok('x'));
      final bridge = _bridge(transport);

      // A header the client sets itself: letting an extension set it would let it smuggle a second
      // request into the first.
      final forbidden = await bridge.call('fetch', [
        {
          'url': 'https://example.org/x',
          'headers': {'Content-Length': '0'},
        },
      ]);
      // A body belongs only to a POST.
      final body = await bridge.call('fetch', [
        {'url': 'https://example.org/x', 'body': 'a=1'},
      ]);

      expect(_error(forbidden)['kind'], 'Parse');
      expect(_error(body)['kind'], 'Parse');
      expect(transport.asked, isEmpty);
    });

    test('a method that does not exist is the extension\'s mistake', () {
      final bridge = _bridge(StubTransport((request) => _ok('x')));

      expect(
        () => bridge.call('post', [
          {'url': 'https://example.org/x'},
        ]),
        throwsA(isA<HostCallException>()),
      );
      expect(
        () => bridge.call('fetch', ['https://example.org/x']),
        throwsA(isA<HostCallException>()),
      );
    });
  });

  test('cookies a site sets are sent back to it', () async {
    final transport = StubTransport(
      (request) => request.url.path == '/login'
          ? http.Response(
              'ok',
              200,
              headers: {'set-cookie': 'session=abc; Path=/'},
            )
          : _ok(request.headers['cookie'] ?? 'none'),
    );
    final bridge = _bridge(transport);

    await bridge.call('fetch', [
      {'url': 'https://example.org/login'},
    ]);
    final response = await bridge.call('fetch', [
      {'url': 'https://example.org/books'},
    ]) as Map<Object?, Object?>;

    expect(response['body'], 'session=abc');
  });
}

/// Stands in for a socket that would not open. `MockClient` has no way to fail a connection, so the
/// transport throws something of its own and the client treats it as it treats any other.
final class SocketishFailure implements Exception {
  const SocketishFailure();

  @override
  String toString() => 'connection refused';
}
