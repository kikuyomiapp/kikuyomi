import 'dart:async';

import 'package:drift/drift.dart';

/// Runs [load] now, and again after every committed change to any of [tables], as a stream.
///
/// §2.6: screens watch the database rather than holding copies of it. Drift's own `watch()` does
/// that for a single query; a read model put together from several queries, as Continue Listening
/// and a book's details are, needs the same around the whole of it.
///
/// The stream listens for changes before the first load starts, so a change committed during that
/// load is not missed. Changes that arrive while a load is under way cause one more load when it
/// finishes rather than one each, so a burst of progress writes costs at most two loads. A load
/// that fails is reported on the stream, and watching carries on.
///
/// Each listener gets loads of its own. In Java terms the stream is cold, like a fresh `Flowable`
/// per subscriber, rather than a shared hot subject.
Stream<T> watchTables<T>(
  DatabaseConnectionUser db,
  Iterable<TableInfo<Table, Object?>> tables,
  Future<T> Function() load,
) => Stream.multi((controller) {
  var loading = false;
  var stale = false;
  var cancelled = false;

  Future<void> refresh() async {
    if (loading) {
      stale = true;
      return;
    }
    loading = true;
    do {
      stale = false;
      try {
        final value = await load();
        if (!cancelled) controller.add(value);
      } catch (error, stackTrace) {
        if (!cancelled) controller.addError(error, stackTrace);
      }
    } while (stale && !cancelled);
    loading = false;
  }

  final changes = db
      .tableUpdates(TableUpdateQuery.onAllTables(tables))
      .listen((_) => unawaited(refresh()));
  unawaited(refresh());
  controller.onCancel = () {
    cancelled = true;
    return changes.cancel();
  };
});
