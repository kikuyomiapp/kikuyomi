import 'dart:io';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'directory_folders.dart';
import 'folder_handles.dart';
import 'saf_folders.dart';

/// The way this device chooses folders outside the app's storage (§5.1), so that the composition
/// root never asks which platform it runs on.
///
/// - Android: Storage Access Framework trees, through [SafFolders].
/// - Windows, and desktop platforms generally: directory paths, through [DirectoryFolders].
/// - iOS: not yet. Keeping access to a folder the user picks in Files takes a security-scoped
///   bookmark, and no maintained plugin creates and resolves bookmarks for folders on iOS. Rather
///   than seem to keep a folder it would lose at the next start, iOS reports that it cannot choose
///   one.
abstract final class DeviceFolders {
  static UserFolders forThisDevice() {
    if (Platform.isAndroid) return SafFolders();
    if (Platform.isIOS) return const UnsupportedFolders();
    return DirectoryFolders();
  }
}

/// Folders on a device that cannot keep access to one yet.
final class UnsupportedFolders implements UserFolders {
  const UnsupportedFolders();

  static const _reason =
      'choosing a folder is not supported on this device yet';

  @override
  bool get canChoose => false;

  @override
  Future<UserFolder?> choose() async =>
      throw const FolderUnsupportedException(_reason);

  @override
  UserFolder open(String handle) =>
      UnusableFolder(handle, reason: _reason, unsupported: true);
}
