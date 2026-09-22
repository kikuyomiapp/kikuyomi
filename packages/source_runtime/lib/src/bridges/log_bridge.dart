/// `log`: an extension's own messages, into the in-app extension console (§3.5).
///
/// "Leveled logging into an in-app extension console. Rate-limited." The console is for the person
/// writing the extension and for the listener reporting that a source stopped working, so a message
/// is kept as the extension wrote it — cut to length and stripped of control characters, never
/// reworded — and never shown as the app's own voice.
///
/// The rate limit is what makes a log safe to leave switched on: an extension logging inside a loop
/// would otherwise fill memory and drown everything else in the console. Over the limit, messages
/// are dropped and one line says how many.
library;

import 'dart:async';

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import 'host_bridge.dart';

/// How loud a message is, as SourceAPI 1.0's `log` names them.
enum ExtensionLogLevel { debug, info, warn, error }

/// One line in the extension console.
final class ExtensionLogMessage {
  const ExtensionLogMessage({
    required this.extensionId,
    required this.level,
    required this.text,
    required this.at,
  });

  /// Which extension wrote it: the console shows several at once.
  final String extensionId;
  final ExtensionLogLevel level;
  final String text;
  final DateTime at;

  @override
  String toString() => '[${level.name}] $extensionId: $text';
}

/// Where the console keeps what extensions write. The app implements it.
///
/// An interface rather than a buffer here, because where the lines are kept, how many are kept and
/// whether they are also written to a file are the app's decisions, and a test wants neither.
abstract interface class ExtensionLogSink {
  void write(ExtensionLogMessage message);
}

/// A sink that keeps the last [limit] messages in memory, for tests and for a console with no
/// storage behind it yet.
final class InMemoryExtensionLog implements ExtensionLogSink {
  InMemoryExtensionLog({this.limit = 500});

  final int limit;
  final _messages = <ExtensionLogMessage>[];

  List<ExtensionLogMessage> get messages => List.unmodifiable(_messages);

  @override
  void write(ExtensionLogMessage message) {
    _messages.add(message);
    if (_messages.length > limit) _messages.removeAt(0);
  }
}

/// The `log` module of one extension's host API.
final class LogBridge implements HostBridge {
  LogBridge({
    required this.extensionId,
    required this.sink,
    this.maxPerWindow = 100,
    this.window = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The extension whose messages these are.
  final String extensionId;

  final ExtensionLogSink sink;

  /// How many messages one extension may write in a [window] before the rest are dropped.
  final int maxPerWindow;

  /// The stretch the limit is counted over.
  final Duration window;

  final DateTime Function() _now;

  DateTime? _windowStarted;
  var _written = 0;
  var _dropped = 0;

  @override
  String get module => 'log';

  @override
  FutureOr<Object?> call(String method, List<Object?> arguments) {
    final level = switch (method) {
      'debug' => ExtensionLogLevel.debug,
      'info' => ExtensionLogLevel.info,
      'warn' => ExtensionLogLevel.warn,
      'error' => ExtensionLogLevel.error,
      _ => throw HostCallException('there is no log.$method'),
    };
    _add(level, _readable(arguments.stringAt(0, 'a message')));
    // Nothing to give back: the prelude's log shims return nothing, so a script never waits on a
    // line of its own log.
    return null;
  }

  void _add(ExtensionLogLevel level, String text) {
    final at = _now();
    final started = _windowStarted;
    if (started == null || at.difference(started) >= window) {
      _closeWindow(at);
      _windowStarted = at;
    }
    if (_written >= maxPerWindow) {
      _dropped++;
      return;
    }
    _written++;
    sink.write(
      ExtensionLogMessage(
        extensionId: extensionId,
        level: level,
        text: text,
        at: at,
      ),
    );
  }

  /// Says how much was lost, so that silence in the console is never mistaken for quiet.
  void _closeWindow(DateTime at) {
    if (_dropped > 0) {
      sink.write(
        ExtensionLogMessage(
          extensionId: extensionId,
          level: ExtensionLogLevel.warn,
          text:
              '$_dropped more messages were dropped: this extension logs more than '
              '$maxPerWindow lines every ${window.inSeconds} s',
          at: at,
        ),
      );
    }
    _written = 0;
    _dropped = 0;
  }

  /// The extension's own words, made safe to show and short enough to keep.
  ///
  /// The same treatment an error's message gets in the contract: control characters replaced, cut
  /// to a thousand characters. A log line is never refused over its contents — a message that is
  /// hard to read still says more than no message.
  static String _readable(String message) {
    final cut = message.length > SourceLimits.maxShortTextLength;
    final kept = cut
        ? message.substring(0, SourceLimits.maxShortTextLength)
        : message;
    final buffer = StringBuffer();
    for (var i = 0; i < kept.length; i++) {
      final unit = kept.codeUnitAt(i);
      buffer.write(unit < 0x20 || unit == 0x7f ? ' ' : kept[i]);
    }
    final text = buffer.toString().trim();
    return cut && text.isNotEmpty ? '$text…' : text;
  }
}
