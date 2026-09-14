import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';

import 'services.dart';

/// Supplied by `main()` once the database and engine are open.
final servicesProvider = Provider<AppServices>(
  (ref) => throw UnimplementedError('AppServices is provided by main()'),
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

/// A book's details, straight from the database. Disposed once no screen shows the book, so a
/// details screen visited once does not keep its queries running for the life of the app.
final bookOverviewProvider = StreamProvider.autoDispose
    .family<BookOverview?, int>(
      (ref, bookId) =>
          watchBookOverview(ref.watch(servicesProvider).database, bookId),
    );
