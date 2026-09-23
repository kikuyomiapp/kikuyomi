/// What extensions are installed, as §4.3's `extension` table holds it.
///
/// The app reads this at every start and shows it on the Extensions screen. It is deliberately the
/// only thing the app has to go on after a restart: the code sits in the app's own storage at
/// [ExtensionRow.installPath], and where the extension came from is [ExtensionRow.originHandle], so
/// nothing has to be found again by looking around the device.
///
/// Nothing here runs a line of extension code, and nothing here reads a manifest. §3.6 starts a
/// runtime on first use.
library;

import 'package:drift/drift.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import '../database/database.dart';

/// Records an extension as installed, replacing what was recorded for the same id.
///
/// Replacing, because that is what installing a version of an extension already installed means: one
/// row per extension, holding the version in use. Earlier versions' files stay on disk for §3.9's
/// rollback; which one is in use is this row.
Future<void> recordInstalledExtension(
  KikuyomiDatabase db, {
  required String id,
  required String name,
  required String version,
  required int versionCode,
  required String apiVersion,
  required ExtensionStatus status,
  required ExtensionOrigin origin,
  required Clock clock,
  String? originHandle,
  String? originName,
  String? installPath,
}) => db
    .into(db.extensions)
    .insertOnConflictUpdate(
      ExtensionsCompanion.insert(
        id: id,
        name: name,
        version: version,
        versionCode: versionCode,
        apiVersion: apiVersion,
        status: status,
        origin: origin,
        originHandle: Value(originHandle),
        originName: Value(originName),
        installPath: Value(installPath),
        installedAt: clock.now(),
      ),
    );

/// Every installed extension, by name, as a listener reads a list.
Future<List<ExtensionRow>> readInstalledExtensions(KikuyomiDatabase db) =>
    (db.select(db.extensions)..orderBy([
          (e) => OrderingTerm.asc(e.name),
          (e) => OrderingTerm.asc(e.id),
        ]))
        .get();

/// Every installed extension, watched, so the Extensions screen follows an install or a removal
/// without being told (§2.5).
Stream<List<ExtensionRow>> watchInstalledExtensions(KikuyomiDatabase db) =>
    (db.select(db.extensions)..orderBy([
          (e) => OrderingTerm.asc(e.name),
          (e) => OrderingTerm.asc(e.id),
        ]))
        .watch();

/// The installed extension [id], or null when it is not installed.
Future<ExtensionRow?> readInstalledExtension(KikuyomiDatabase db, String id) =>
    (db.select(db.extensions)..where((e) => e.id.equals(id))).getSingleOrNull();

/// Forgets that [id] was installed, and returns whether it was.
///
/// Only this row. §3.9: "Uninstalling removes the code but not the user's data." The books that came
/// from its sources, their progress, the `source` rows they point at and whatever the extension had
/// stored all stay exactly as they were, so that installing it again finds the library it left.
Future<bool> forgetInstalledExtension(KikuyomiDatabase db, String id) async =>
    await (db.delete(db.extensions)..where((e) => e.id.equals(id))).go() > 0;

/// Records that [id] may no longer run, or may again (§3.8).
Future<void> setExtensionStatus(
  KikuyomiDatabase db,
  String id,
  ExtensionStatus status,
) async {
  await (db.update(db.extensions)..where((e) => e.id.equals(id))).write(
    ExtensionsCompanion(status: Value(status)),
  );
}
