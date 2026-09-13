// Spike (b) probe: playback on Windows. Throwaway.
//
// Question: does just_audio, via just_audio_media_kit, handle what an audiobook actually needs on
// Windows — a book made of several physical files, accurate seeking within and across them,
// playback speed, and a position stream good enough to store progress from?
//
// §6 puts the engine behind a PlaybackEngine interface and states that engine queue items are
// physical files, not chapters. The multi-file behaviour is therefore the part that matters; a
// single-file player would prove nothing.
//
// Test audio is generated here as plain PCM sine tones. Nothing is downloaded and no real
// audiobook is involved. Generating it also means every file's exact duration is known up front,
// which is what makes the duration and seek assertions meaningful.
//
// Volume is forced to zero: this runs unattended.
//
// Two API rules were learned the hard way and are encoded below, because the PlaybackEngine
// adapter will have to encode them too:
//
//   1. `position` is NOT settled synchronously after `await seek(...)`. The engine passes through
//      buffering first. Read it only after waiting for the state to come back to ready.
//   2. `await play()` does not mean "play to completion". Start it unawaited and wait on
//      processingState instead.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

const _sampleRate = 44100;

int _passed = 0;
int _failed = 0;

void _ok(String name, String detail) {
  _passed++;
  stdout.writeln('[PASS] $name :: $detail');
}

void _bad(String name, String detail) {
  _failed++;
  stdout.writeln('[FAIL] $name :: $detail');
}

void _near(String name, Duration? actual, Duration expected, int toleranceMs) {
  if (actual == null) {
    _bad(name, 'got null, expected ${expected.inMilliseconds}ms');
    return;
  }
  final delta = (actual.inMilliseconds - expected.inMilliseconds).abs();
  final detail = 'got ${actual.inMilliseconds}ms, expected ${expected.inMilliseconds}ms, '
      'delta ${delta}ms (tolerance ${toleranceMs}ms)';
  delta <= toleranceMs ? _ok(name, detail) : _bad(name, detail);
}

/// Polls until [test] passes or [limit] elapses. Returns whether it ended up true.
Future<bool> _until(bool Function() test, {Duration limit = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return test();
}

String _writeTone(Directory dir, String name, double seconds, double freq) {
  final frames = (seconds * _sampleRate).round();
  final dataBytes = frames * 2;
  final b = BytesBuilder();
  void ascii(String s) => b.add(s.codeUnits);
  void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(_sampleRate);
  u32(_sampleRate * 2);
  u16(2);
  u16(16);
  ascii('data');
  u32(dataBytes);

  final samples = Uint8List(dataBytes);
  final view = samples.buffer.asByteData();
  for (var i = 0; i < frames; i++) {
    final v = (math.sin(2 * math.pi * freq * i / _sampleRate) * 12000).round();
    view.setInt16(i * 2, v, Endian.little);
  }
  b.add(samples);

  final path = '${dir.path}${Platform.pathSeparator}$name';
  File(path).writeAsBytesSync(b.takeBytes());
  return path;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(windows: true);
  final dir = Directory.systemTemp.createTempSync('kk_resume');
  final a = _writeTone(dir, 'a.wav', 2.0, 220);
  final b = _writeTone(dir, 'b.wav', 3.0, 330);
  final c = _writeTone(dir, 'c.wav', 1.5, 440);
  final files = [a, b, c];

  Future<void> settle(AudioPlayer p) =>
      _until(() => p.processingState == ProcessingState.ready);

  stdout.writeln('Recipes for "resume at file index 1, offset 1500ms":');

  // A: single seek with index, while paused (what the probe originally did).
  {
    final p = AudioPlayer();
    await p.setAudioSources(files.map(AudioSource.file).toList());
    await p.setVolume(0);
    await p.seek(const Duration(milliseconds: 1500), index: 1);
    await settle(p);
    stdout.writeln('A  seek(1500ms, index:1) paused        -> idx=${p.currentIndex} '
        'pos=${p.position.inMilliseconds}ms');
    await p.dispose();
  }

  // B: two-step, index first then position.
  {
    final p = AudioPlayer();
    await p.setAudioSources(files.map(AudioSource.file).toList());
    await p.setVolume(0);
    await p.seek(Duration.zero, index: 1);
    await settle(p);
    await p.seek(const Duration(milliseconds: 1500));
    await settle(p);
    stdout.writeln('B  seek(0,index:1) then seek(1500ms)   -> idx=${p.currentIndex} '
        'pos=${p.position.inMilliseconds}ms');
    await p.dispose();
  }

  // C: initialIndex / initialPosition on load. This is the API meant for resume.
  {
    final p = AudioPlayer();
    await p.setAudioSources(files.map(AudioSource.file).toList(),
        initialIndex: 1, initialPosition: const Duration(milliseconds: 1500));
    await p.setVolume(0);
    await settle(p);
    stdout.writeln('C  setAudioSources(initialIndex/Pos)   -> idx=${p.currentIndex} '
        'pos=${p.position.inMilliseconds}ms');
    await p.dispose();
  }

  // D: seek while playing, then pause.
  {
    final p = AudioPlayer();
    await p.setAudioSources(files.map(AudioSource.file).toList());
    await p.setVolume(0);
    unawaited(p.play());
    await _until(() => p.position.inMilliseconds > 0, limit: const Duration(seconds: 3));
    await p.seek(const Duration(milliseconds: 1500), index: 1);
    await settle(p);
    await p.pause();
    stdout.writeln('D  play, then seek(1500ms, index:1)    -> idx=${p.currentIndex} '
        'pos=${p.position.inMilliseconds}ms');
    await p.dispose();
  }

  // E: does position survive a pause mid-file? Progress is saved on pause.
  {
    final p = AudioPlayer();
    await p.setAudioSource(AudioSource.file(b));
    await p.setVolume(0);
    unawaited(p.play());
    await _until(() => p.position.inMilliseconds > 800, limit: const Duration(seconds: 5));
    await p.pause();
    final atPause = p.position.inMilliseconds;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    stdout.writeln('E  pause mid-file                      -> at pause ${atPause}ms, '
        '300ms later ${p.position.inMilliseconds}ms');
    await p.dispose();
  }

  try { dir.deleteSync(recursive: true); } catch (_) {}
  await stdout.flush();
  exit(0);
}
