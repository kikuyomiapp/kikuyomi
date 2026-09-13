import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// A clock that moves only when a test tells it to.
final class FakeClock implements Clock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026);

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Moves time forward. Time never moves backwards here; code that must survive a device clock
  /// being set back should be tested by constructing a new clock instead.
  void advance(Duration by) {
    if (by.isNegative) {
      throw ArgumentError.value(by, 'by', 'a FakeClock cannot go backwards');
    }
    _now = _now.add(by);
  }
}
