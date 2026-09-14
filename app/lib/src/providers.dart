import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart' show NavigationEntry;
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

/// A book's navigation for the player's chapter list: its chapters, or the markers embedded in its
/// file standing in for them (§4.5), in book-global time.
///
/// Read once from the stored layout, as opening the book reads it, rather than watched: the
/// coordinator goes on playing the Timeline it was opened with, so a list read the same way stays in
/// step with what plays. Disposed with the screen that shows it, so a book opened again is read
/// afresh.
final navigationProvider = FutureProvider.autoDispose
    .family<List<NavigationEntry>, int>((ref, bookId) async {
      final db = ref.watch(servicesProvider).database;
      return (await loadStoredPlayback(db, bookId)).timeline.navigation;
    });
