import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

void main() {
  late FakeClock clock;

  setUp(() => clock = FakeClock(DateTime.utc(2026, 9, 14)));

  test('fires a timer once time reaches it, and not before', () {
    final fired = <DateTime>[];
    clock.startTimer(const Duration(minutes: 3), () => fired.add(clock.now()));

    clock.advance(const Duration(minutes: 2, seconds: 59));
    expect(fired, isEmpty);
    clock.advance(const Duration(seconds: 1));
    expect(fired, [DateTime.utc(2026, 9, 14, 0, 3)]);
    expect(clock.pendingTimers, 0);
  });

  test('fires timers in the order their times come, showing each time', () {
    final fired = <(String, DateTime)>[];
    clock
      ..startTimer(
        const Duration(minutes: 5),
        () => fired.add(('late', clock.now())),
      )
      ..startTimer(
        const Duration(minutes: 1),
        () => fired.add(('early', clock.now())),
      );

    clock.advance(const Duration(hours: 1));
    expect(fired, [
      ('early', DateTime.utc(2026, 9, 14, 0, 1)),
      ('late', DateTime.utc(2026, 9, 14, 0, 5)),
    ]);
    expect(clock.now(), DateTime.utc(2026, 9, 14, 1));
  });

  test('fires a timer started by another if its time comes', () {
    final fired = <DateTime>[];
    clock.startTimer(const Duration(minutes: 1), () {
      clock.startTimer(
        const Duration(minutes: 1),
        () => fired.add(clock.now()),
      );
    });

    clock.advance(const Duration(minutes: 5));
    expect(fired, [DateTime.utc(2026, 9, 14, 0, 2)]);
  });

  test('never fires a cancelled timer', () {
    var fired = false;
    final timer = clock.startTimer(
      const Duration(minutes: 1),
      () => fired = true,
    );
    expect(timer.isActive, isTrue);

    timer.cancel();
    clock.advance(const Duration(minutes: 5));
    expect(fired, isFalse);
    expect(timer.isActive, isFalse);
  });

  test('cannot go backwards', () {
    expect(
      () => clock.advance(const Duration(seconds: -1)),
      throwsArgumentError,
    );
  });
}
