import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';

import 'services.dart';
import 'setup_gate.dart';
import 'sources/extension_console.dart';
import 'sources/extension_library.dart';
import 'sources/source_gateway.dart';
import 'sources/source_registry.dart';

/// Supplied by `main()` once the database and engine are open.
final servicesProvider = Provider<AppServices>(
  (ref) => throw UnimplementedError('AppServices is provided by main()'),
);

/// Every source the app offers, from manifests alone (§3.6). Reading it runs no extension code.
final sourceRegistryProvider = Provider<SourceRegistry>(
  (ref) => ref.watch(servicesProvider).sources,
);

/// Every source the app offers, and the list again after every install and removal.
///
/// A [Provider] would not do: installing an extension adds sources while a screen is open, and §2.5
/// has screens follow what changes rather than hold a copy of it. The current list comes first, so a
/// screen shows the sources in its first frame.
final sourceListProvider = StreamProvider<List<SourceDescription>>((ref) {
  final gateway = ref.watch(sourceGatewayProvider);
  return Stream<List<SourceDescription>>.multi((controller) {
    controller.add(gateway.sources);
    final subscription = gateway.sourceChanges.listen(
      controller.add,
      onError: controller.addError,
    );
    controller.onCancel = subscription.cancel;
  });
});

/// Every extension the app knows about, watched, for the Extensions screen (§3.9).
final extensionsProvider = StreamProvider<List<ExtensionSummary>>(
  (ref) => ref.watch(servicesProvider).extensions.watch(),
);

/// What is in the extension console (§3.5), and its contents again after every line.
///
/// The console keeps its lines in memory rather than in the database, so this reads them on every
/// signal rather than watching a query.
final extensionConsoleProvider = StreamProvider<List<ExtensionLogLine>>((ref) {
  final console = ref.watch(servicesProvider).extensionConsole;
  return Stream<List<ExtensionLogLine>>.multi((controller) {
    controller.add(console.lines);
    final subscription = console.changes.listen(
      (_) => controller.add(console.lines),
      onError: controller.addError,
    );
    controller.onCancel = subscription.cancel;
  });
});

/// What the Browse screens reach the sources through. Overridden in a widget test with a fake
/// source, which is how those screens are tested without a database, an engine or a network.
final sourceGatewayProvider = Provider<SourceGateway>(
  (ref) => AppSourceGateway(ref.watch(servicesProvider)),
);

/// The library, straight from the database. §2.6: screens watch Drift streams rather than holding
/// copies, so an import appears without anything being refreshed.
final libraryProvider = StreamProvider<List<BookRow>>((ref) {
  final db = ref.watch(servicesProvider).database;
  return (db.select(db.books)
        ..where((b) => b.inLibrary.equals(true))
        ..orderBy([(b) => OrderingTerm.desc(b.dateAdded)]))
      .watch();
});

final bookProvider = StreamProvider.family<BookRow?, int>((ref, bookId) {
  final db = ref.watch(servicesProvider).database;
  return (db.select(
    db.books,
  )..where((b) => b.id.equals(bookId))).watchSingleOrNull();
});

/// The coordinator's state, starting from its current value so a screen opened mid-playback does not
/// wait for the next change to show anything.
final playerStateProvider = StreamProvider<PlayerState>((ref) {
  final coordinator = ref.watch(servicesProvider).coordinator;
  return Stream<PlayerState>.multi((controller) {
    controller.add(coordinator.state);
    final subscription = coordinator.states.listen(
      controller.add,
      onError: controller.addError,
    );
    controller.onCancel = subscription.cancel;
  });
});

/// Continue Listening, straight from the database: the started, unfinished books in the library,
/// most recently played first. It emits again on every progress save, so a book's place on the
/// shelf keeps up while it plays.
final continueListeningProvider = StreamProvider<List<ContinueListeningBook>>(
  (ref) => watchContinueListening(ref.watch(servicesProvider).database),
);

/// Whether backup setup is offered at start. The router redirects by it.
final setupGateProvider = Provider<SetupGate>((ref) {
  final gate = SetupGate();
  ref.onDispose(gate.dispose);
  return gate;
});

/// Whether the reminder to choose a backup folder was put off with "Not now". Kept only in memory,
/// so the reminder comes back at the next start: it stays on the home until a folder is chosen.
final backupReminderPutOffProvider =
    NotifierProvider<BackupReminderPutOff, bool>(BackupReminderPutOff.new);

class BackupReminderPutOff extends Notifier<bool> {
  @override
  bool build() => false;

  void putOff() => state = true;
}

/// The folder backups go to, or null before one is chosen, from settings.
final backupFolderProvider = StreamProvider<UserFolder?>(
  (ref) => ref.watch(servicesProvider).backups.watchFolder(),
);

/// Whether the backup folder can still be reached, or null while none is chosen. Checked afresh
/// whenever a screen that shows it opens.
final backupFolderStatusProvider = FutureProvider.autoDispose<FolderStatus?>((
  ref,
) async {
  final folder = await ref.watch(backupFolderProvider.future);
  return folder?.checkAccess();
});

/// When the last backup was written, or null for never.
final lastBackupProvider = StreamProvider<DateTime?>(
  (ref) => ref.watch(servicesProvider).backups.watchLastBackup(),
);

/// How the last backup went, since the app started, and each one after.
final lastBackupOutcomeProvider = StreamProvider<BackupOutcome?>((ref) {
  final scheduler = ref.watch(servicesProvider).backupScheduler;
  return Stream<BackupOutcome?>.multi((controller) {
    controller.add(scheduler.lastOutcome);
    final subscription = scheduler.outcomes.listen(controller.add);
    controller.onCancel = subscription.cancel;
  });
});

/// What the source a book came from is called, for a message about a failure at it.
///
/// A streamed book fails with one of the contract's error kinds, and those messages are written
/// around the source's name (§3.4). Disposed once nothing shows it.
final bookSourceNameProvider = FutureProvider.autoDispose.family<String, int>((
  ref,
  bookId,
) async {
  final db = ref.watch(servicesProvider).database;
  final book = await (db.select(
    db.books,
  )..where((b) => b.id.equals(bookId))).getSingleOrNull();
  if (book == null) return 'This source';
  return ref.watch(sourceGatewayProvider).nameOf(book.sourceId);
});

/// A book's details, straight from the database. Disposed once no screen shows the book, so a
/// details screen visited once does not keep its queries running for the life of the app.
final bookOverviewProvider = StreamProvider.autoDispose
    .family<BookOverview?, int>(
      (ref, bookId) =>
          watchBookOverview(ref.watch(servicesProvider).database, bookId),
    );

/// A book's bookmarks in playing order, straight from the database, so one added, changed or
/// deleted shows at once. Disposed once no screen shows them.
final bookmarksProvider = StreamProvider.autoDispose
    .family<List<BookmarkOverview>, int>(
      (ref, bookId) =>
          watchBookmarks(ref.watch(servicesProvider).database, bookId),
    );
