import 'dart:async';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// A clock that moves only when a test tells it to, and fires the timers started against it as it
/// moves.
final class FakeClock implements Clock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026);

  DateTime _now;

  final _timers = <_FakeTimer>[];

  @override
  DateTime now() => _now;

  /// Starts a timer that fires once [advance] has moved time [duration] on from now, as `Timer.new`
  /// does in real time. For code that takes a way to start timers, so that it can be given this.
  Timer startTimer(Duration duration, void Function() callback) {
    final timer = _FakeTimer(
      this,
      _now.add(duration.isNegative ? Duration.zero : duration),
      callback,
    );
    _timers.add(timer);
    return timer;
  }

  /// How many timers are waiting to fire.
  int get pendingTimers => _timers.length;

  /// Moves time forward, firing each timer whose time comes, in the order they come, with the clock
  /// showing that timer's time while it runs. Timers started by those that fire are fired too, if
  /// their time comes before the end.
  ///
  /// Time never moves backwards here; code that must survive a device clock being set back should be
  /// tested by constructing a new clock instead.
  void advance(Duration by) {
    if (by.isNegative) {
      throw ArgumentError.value(by, 'by', 'a FakeClock cannot go backwards');
    }
    final end = _now.add(by);
    while (true) {
      _FakeTimer? next;
      for (final timer in _timers) {
        if (!timer.due.isAfter(end) &&
            (next == null || timer.due.isBefore(next.due))) {
          next = timer;
        }
      }
      if (next == null) break;
      _timers.remove(next);
      if (next.due.isAfter(_now)) _now = next.due;
      next.fire();
    }
    _now = end;
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this._clock, this.due, this._callback);

  final FakeClock _clock;
  final DateTime due;
  final void Function() _callback;
  var _fired = false;

  void fire() {
    _fired = true;
    _callback();
  }

  @override
  bool get isActive => !_fired && _clock._timers.contains(this);

  @override
  int get tick => _fired ? 1 : 0;

  @override
  void cancel() => _clock._timers.remove(this);
}
