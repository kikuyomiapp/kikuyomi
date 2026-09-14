import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'folder_handles.dart';

/// Folders as plain directory paths, as desktop platforms give them (§5.1: on Windows, any folder).
///
/// A path needs nothing to keep access to it across restarts, so the handle is the path itself. It
/// stops working when the folder is moved, renamed or deleted, or its drive is not connected, which
/// is reported as the folder being unreachable.
final class DirectoryFolders implements UserFolders {
  /// [pickDirectory] shows the picker and returns the path chosen; the platform's folder dialog,
  /// unless a test gives another.
  DirectoryFolders({Future<String?> Function()? pickDirectory})
    : _pickDirectory = pickDirectory ?? _showFolderDialog;

  static const kind = 'directory';

  final Future<String?> Function() _pickDirectory;

  @override
  bool get canChoose => true;

  @override
  Future<UserFolder?> choose() async {
    final path = await _pickDirectory();
    return path == null ? null : DirectoryFolder(Directory(path).absolute.path);
  }

  @override
  UserFolder open(String handle) =>
      switch (decodeFolderHandle(handle, kind: kind, fields: ['path'])) {
        {'path': final path} => DirectoryFolder(path),
        _ => UnusableFolder(
          handle,
          reason: 'the saved folder was not chosen on this device',
        ),
      };
}

Future<String?> _showFolderDialog() =>
    getDirectoryPath(confirmButtonText: 'Choose');

/// A folder at a directory path.
final class DirectoryFolder implements UserFolder {
  const DirectoryFolder(this.path);

  /// Absolute.
  final String path;

  @override
  String get handle =>
      encodeFolderHandle(DirectoryFolders.kind, {'path': path});

  @override
  String get displayName => path;

  Directory get _directory => Directory(path);

  File _file(String name) {
    checkFileName(name);
    return File('$path${Platform.pathSeparator}$name');
  }

  @override
  Future<FolderStatus> checkAccess() async {
    try {
      if (!await _directory.exists()) {
        return const FolderUnreachable('the folder no longer exists');
      }
      // Listing proves the folder can be read, which existing alone does not.
      await _directory.list().isEmpty;
      return const FolderReachable();
    } on FileSystemException catch (error) {
      return FolderUnreachable(_describe(error));
    }
  }

  @override
  Future<List<FolderFile>> list() => _guard(() async {
    final files = <FolderFile>[];
    await for (final entry in _directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final stat = await entry.stat();
      files.add(
        FolderFile(
          name: entry.uri.pathSegments.last,
          modifiedAt: stat.modified.toUtc(),
          sizeBytes: stat.size,
        ),
      );
    }
    return files;
  });

  @override
  Future<Uint8List> read(String name) {
    final file = _file(name);
    return _guard(file.readAsBytes);
  }

  @override
  Future<void> write(String name, List<int> bytes) {
    final file = _file(name);
    final partial = _file('$name$partialFileSuffix');
    return _guard(() async {
      try {
        await partial.writeAsBytes(bytes, flush: true);
        // A rename within one directory is atomic, and replaces an existing file of the name, on
        // Windows as elsewhere: `dart:io` asks Windows to replace it.
        await partial.rename(file.path);
      } on FileSystemException {
        try {
          await partial.delete();
        } on FileSystemException {
          // Never written, or already gone.
        }
        rethrow;
      }
    });
  }

  @override
  Future<void> delete(String name) {
    final file = _file(name);
    return _guard(() async {
      try {
        await file.delete();
      } on PathNotFoundException {
        // Already gone, which is what was asked for.
      }
    });
  }

  /// Runs [operation], turning a file system failure into the [FolderException] it means.
  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on FileSystemException catch (error) {
      if (!await _directory.exists()) {
        throw const FolderUnavailableException('the folder no longer exists');
      }
      throw FolderOperationException(_describe(error));
    }
  }
}

String _describe(FileSystemException error) => switch (error.osError) {
  final os? when os.message.isNotEmpty => '${error.message}: ${os.message}',
  _ => error.message,
};
