// What happens when a streamed file cannot be fetched.
//
// The bytes of a cached stream are fetched here and served to the player through a local proxy, so a
// failure reaches the player as its own platform's word for "the proxy gave me nothing" —
// AVFoundation says `-1008 resource unavailable`. The status the site really answered with is lost
// between the two unless this reports it, which is what these tests are about.
//
// Only the paths that do not need the real fetch are covered: the fetch itself lives inside
// just_audio's LockCachingAudioSource, which needs a player and a network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kikuyomi_streams');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  CachedAudioSource sourceThatFails({
    required Future<Never> Function() resolve,
    required void Function(Object error, Uri? uri) onFailure,
  }) => CachedAudioSource(
    fileId: 1,
    cache: StreamAudioCache(temp),
    resolve: resolve,
    onFailure: onFailure,
  );

  test('a file that cannot be resolved is reported, and still fails', () async {
    final reported = <Object>[];
    final source = sourceThatFails(
      resolve: () async => throw StateError('the source would not resolve it'),
      onFailure: (error, uri) => reported.add(error),
    );

    await expectLater(source.request(), throwsA(isA<StateError>()));

    expect(
      reported,
      hasLength(1),
      reason:
          'the reason has to be written down before it is passed on, '
          'because what reaches the player no longer carries it',
    );
    expect(reported.single, isA<StateError>());
  });

  test('a failure does not stick to the file (§6.3)', () async {
    // The coordinator retries once, and a listener may press play again after that. Each attempt has
    // to ask the source afresh rather than being handed the failure the first one got.
    var asked = 0;
    final source = sourceThatFails(
      resolve: () async {
        asked++;
        throw StateError('still not resolvable');
      },
      onFailure: (error, uri) {},
    );

    await expectLater(source.request(), throwsA(isA<StateError>()));
    await expectLater(source.request(), throwsA(isA<StateError>()));

    expect(asked, 2);
  });

  test('a source with nobody listening still fails the same way', () async {
    // onFailure is optional: the engine is built without one in tests and in any host that has no
    // console to write to.
    final source = CachedAudioSource(
      fileId: 1,
      cache: StreamAudioCache(temp),
      resolve: () async => throw StateError('no'),
    );

    await expectLater(source.request(), throwsA(isA<StateError>()));
  });
}
