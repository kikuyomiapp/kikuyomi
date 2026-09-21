import 'package:drift/native.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:test/test.dart';

void main() {
  late KikuyomiDatabase db;
  late int signals;

  setUp(() {
    db = KikuyomiDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    signals = 0;
    final subscription = backedUpChanges(db).listen((_) => signals++);
    addTearDown(subscription.cancel);
  });

  test('covers every table in the database', () {
    // A table added to the schema has to be added to backedUpTables, or be left out of it on purpose
    // and listed here as such.
    expect(
      {for (final table in backedUpTables(db)) table.actualTableName},
      {for (final table in db.allTables) table.actualTableName},
    );
  });

  test('signals a change to what a backup carries', () async {
    await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: 'Next up', sortOrder: 0));
    await pumpEventQueue();
    expect(signals, 1);
  });

  test('signals once for a transaction, when it commits', () async {
    await db.transaction(() async {
      for (var i = 0; i < 3; i++) {
        await db
            .into(db.categories)
            .insert(CategoriesCompanion.insert(name: 'Shelf $i', sortOrder: i));
      }
    });
    await pumpEventQueue();
    expect(signals, 1);
  });

  test('signals nothing while nothing is written', () async {
    await db.select(db.books).get();
    await pumpEventQueue();
    expect(signals, 0);
  });
}
