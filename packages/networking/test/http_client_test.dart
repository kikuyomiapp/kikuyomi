// The app's transport, against a server on this machine. Never the internet: a test that needs a
// site to be up is a test that fails for reasons that have nothing to do with the code.

import 'dart:async';
import 'dart:io';

import 'package:kikuyomi_networking/kikuyomi_networking.dart';
import 'package:test/test.dart';

/// A server for one test, answering however the test says.
final class TestServer {
  TestServer._(this._server);

  static Future<TestServer> start(
    FutureOr<void> Function(HttpRequest request) answer,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final test = TestServer._(server);
    unawaited(
      server.forEach((request) async {
        test.received.add(request);
        await answer(request);
        await request.response.close();
      }),
    );
    return test;
  }

  final HttpServer _server;

  /// Every request the server was given, for asserting what was sent.
  final received = <HttpRequest>[];

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> stop() => _server.close(force: true);
}

const _policy = NetworkPolicy(
  userAgent: 'Kikuyomi/1.0 (test)',
  minimumInterval: Duration.zero,
  requestTimeout: Duration(seconds: 5),
  connectTimeout: Duration(seconds: 5),
);

NetworkService _service([NetworkPolicy policy = _policy]) =>
    NetworkService(policy: policy);

void main() {
  test('gives back any status the site answers with', () async {
    final server = await TestServer.start((request) {
      request.response.statusCode = 404;
      request.response.write('gone');
    });
    addTearDown(server.stop);
    final client = _service().clientFor('org.example.a');

    final response = await client.send(NetworkRequest(url: server.url('/x')));

    expect(response.status, 404);
    expect(String.fromCharCodes(response.body), 'gone');
  });

  test('sends the app\'s User-Agent, whatever the caller asks for', () async {
    final server = await TestServer.start((request) {
      request.response.write('ok');
    });
    addTearDown(server.stop);
    final client = _service().clientFor('org.example.a');

    await client.send(
      NetworkRequest(
        url: server.url('/x'),
        headers: const {
          'user-agent': 'Definitely A Browser',
          'accept': 'text/html',
        },
      ),
    );

    expect(
      server.received.single.headers.value('user-agent'),
      'Kikuyomi/1.0 (test)',
    );
    expect(server.received.single.headers.value('accept'), 'text/html');
  });

  test('sends a POST body, and reads what came back', () async {
    final server = await TestServer.start((request) async {
      final body = await request
          .cast<List<int>>()
          .transform(SystemEncoding().decoder)
          .join();
      request.response.write('saw: $body');
    });
    addTearDown(server.stop);
    final client = _service().clientFor('org.example.a');

    final response = await client.send(
      NetworkRequest(
        url: server.url('/search'),
        method: HttpMethod.post,
        body: 'q=whale',
      ),
    );

    expect(String.fromCharCodes(response.body), 'saw: q=whale');
    expect(server.received.single.method, 'POST');
  });

  group('cookies', () {
    test('are kept per extension and sent back to the site', () async {
      final server = await TestServer.start((request) {
        if (request.uri.path == '/login') {
          request.response.headers.add('set-cookie', 'session=abc; Path=/');
        }
        request.response.write(request.headers.value('cookie') ?? 'none');
      });
      addTearDown(server.stop);
      final service = _service();
      final mine = service.clientFor('org.example.a');
      final theirs = service.clientFor('org.example.b');

      await mine.send(NetworkRequest(url: server.url('/login')));
      final asMe = await mine.send(NetworkRequest(url: server.url('/books')));
      final asThem = await theirs.send(
        NetworkRequest(url: server.url('/books')),
      );

      expect(String.fromCharCodes(asMe.body), 'session=abc');
      // One extension's session is not another's: that is what per-extension jars are for.
      expect(String.fromCharCodes(asThem.body), 'none');
    });

    test('are forgotten when the extension is', () async {
      final server = await TestServer.start((request) {
        request.response.headers.add('set-cookie', 'session=abc; Path=/');
        request.response.write(request.headers.value('cookie') ?? 'none');
      });
      addTearDown(server.stop);
      final service = _service();

      await service
          .clientFor('org.example.a')
          .send(NetworkRequest(url: server.url('/login')));
      service.forget('org.example.a');
      final after = await service
          .clientFor('org.example.a')
          .send(NetworkRequest(url: server.url('/books')));

      expect(String.fromCharCodes(after.body), 'none');
    });
  });

  group('redirects', () {
    test('are followed, and every hop is offered to the check', () async {
      final server = await TestServer.start((request) {
        if (request.uri.path == '/first') {
          request.response.statusCode = 302;
          request.response.headers.add('location', '/second');
        } else {
          request.response.write('arrived');
        }
      });
      addTearDown(server.stop);
      final client = _service().clientFor('org.example.a');
      final checked = <Uri>[];

      final response = await client.send(
        NetworkRequest(url: server.url('/first')),
        check: checked.add,
      );

      expect(String.fromCharCodes(response.body), 'arrived');
      expect(response.url.path, '/second');
      expect(checked.map((url) => url.path), ['/first', '/second']);
    });

    test('a hop the check refuses stops the request there', () async {
      final server = await TestServer.start((request) {
        if (request.uri.path == '/first') {
          request.response.statusCode = 302;
          request.response.headers.add('location', '/elsewhere');
        } else {
          request.response.write('should not be read');
        }
      });
      addTearDown(server.stop);
      final client = _service().clientFor('org.example.a');

      expect(
        () => client.send(
          NetworkRequest(url: server.url('/first')),
          check: (url) {
            if (url.path != '/first') throw StateError('not allowed: $url');
          },
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a POST becomes a GET on a 302, and stays a POST on a 307', () async {
      final server = await TestServer.start((request) {
        if (request.uri.path == '/see-other') {
          request.response.statusCode = 302;
          request.response.headers.add('location', '/landed');
        } else if (request.uri.path == '/keep') {
          request.response.statusCode = 307;
          request.response.headers.add('location', '/landed');
        } else {
          request.response.write(request.method);
        }
      });
      addTearDown(server.stop);
      final client = _service().clientFor('org.example.a');

      final seeOther = await client.send(
        NetworkRequest(
          url: server.url('/see-other'),
          method: HttpMethod.post,
          body: 'a=1',
        ),
      );
      final kept = await client.send(
        NetworkRequest(
          url: server.url('/keep'),
          method: HttpMethod.post,
          body: 'a=1',
        ),
      );

      expect(String.fromCharCodes(seeOther.body), 'GET');
      expect(String.fromCharCodes(kept.body), 'POST');
    });

    test('a site that redirects for ever is stopped', () async {
      final server = await TestServer.start((request) {
        request.response.statusCode = 302;
        request.response.headers.add('location', '/again');
      });
      addTearDown(server.stop);
      final client = _service(
        const NetworkPolicy(
          userAgent: 'Kikuyomi/1.0 (test)',
          minimumInterval: Duration.zero,
          maxRedirects: 2,
        ),
      ).clientFor('org.example.a');

      expect(
        () => client.send(NetworkRequest(url: server.url('/loop'))),
        throwsA(isA<NetworkLimitReached>()),
      );
    });
  });

  group('limits', () {
    test('a body larger than the cap is refused', () async {
      final server = await TestServer.start((request) {
        request.response.add(List.filled(200 * 1024, 65));
      });
      addTearDown(server.stop);
      final client = _service(
        const NetworkPolicy(
          userAgent: 'Kikuyomi/1.0 (test)',
          minimumInterval: Duration.zero,
          maxBodyBytes: 64 * 1024,
        ),
      ).clientFor('org.example.a');

      expect(
        () => client.send(NetworkRequest(url: server.url('/big'))),
        throwsA(
          isA<NetworkLimitReached>().having(
            (e) => e.message,
            'message',
            contains('larger than'),
          ),
        ),
      );
    });

    test('a site that never answers is a failure, not a hang', () async {
      final server = await TestServer.start((request) async {
        await Future<void>.delayed(const Duration(seconds: 10));
      });
      addTearDown(server.stop);
      final client = _service(
        const NetworkPolicy(
          userAgent: 'Kikuyomi/1.0 (test)',
          minimumInterval: Duration.zero,
          connectTimeout: Duration(milliseconds: 300),
          requestTimeout: Duration(milliseconds: 500),
        ),
      ).clientFor('org.example.a');

      expect(
        () => client.send(NetworkRequest(url: server.url('/slow'))),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('a site that cannot be reached at all is a Network failure', () async {
      final server = await TestServer.start((request) {});
      final url = server.url('/x');
      await server.stop();
      final client = _service().clientFor('org.example.a');

      expect(
        () => client.send(NetworkRequest(url: url)),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test(
      'requests to one host are spaced out once the burst is spent',
      () async {
        final server = await TestServer.start((request) {
          request.response.write('ok');
        });
        addTearDown(server.stop);
        final client = _service(
          const NetworkPolicy(
            userAgent: 'Kikuyomi/1.0 (test)',
            minimumInterval: Duration(milliseconds: 200),
            burstPerHost: 2,
          ),
        ).clientFor('org.example.a');

        // One stopwatch across all four, because the limiter paces from the first request and not
        // from whenever a later one was asked for: timing the last two on their own would measure
        // 400 ms less however long the first two took, which is the server's speed, not the
        // limiter's.
        final watch = Stopwatch()..start();

        // The burst goes straight out; only what follows it waits.
        await client.send(NetworkRequest(url: server.url('/1')));
        await client.send(NetworkRequest(url: server.url('/2')));
        expect(watch.elapsedMilliseconds, lessThan(200));

        await client.send(NetworkRequest(url: server.url('/3')));
        await client.send(NetworkRequest(url: server.url('/4')));
        watch.stop();

        // A burst of two, then the sustained rate: the third request starts one interval after the
        // first and the fourth two, so the fourth cannot have started before 400 ms had passed. A
        // few milliseconds of slack, because the limiter schedules on DateTime.now() and waits on a
        // timer while this measures with a Stopwatch, and the three need not agree exactly.
        expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(395));
      },
    );
  });
}
