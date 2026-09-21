import 'dart:async';
import 'dart:math' show max;

import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';
import 'package:test/test.dart';

Duration min(int minutes, [int seconds = 0]) =>
    Duration(minutes: minutes, seconds: seconds);

void main() {
  final start = DateTime.utc(2026, 9, 14, 12);

  late FakeClock clock;
  late InMemorySettingsStore settings;
  late StreamController<void> changes;
  late BackupScheduler scheduler;

  /// When each backup started, as time since [start].
  late List<Duration> backups;

  /// What the next backups come to.
  late BackupOutcome Function() outcome;

  /// While set, backups wait for it before finishing.
  Completer<void>? hold;

  late int running;
  late int mostAtOnce;

  Future<BackupOutcome> backUp() async {
    backups.add(clock.now().difference(start));
    running++;
    mostAtOnce = max(mostAtOnce, running);
    final held = hold;
    if (held != null) await held.future;
    running--;
    return outcome();
  }

  BackupWritten written() =>
      BackupWritten(fileName: 'backup', takenAt: clock.now());

  BackupScheduler schedulerOf() => BackupScheduler(
    backUp: backUp,
    changes: changes.stream,
    settings: settings,
    clock: clock,
    startTimer: clock.startTimer,
  );

  Future<void> change() async {
    changes.add(null);
    await pumpEventQueue();
  }

  Future<void> advance(Duration by) async {
    clock.advance(by);
    await pumpEventQueue();
  }

  /// Changes every five seconds for [length], as listening saves progress.
  Future<void> listen(Duration length) async {
    final end = clock.now().add(length);
    while (clock.now().isBefore(end)) {
      await change();
      await advance(const Duration(seconds: 5));
    }
  }

  setUp(() {
    clock = FakeClock(start);
    settings = InMemorySettingsStore();
    changes = StreamController<void>.broadcast();
    backups = [];
    outcome = written;
    hold = null;
    running = 0;
    mostAtOnce = 0;
    scheduler = schedulerOf()..start();
  });

  tearDown(() async {
    hold?.complete();
    await scheduler.dispose();
    await changes.close();
  });

  group('after a change', () {
    test('backs up once changes have settled for three minutes', () async {
      await change();
      await advance(min(2, 59));
      expect(backups, isEmpty);
      await advance(const Duration(seconds: 1));
      expect(backups, [min(3)]);
    });

    test('waits again with every change', () async {
      await change();
      await advance(min(2));
      await change();
      await advance(min(2));
      await change();
      await advance(min(2, 59));
      expect(backups, isEmpty);
      await advance(const Duration(seconds: 1));
      expect(backups, [min(7)]);
    });

    test('never waits more than fifteen minutes after the first change not backed up', () async {
      await listen(min(40));
      // The change right after the first backup starts the next wait.
      expect(backups, [min(15), min(30)]);
    });

    test('backs up once for a burst of changes', () async {
      for (var i = 0; i < 10; i++) {
        await change();
      }
      await advance(min(10));
      expect(backups, [min(3)]);
    });
  });

  group('when the app leaves', () {
    test('backs up at once if anything changed', () async {
      await change();
      await advance(min(1));
      await scheduler.appLeaving();
      expect(backups, [min(1)]);

      // The backup it would have run later is no longer due.
      await advance(min(10));
      expect(backups, [min(1)]);
    });

    test('writes nothing if nothing changed', () async {
      await scheduler.appLeaving();
      expect(backups, isEmpty);
    });

    test('writes nothing if nothing changed since the last backup', () async {
      await change();
      await advance(min(3));
      await scheduler.appLeaving();
      expect(backups, [min(3)]);
    });

    test('waits for a backup under way, and adds none if nothing changed '
        'since it began', () async {
      hold = Completer<void>();
      await change();
      await advance(min(3));

      final leaving = scheduler.appLeaving();
      await pumpEventQueue();
      hold!.complete();
      hold = null;
      await leaving;
      expect(backups, [min(3)]);
    });
  });

  group('one backup at a time', () {
    test(
      'a change during a backup makes another due, run once the first finishes',
      () async {
        hold = Completer<void>();
        await change();
        await advance(min(3));
        expect(backups, [min(3)]);

        // The second comes due while the first is still writing.
        await change();
        await advance(min(3));
        expect(backups, [min(3)]);

        final held = hold!;
        hold = null;
        held.complete();
        await pumpEventQueue();
        expect(backups, [min(3), min(6)]);
        expect(mostAtOnce, 1);
      },
    );

    test(
      'backing up now waits for a backup under way, then writes another',
      () async {
        hold = Completer<void>();
        await change();
        await advance(min(3));

        final now = scheduler.backUpNow();
        await advance(min(1));
        expect(backups, [min(3)]);

        final held = hold!;
        hold = null;
        held.complete();
        expect(await now, isA<BackupWritten>());
        expect(backups, [min(3), min(4)]);
        expect(mostAtOnce, 1);
      },
    );
  });

  test('backs up now when asked, even with nothing changed', () async {
    expect(await scheduler.backUpNow(), isA<BackupWritten>());
    expect(backups, [Duration.zero]);
  });

  group('a backup that failed', () {
    setUp(() {
      outcome = () => const BackupNotConfigured();
    });

    test('stays due, and runs again when the app leaves', () async {
      await change();
      await advance(min(3));
      expect(scheduler.isDue, isTrue);

      await scheduler.appLeaving();
      expect(backups, [min(3), min(3)]);
    });

    test(
      'is tried again after the longest wait, not on every change',
      () async {
        await change();
        await advance(min(3));
        await listen(min(16));
        // Due again from the failure at three minutes, so the next try is at eighteen.
        expect(backups, [min(3), min(18)]);
      },
    );

    test('reports how it failed', () async {
      final outcomes = <BackupOutcome>[];
      scheduler.outcomes.listen(outcomes.add);
      await change();
      await advance(min(3));
      expect(outcomes.single, isA<BackupNotConfigured>());
      expect(scheduler.lastOutcome, same(outcomes.single));
    });

    test('is reported as failed when the backup throws', () async {
      outcome = () => throw StateError('broken');
      expect(await scheduler.backUpNow(), isA<BackupFailed>());
    });
  });

  group('across restarts', () {
    test('a change is remembered as due until a backup is written', () async {
      await change();
      expect(settings.read(AppSettings.backupDue), isTrue);
      await advance(min(3));
      expect(settings.read(AppSettings.backupDue), isNull);
    });

    test('a backup still due when the app stopped runs once changes would have settled', () async {
      await settings.write(AppSettings.backupDue, true);
      final next = schedulerOf()..start();
      addTearDown(next.dispose);

      await advance(min(3));
      expect(backups, [min(3)]);
    });

    test('a change during a backup keeps it due', () async {
      hold = Completer<void>();
      await change();
      await advance(min(3));
      await change();

      final held = hold!;
      hold = null;
      held.complete();
      await pumpEventQueue();
      expect(settings.read(AppSettings.backupDue), isTrue);
    });
  });

  test('stops once disposed', () async {
    await scheduler.dispose();
    changes.add(null);
    await advance(min(20));
    expect(backups, isEmpty);
    expect(clock.pendingTimers, 0);
  });
}
