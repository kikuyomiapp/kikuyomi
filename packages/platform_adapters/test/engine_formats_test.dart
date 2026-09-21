import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';

/// The formats [formats] can play, in declared order, for comparing rows of the matrix.
List<AudioFormat> playable(PlayableFormats formats) => [
  for (final format in AudioFormat.values)
    if (formats.canPlay(format)) format,
];

void main() {
  test('ExoPlayer on Android plays FLAC, Ogg Vorbis and Ogg Opus', () {
    expect(playable(EngineFormats.on('android')), AudioFormat.values);
  });

  test('mpv on Windows and Linux plays FLAC, Ogg Vorbis and Ogg Opus', () {
    expect(playable(EngineFormats.on('windows')), AudioFormat.values);
    expect(playable(EngineFormats.on('linux')), AudioFormat.values);
  });

  test('AVFoundation on iOS and macOS plays FLAC but not Ogg', () {
    for (final system in ['ios', 'macos']) {
      expect(playable(EngineFormats.on(system)), [
        AudioFormat.mp3,
        AudioFormat.mp4,
        AudioFormat.flac,
      ], reason: system);
    }
  });

  test('a platform with no player is given only what every player plays', () {
    expect(playable(EngineFormats.on('fuchsia')), [
      AudioFormat.mp3,
      AudioFormat.mp4,
    ]);
  });

  test('this device is given its own platform\'s formats', () {
    expect(
      playable(EngineFormats.forThisDevice()),
      playable(EngineFormats.on(Platform.operatingSystem)),
    );
  });
}
