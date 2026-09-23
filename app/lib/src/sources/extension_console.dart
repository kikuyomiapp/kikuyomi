/// The in-app extension console (§3.5, §3.11).
///
/// "Leveled logging into an in-app extension console" is what the `log` bridge writes to, and §3.11
/// counts an extension log console as part of what an author needs. Until now the app collected the
/// lines and showed them nowhere, which left an author debugging blind.
///
/// Two kinds of line end up here, deliberately in one place:
///
/// - what an extension wrote itself, through `log`, kept exactly as it wrote it;
/// - what went wrong *around* an extension — a manifest that would not read, a package whose files did
///   not match it, a runtime that would not start — written by the app, in the app's own voice.
///
/// The second kind is why an Extensions screen can show "what this extension produced" at all: a
/// failure before any code ran never reaches a `log` call. The two are told apart by
/// [ExtensionLogLine.fromTheApp], so the console never shows the app's words as an extension's.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

/// One line in the console.
@immutable
final class ExtensionLogLine {
  const ExtensionLogLine({
    required this.extensionId,
    required this.level,
    required this.text,
    required this.at,
    this.fromTheApp = false,
  });

  /// Which extension it is about. The console shows several at once, and the Extensions screen shows
  /// one.
  final String extensionId;

  final ExtensionLogLevel level;

  /// The message. An extension's own words, or the app's about it — never the one presented as the
  /// other.
  final String text;

  final DateTime at;

  /// Whether the app wrote this rather than the extension.
  final bool fromTheApp;
}

/// Where extensions' messages are kept while the app runs, and what the console screen watches.
///
/// In memory, bounded, and lost when the app closes, which is what a debugging aid should be: §4.3
/// gives the database the listener's data, and an extension logging in a loop must never be able to
/// grow a file on the device. The rate limit that makes that safe is in the `log` bridge; this only
/// forgets the oldest line once it is full.
final class ExtensionConsole implements ExtensionLogSink {
  ExtensionConsole({this.limit = 500, Clock? clock})
    : _clock = clock ?? const SystemClock();

  /// How many lines are kept. The oldest goes when a new one arrives.
  final int limit;

  final Clock _clock;
  final _lines = <ExtensionLogLine>[];
  final _changes = StreamController<void>.broadcast();

  /// Every line kept, oldest first.
  List<ExtensionLogLine> get lines => List.unmodifiable(_lines);

  /// The lines about one extension, oldest first.
  List<ExtensionLogLine> linesOf(String extensionId) => [
    for (final line in _lines)
      if (line.extensionId == extensionId) line,
  ];

  /// How many of the lines about [extensionId] are failures, which is what the Extensions screen
  /// counts to say that an extension has problems.
  int problemsOf(String extensionId) =>
      linesOf(extensionId)
          .where((line) => line.level == ExtensionLogLevel.error)
          .length;

  /// Every extension the console has a line about, whether or not it is still installed.
  Set<String> get extensionIds => {for (final line in _lines) line.extensionId};

  /// A signal after every line, so a screen showing the console follows it.
  Stream<void> get changes => _changes.stream;

  @override
  void write(ExtensionLogMessage message) => _add(
    ExtensionLogLine(
      extensionId: message.extensionId,
      level: message.level,
      text: message.text,
      at: message.at,
    ),
  );

  /// Records something the app has to say about [extensionId]: a package that would not read, a
  /// runtime that would not start.
  ///
  /// [error] is written as it describes itself. The exceptions this is given — a manifest's, a
  /// package's, a load's — all say which field or file was wrong, and that sentence is the whole
  /// value of the line.
  void report(
    String extensionId,
    Object error, {
    ExtensionLogLevel level = ExtensionLogLevel.error,
  }) => _add(
    ExtensionLogLine(
      extensionId: extensionId,
      level: level,
      text: '$error',
      at: _clock.now(),
      fromTheApp: true,
    ),
  );

  /// Records something the app did, for an author watching the console: an install, a removal, a
  /// reload.
  void note(String extensionId, String text) => _add(
    ExtensionLogLine(
      extensionId: extensionId,
      level: ExtensionLogLevel.info,
      text: text,
      at: _clock.now(),
      fromTheApp: true,
    ),
  );

  /// Throws every line away.
  void clear() {
    if (_lines.isEmpty) return;
    _lines.clear();
    _changes.add(null);
  }

  void _add(ExtensionLogLine line) {
    _lines.add(line);
    if (_lines.length > limit) _lines.removeRange(0, _lines.length - limit);
    _changes.add(null);
  }

  /// Ends the change signal. The app keeps one console for as long as it runs, so this is for tests.
  Future<void> dispose() => _changes.close();
}
