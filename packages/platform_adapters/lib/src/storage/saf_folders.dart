import 'package:flutter/services.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart' show SafDocumentFile;

import 'folder_handles.dart';

/// Folders on Android, through the Storage Access Framework (§3.10, §5.1).
///
/// The user picks a document tree, and the app takes a persistable read and write permission on it,
/// which Android keeps across restarts until the user removes it or the app is uninstalled. The
/// handle keeps the tree's address and its name, since reading the name back costs a query.
///
/// The folder is unreachable when the permission is gone, or the tree no longer exists.
final class SafFolders implements UserFolders {
  SafFolders([SafDocuments? documents])
    : _documents = documents ?? PluginSafDocuments();

  static const kind = 'saf-tree';

  final SafDocuments _documents;

  @override
  bool get canChoose => true;

  @override
  Future<UserFolder?> choose() async {
    final tree = await _documents.pickTree();
    return tree == null ? null : SafFolder(tree.uri, tree.name, _documents);
  }

  @override
  UserFolder open(String handle) => switch (decodeFolderHandle(
    handle,
    kind: kind,
    fields: ['uri', 'name'],
  )) {
    {'uri': final uri, 'name': final name} => SafFolder(uri, name, _documents),
    _ => UnusableFolder(
      handle,
      reason: 'the saved folder was not chosen on this device',
    ),
  };
}

/// A document tree the app holds a persistable permission on.
final class SafFolder implements UserFolder {
  SafFolder(this.uri, this.name, this._documents);

  /// The tree's address, as the picker gave it.
  final String uri;

  /// The tree's name when it was chosen.
  final String name;

  final SafDocuments _documents;

  @override
  String get handle =>
      encodeFolderHandle(SafFolders.kind, {'uri': uri, 'name': name});

  @override
  String get displayName => name;

  @override
  Future<FolderStatus> checkAccess() async {
    try {
      if (!await _documents.hasPermission(uri)) {
        return const FolderUnreachable(
          'Kikuyomi no longer has permission to use the folder',
        );
      }
      if (await _documents.stat(uri) == null) {
        return const FolderUnreachable('the folder no longer exists');
      }
      return const FolderReachable();
    } on PlatformException catch (error) {
      return FolderUnreachable(_describe(error));
    }
  }

  @override
  Future<List<FolderFile>> list() => _guard(() async {
    return [
      for (final document in await _documents.list(uri))
        if (!document.isDirectory)
          FolderFile(
            name: document.name,
            modifiedAt: document.modifiedAt,
            sizeBytes: document.sizeBytes,
          ),
    ];
  });

  @override
  Future<Uint8List> read(String name) {
    checkFileName(name);
    return _guard(() async {
      final document = await _documents.child(uri, name);
      if (document == null) {
        throw FolderOperationException('there is no file named $name');
      }
      return _documents.read(document.uri);
    });
  }

  @override
  Future<void> write(String name, List<int> bytes) {
    checkFileName(name);
    final partialName = '$name$partialFileSuffix';
    return _guard(() async {
      final partial = await _documents.write(
        uri,
        partialName,
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
      // A provider may store a file under another name than asked, for one already taken, and a
      // file under a name the app did not choose is one it would never recognise again.
      if (partial.name != partialName) {
        await _documents.delete(partial.uri);
        throw FolderOperationException(
          'the folder stored the file as ${partial.name} instead of '
          '$partialName',
        );
      }
      // Renaming onto a name that is taken gives another name rather than replacing the file, so a
      // file of the name goes first. Names of backups are unique to the millisecond, so this is a
      // rare second write of the same file, not a window in which a backup goes missing.
      final existing = await _documents.child(uri, name);
      if (existing != null) await _documents.delete(existing.uri);
      final SafDocument renamed;
      try {
        renamed = await _documents.rename(partial.uri, name);
      } on PlatformException {
        await _documents.delete(partial.uri);
        throw const FolderOperationException(
          'the folder does not let files be renamed, which writing a file '
          'safely needs',
        );
      }
      if (renamed.name != name) {
        await _documents.delete(renamed.uri);
        throw FolderOperationException(
          'the folder renamed the file to ${renamed.name} instead of $name',
        );
      }
    });
  }

  @override
  Future<void> delete(String name) {
    checkFileName(name);
    return _guard(() async {
      final document = await _documents.child(uri, name);
      if (document != null) await _documents.delete(document.uri);
    });
  }

  /// Runs [operation], turning a platform failure into the [FolderException] it means. Android
  /// reports a removed permission and a deleted tree alike as a failed call, so the folder is checked
  /// to tell them apart from other failures.
  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      if (await checkAccess() case FolderUnreachable(:final reason)) {
        throw FolderUnavailableException(reason);
      }
      throw FolderOperationException(_describe(error));
    }
  }
}

String _describe(PlatformException error) => error.message ?? error.code;

/// A document, as the Storage Access Framework describes it.
final class SafDocument {
  const SafDocument({
    required this.uri,
    required this.name,
    this.isDirectory = false,
    this.sizeBytes,
    this.modifiedAt,
  });

  final String uri;
  final String name;
  final bool isDirectory;
  final int? sizeBytes;
  final DateTime? modifiedAt;
}

/// The Storage Access Framework calls a [SafFolder] makes, behind a seam, so that what the folder
/// does with them can be tested without Android. Failures are [PlatformException]s, as the plugins
/// report them.
abstract interface class SafDocuments {
  /// Shows the tree picker and takes a persistable read and write permission on the tree chosen.
  Future<SafDocument?> pickTree();

  /// Whether the app still holds a persisted read and write permission on [treeUri].
  Future<bool> hasPermission(String treeUri);

  /// The tree itself, or null when it no longer exists.
  Future<SafDocument?> stat(String treeUri);

  Future<List<SafDocument>> list(String treeUri);

  /// The document named [name] directly inside [treeUri], or null.
  Future<SafDocument?> child(String treeUri, String name);

  Future<Uint8List> read(String documentUri);

  /// Writes [bytes] as the document [name] in [treeUri], replacing one of that name.
  Future<SafDocument> write(String treeUri, String name, Uint8List bytes);

  Future<SafDocument> rename(String documentUri, String name);

  Future<void> delete(String documentUri);
}

/// [SafDocuments] through `saf_util`, for picking, listing, renaming and deleting, and `saf_stream`,
/// for reading and writing.
///
/// Read against the plugins' Kotlin sources: the tree picker takes the persistable permission itself
/// when asked, every call runs off the main thread, and the addresses they return for documents are
/// addresses within the tree, which every later call accepts.
final class PluginSafDocuments implements SafDocuments {
  final _util = SafUtil();
  final _stream = SafStream();

  @override
  Future<SafDocument?> pickTree() async => _document(
    await _util.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    ),
  );

  @override
  Future<bool> hasPermission(String treeUri) =>
      _util.hasPersistedPermission(treeUri, checkRead: true, checkWrite: true);

  @override
  Future<SafDocument?> stat(String treeUri) async =>
      _document(await _util.stat(treeUri, true));

  @override
  Future<List<SafDocument>> list(String treeUri) async => [
    for (final file in await _util.list(treeUri)) _document(file)!,
  ];

  @override
  Future<SafDocument?> child(String treeUri, String name) async =>
      _document(await _util.child(treeUri, [name]));

  @override
  Future<Uint8List> read(String documentUri) =>
      _stream.readFileBytes(documentUri);

  @override
  Future<SafDocument> write(
    String treeUri,
    String name,
    Uint8List bytes,
  ) async {
    // A generic binary type, because a provider given a more specific one may append that type's
    // extension to the name, and Android's own storage provider keeps an unfamiliar extension only
    // for this type.
    final file = await _stream.writeFileBytes(
      treeUri,
      name,
      'application/octet-stream',
      bytes,
      overwrite: true,
    );
    return SafDocument(uri: file.uri.toString(), name: file.fileName ?? name);
  }

  @override
  Future<SafDocument> rename(String documentUri, String name) async =>
      _document(await _util.rename(documentUri, false, name))!;

  @override
  Future<void> delete(String documentUri) => _util.delete(documentUri, false);
}

SafDocument? _document(SafDocumentFile? file) => file == null
    ? null
    : SafDocument(
        uri: file.uri,
        name: file.name,
        isDirectory: file.isDir,
        // The plugin reports an unknown size as -1 and an unknown time as 0.
        sizeBytes: file.length < 0 ? null : file.length,
        modifiedAt: file.lastModified <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                file.lastModified,
                isUtc: true,
              ),
      );
