/// Folders the user chooses outside the app's own storage, behind an interface.
///
/// §5.1 sends automatic backups to a folder the user picks, on every platform, because the app's own
/// storage is exactly what an Android uninstall and an iOS re-sign lose (Appendix A). How a folder is
/// chosen and kept differs by platform: a plain path on Windows, a Storage Access Framework tree with
/// a persistable permission on Android, a security-scoped bookmark on iOS. The platform adapters
/// implement this for each, and the pure packages that write to such a folder, `backup` now and
/// `sync` later (ADR-0011), see only this.
library;

import 'dart:typed_data';

/// What [UserFolder.write] appends to a file's name while the file is being written.
///
/// A file with this suffix is never a finished file. Code that recognises its own files by name,
/// as backups do, can recognise one left behind by a write that never finished, too.
const partialFileSuffix = '.partial';

/// Choosing folders, and opening those chosen before.
abstract interface class UserFolders {
  /// Whether this device can choose a folder. False where the platform's way of keeping access to a
  /// folder is not implemented yet; then [choose] throws [FolderUnsupportedException].
  bool get canChoose;

  /// Shows the platform's folder picker, and returns the folder chosen, with access to it kept
  /// across restarts. Null when the user cancels.
  Future<UserFolder?> choose();

  /// The folder [handle] names, as [UserFolder.handle] gave it.
  ///
  /// Asks nothing of the platform. A folder that can no longer be reached, or a handle this device
  /// cannot read, shows up in [UserFolder.checkAccess] and in the folder's operations instead.
  UserFolder open(String handle);
}

/// A folder the user chose.
///
/// Every operation throws a [FolderException] when it fails: [FolderUnavailableException] when the
/// folder itself can no longer be reached, and [FolderOperationException] for anything else. A
/// [name] is always the plain name of a file directly inside the folder; anything else is an
/// [ArgumentError].
abstract interface class UserFolder {
  /// What to store to open this folder again with [UserFolders.open].
  String get handle;

  /// What to call the folder in the app: a path on desktop, the folder's own name on Android.
  String get displayName;

  /// Whether the folder can still be reached. Never throws.
  Future<FolderStatus> checkAccess();

  /// The files directly inside the folder, in no particular order. Folders inside it are left out.
  Future<List<FolderFile>> list();

  /// The content of the file [name].
  Future<Uint8List> read(String name);

  /// Writes [bytes] as the file [name], replacing any file of that name.
  ///
  /// Safely: the bytes are written under [name] with [partialFileSuffix] appended, and the file takes
  /// its real name only once all of them are written. A write that fails or is cut short, by the app
  /// being ended or the disk filling up, never leaves a file under [name] that looks finished.
  Future<void> write(String name, List<int> bytes);

  /// Deletes the file [name]. Deleting a file that is not there does nothing.
  Future<void> delete(String name);
}

/// A file in a [UserFolder].
final class FolderFile {
  const FolderFile({required this.name, this.modifiedAt, this.sizeBytes});

  final String name;

  /// When the file was last written, where the platform says.
  final DateTime? modifiedAt;

  /// The file's size, where the platform says.
  final int? sizeBytes;
}

/// Whether a [UserFolder] can be reached.
sealed class FolderStatus {
  const FolderStatus();
}

/// The folder is there, and the app may use it.
final class FolderReachable extends FolderStatus {
  const FolderReachable();
}

/// The folder can no longer be reached: it was moved or deleted, the permission to use it was
/// removed, or the platform's record of it expired.
///
/// Recoverable: choosing the folder again, or another, restores access.
final class FolderUnreachable extends FolderStatus {
  const FolderUnreachable(this.reason);

  /// Why, as a phrase for a person to read, such as "the folder no longer exists".
  final String reason;
}

/// A folder operation that failed.
sealed class FolderException implements Exception {
  const FolderException(this.message);

  /// What went wrong, as a phrase for a person to read.
  final String message;
}

/// The folder can no longer be reached, as [FolderUnreachable] describes. Choosing it again fixes
/// this; trying again does not.
final class FolderUnavailableException extends FolderException {
  const FolderUnavailableException(super.message);

  @override
  String toString() => 'FolderUnavailableException: $message';
}

/// This device cannot use a chosen folder yet.
final class FolderUnsupportedException extends FolderException {
  const FolderUnsupportedException(super.message);

  @override
  String toString() => 'FolderUnsupportedException: $message';
}

/// Anything else: the disk is full, a file is missing, the folder refused something. The folder can
/// still be reached, so trying again later may work.
final class FolderOperationException extends FolderException {
  const FolderOperationException(super.message);

  @override
  String toString() => 'FolderOperationException: $message';
}
