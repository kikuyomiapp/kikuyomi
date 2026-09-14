import 'dart:convert';
import 'dart:typed_data';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// A folder handle, as stored: a JSON object whose `kind` says which implementation wrote it.
String encodeFolderHandle(String kind, Map<String, String> fields) =>
    jsonEncode({'kind': kind, ...fields});

/// The fields of [handle], when it is a handle of [kind] holding every one of [fields] as text.
/// Null for anything else: a handle is read back from settings, and settings can hold anything.
Map<String, String>? decodeFolderHandle(
  String handle, {
  required String kind,
  required List<String> fields,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(handle);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?> || decoded['kind'] != kind) return null;
  final values = <String, String>{};
  for (final field in fields) {
    final value = decoded[field];
    if (value is! String) return null;
    values[field] = value;
  }
  return values;
}

/// Throws [ArgumentError] unless [name] is the plain name of a file directly inside a folder.
void checkFileName(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains(r'\')) {
    throw ArgumentError.value(
      name,
      'name',
      'must be the name of a file in the folder',
    );
  }
}

/// A folder this device cannot use, for [reason]: its handle was written by another kind of device
/// or cannot be read, or this device cannot use chosen folders at all.
final class UnusableFolder implements UserFolder {
  const UnusableFolder(
    this.handle, {
    required this.reason,
    this.unsupported = false,
  });

  @override
  final String handle;

  /// Why the folder cannot be used, as a phrase for a person to read.
  final String reason;

  /// Whether the device cannot use chosen folders at all, rather than this one.
  final bool unsupported;

  @override
  String get displayName => 'A folder this device cannot use';

  FolderException get _failure => unsupported
      ? FolderUnsupportedException(reason)
      : FolderUnavailableException(reason);

  @override
  Future<FolderStatus> checkAccess() async => FolderUnreachable(reason);

  @override
  Future<List<FolderFile>> list() async => throw _failure;

  @override
  Future<Uint8List> read(String name) async => throw _failure;

  @override
  Future<void> write(String name, List<int> bytes) async => throw _failure;

  @override
  Future<void> delete(String name) async => throw _failure;
}
