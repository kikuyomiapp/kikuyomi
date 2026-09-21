import 'dart:async';
import 'dart:typed_data';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Folders held in memory, standing in for the platform's folder picker.
final class FakeUserFolders implements UserFolders {
  FakeUserFolders({this.canChoose = true});

  @override
  bool canChoose;

  /// What the next [choose] returns. Null, the default, is the user cancelling.
  FakeUserFolder? nextChoice;

  /// Every folder chosen so far, or added by a test, by handle.
  final folders = <String, FakeUserFolder>{};

  /// How many times the picker was shown.
  var pickerShown = 0;

  /// Makes [folder] one that [open] finds.
  FakeUserFolder add(FakeUserFolder folder) => folders[folder.handle] = folder;

  @override
  Future<UserFolder?> choose() async {
    if (!canChoose) {
      throw const FolderUnsupportedException('not supported on this device');
    }
    pickerShown++;
    final chosen = nextChoice;
    if (chosen != null) add(chosen);
    return chosen;
  }

  /// The folder added under [handle]. A handle nobody added opens as a folder that can no longer be
  /// reached, as a stale handle does on a real device.
  @override
  UserFolder open(String handle) =>
      folders[handle] ??
      (FakeUserFolder(handle: handle, displayName: handle)
        ..unreachable = 'the folder no longer exists');
}

/// A folder whose files are kept in memory.
final class FakeUserFolder implements UserFolder {
  FakeUserFolder({
    this.handle = 'backups',
    this.displayName = 'Backups',
    Map<String, List<int>> files = const {},
  }) : files = {
         for (final MapEntry(:key, :value) in files.entries)
           key: List<int>.of(value),
       };

  @override
  final String handle;

  @override
  final String displayName;

  /// The files in the folder, by name. Tests may change it to set up a case.
  final Map<String, List<int>> files;

  /// When set, the folder can no longer be reached, for this reason.
  String? unreachable;

  /// When set, the next [write] fails with it, leaving the folder as it was.
  FolderException? failNextWrite;

  /// Names whose deletion fails.
  final failDeletes = <String>{};

  /// While set, every [write] waits for it before finishing.
  Completer<void>? holdWrites;

  /// The names written, in order.
  final written = <String>[];

  /// The names deleted, in order.
  final deleted = <String>[];

  void _checkReachable() {
    final reason = unreachable;
    if (reason != null) throw FolderUnavailableException(reason);
  }

  @override
  Future<FolderStatus> checkAccess() async => switch (unreachable) {
    final reason? => FolderUnreachable(reason),
    null => const FolderReachable(),
  };

  @override
  Future<List<FolderFile>> list() async {
    _checkReachable();
    return [
      for (final MapEntry(:key, :value) in files.entries)
        FolderFile(name: key, sizeBytes: value.length),
    ];
  }

  @override
  Future<Uint8List> read(String name) async {
    _checkReachable();
    final bytes = files[name];
    if (bytes == null) {
      throw FolderOperationException('there is no file named $name');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String name, List<int> bytes) async {
    _checkReachable();
    final held = holdWrites;
    if (held != null) await held.future;
    final failure = failNextWrite;
    if (failure != null) {
      failNextWrite = null;
      throw failure;
    }
    files[name] = List<int>.of(bytes);
    written.add(name);
  }

  @override
  Future<void> delete(String name) async {
    _checkReachable();
    if (failDeletes.contains(name)) {
      throw FolderOperationException('the folder refused to delete $name');
    }
    if (files.remove(name) != null) deleted.add(name);
  }
}
