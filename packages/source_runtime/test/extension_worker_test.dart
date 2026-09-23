// A runtime confined to an isolate of its own, with only plain data crossing (§3.6).
//
// The engine here is a fake built inside the worker, because what crosses to an isolate is a value:
// a factory of plain data, not a closure. That is exactly the constraint `ScriptEngineFactory`
// exists for, and a test that could not meet it would be testing the wrong thing.

import 'dart:async';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A bridge that answers from the isolate that started the worker, recording what crossed.
final class _MainIsolateBridge implements HostBridge {
  _MainIsolateBridge(this.module, this.answer);

  @override
  final String module;

  final Object? Function(String method, List<Object?> arguments) answer;
  final calls = <String>[];

  @override
  FutureOr<Object?> call(String method, List<Object?> arguments) {
    calls.add('$module.$method');
    return answer(method, arguments);
  }
}

Future<ExtensionWorker> _worker({
  Iterable<HostBridge> bridges = const [],
  String code = 'module.exports = {};',
}) => ExtensionWorker.start(
  engineFactory: const ScriptedEngineFactory(),
  bundle: testBundle(code: code),
  host: testHost,
  bridges: bridges,
);

void main() {
  test('loads an extension in an isolate and reads its sources', () async {
    final worker = await _worker();
    addTearDown(worker.dispose);

    expect(worker.extensionId, 'org.example.test');
    expect(worker.sourceKeys, ['scripted']);
    expect(await worker.hasMethod('scripted', 'echo'), isTrue);
    expect(await worker.hasMethod('scripted', 'nothing'), isFalse);
  });

  test('a call and its result cross as plain data', () async {
    final worker = await _worker();
    addTearDown(worker.dispose);

    final answer = await worker.invoke('scripted', 'echo', [
      'page',
      {'n': 2},
    ]);

    expect(answer, {
      'method': 'echo',
      'arguments': [
        'page',
        {'n': 2},
      ],
    });
  });

  test('an error keeps its kind and its fields across the isolate', () async {
    final worker = await _worker();
    addTearDown(worker.dispose);

    await expectLater(
      worker.invoke('scripted', 'rateLimited', const []),
      throwsA(
        isA<RateLimitedException>().having(
          (error) => error.retryAfterMs,
          'retryAfterMs',
          1500,
        ),
      ),
    );
    await expectLater(
      worker.invoke('scripted', 'challenge', const []),
      throwsA(
        isA<ChallengeRequiredException>().having(
          (error) => error.url.host,
          'host',
          'example.org',
        ),
      ),
    );
  });

  test('the watchdog inside the worker fails the call here', () async {
    final worker = await _worker();
    addTearDown(worker.dispose);

    await expectLater(
      worker.invoke('scripted', 'slow', const []),
      throwsA(
        isA<ParseException>().having(
          (error) => error.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
  });

  test('an extension that does not load fails to start', () async {
    expect(
      () => ExtensionWorker.start(
        engineFactory: const ScriptedEngineFactory(),
        bundle: testBundle(code: 'refuse to load'),
        host: testHost,
        bridges: const [],
      ),
      throwsA(isA<ExtensionLoadException>()),
    );
  });

  test('http, storage and log are answered by this isolate', () async {
    final http = _MainIsolateBridge(
      'http',
      (method, arguments) => {'status': 200, 'body': 'from the main isolate'},
    );
    final log = _MainIsolateBridge('log', (method, arguments) => null);
    final worker = await _worker(bridges: [http, log]);
    addTearDown(worker.dispose);

    final answer = await worker.invoke('scripted', 'fetch', [
      {'url': 'https://example.org/book/12'},
    ]);

    expect(answer, {'status': 200, 'body': 'from the main isolate'});
    expect(http.calls, ['http.fetch']);
    expect(proxiedHostModules, contains('storage'));
  });

  test('a bridge that fails reaches the extension as a failure', () async {
    final http = _MainIsolateBridge(
      'http',
      (method, arguments) => throw const HostCallException('nothing answered'),
    );
    final worker = await _worker(bridges: [http]);
    addTearDown(worker.dispose);

    await expectLater(
      worker.invoke('scripted', 'fetch', [
        {'url': 'https://example.org/book/12'},
      ]),
      throwsA(isA<ParseException>()),
    );
  });

  test('a module the worker does not proxy is not reachable', () async {
    final worker = await _worker();
    addTearDown(worker.dispose);

    await expectLater(
      worker.invoke('scripted', 'fetch', [
        {'url': 'https://example.org/book/12'},
      ]),
      throwsA(
        isA<ParseException>().having(
          (error) => error.message,
          'message',
          contains('there is no host module "http"'),
        ),
      ),
    );
  });

  test('nothing can be called after the worker is disposed', () async {
    final worker = await _worker();

    await worker.dispose();

    expect(
      () => worker.invoke('scripted', 'echo', const []),
      throwsA(isA<ParseException>()),
    );
    // Disposing twice is not a failure: a pool evicting a worker should not have to check.
    await worker.dispose();
  });

  test(
    'a source adapter over a worker decodes what crossed the isolate',
    () async {
      final worker = await _worker();
      addTearDown(worker.dispose);

      // The same adapter the in-isolate runtime uses: a worker is an ExtensionCalls, so the rules a
      // result is held to are written once and the confined path cannot drift from the other.
      final source = await JsSourceAdapter.open(
        runtime: worker,
        sourceKey: 'scripted',
      );
      final page = await source.getPopular(2);

      expect(source.capabilities, isEmpty);
      expect(page.items.single.key, 'b2');
      expect(
        page.items.single.coverUrl,
        Uri.parse('https://example.org/typee.jpg'),
      );
      expect(page.hasNextPage, isFalse);
    },
  );
}
