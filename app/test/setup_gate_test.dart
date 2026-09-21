import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/routes.dart';
import 'package:kikuyomi/src/setup_gate.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';

void main() {
  group('setup is offered', () {
    late InMemorySettingsStore settings;

    Future<bool> offered({
      bool canChooseFolder = true,
      bool libraryIsEmpty = true,
    }) => shouldOfferSetup(
      settings: settings,
      canChooseFolder: canChooseFolder,
      libraryIsEmpty: () async => libraryIsEmpty,
    );

    setUp(() => settings = InMemorySettingsStore());

    test('when the app starts with an empty library', () async {
      expect(await offered(), isTrue);
    });

    test('not when the library has books', () async {
      expect(await offered(libraryIsEmpty: false), isFalse);
    });

    test('not once it was skipped, or completed', () async {
      await settings.write(AppSettings.backupSetup, BackupSetup.skipped);
      expect(await offered(), isFalse);
      await settings.write(AppSettings.backupSetup, BackupSetup.completed);
      expect(await offered(), isFalse);
    });

    test('not when a backup folder is set', () async {
      await settings.write(AppSettings.backupFolder, 'a folder');
      expect(await offered(), isFalse);
    });

    test('not where this device cannot choose a folder', () async {
      expect(await offered(canChooseFolder: false), isFalse);
    });
  });

  group('the gate', () {
    late SetupGate gate;
    late int told;

    setUp(() {
      gate = SetupGate();
      addTearDown(gate.dispose);
      told = 0;
      gate.addListener(() => told++);
    });

    test('is undecided until it decides, and tells the router', () async {
      expect(gate.offer, SetupOffer.undecided);
      await gate.decide(() async => true);
      expect(gate.offer, SetupOffer.offered);
      expect(told, 1);
    });

    test('decides once', () async {
      await gate.decide(() async => false);
      await gate.decide(() async => true);
      expect(gate.offer, SetupOffer.notOffered);
    });

    test('stops offering once setup is finished', () async {
      await gate.decide(() async => true);
      gate.finish();
      expect(gate.offer, SetupOffer.notOffered);
      expect(told, 2);
    });

    test('offers nothing when deciding fails', () async {
      await expectLater(
        gate.decide(() async => throw StateError('no database')),
        throwsStateError,
      );
      expect(gate.offer, SetupOffer.notOffered);
    });
  });

  group('the router', () {
    test('goes to setup from anywhere while it is offered', () {
      expect(setupRedirect(SetupOffer.offered, '/'), '/setup');
      expect(setupRedirect(SetupOffer.offered, '/book/7'), '/setup');
      expect(setupRedirect(SetupOffer.offered, '/setup'), isNull);
    });

    test('leaves setup for the home once it is finished', () {
      expect(setupRedirect(SetupOffer.notOffered, '/setup'), '/');
      expect(setupRedirect(SetupOffer.notOffered, '/'), isNull);
      expect(setupRedirect(SetupOffer.notOffered, '/settings'), isNull);
    });

    test('goes where it was going while undecided', () {
      expect(setupRedirect(SetupOffer.undecided, '/'), isNull);
      expect(setupRedirect(SetupOffer.undecided, '/setup'), isNull);
    });
  });
}
