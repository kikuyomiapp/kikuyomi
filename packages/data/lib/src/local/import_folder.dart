import 'dart:io';
import 'dart:math' as math;

/// How much of each end of two same-sized files is compared to tell whether they are one book.
const _sampleBytes = 64 * 1024;

/// The app's own folder for books added through a file picker that hands over only a copy.
///
/// On iOS and Android the picker never gives the app the user's file, only a copy in a temporary or
/// cache folder that the system may clear at any time. A library that kept that path would lose the
/// book. So the copy is moved here, into storage the app owns, and the library refers to it by a
/// path relative to [mediaRoot], as `LocalMediaResolver` expects.
///
/// It stands in for the Local source's folders (§3.10) until they arrive. On iOS it is already the
/// Files-visible `Import` folder that §5.1 describes.
final class ImportFolder {
  ImportFolder({required this.mediaRoot, this.name = 'Import'});

  /// What the returned paths are relative to.
  final Directory mediaRoot;

  /// The folder's name inside [mediaRoot].
  final String name;

  /// Takes over [copy], a temporary copy from a file picker, and returns where it now lives,
  /// relative to [mediaRoot].
  ///
  /// The file keeps its name, since on iOS the folder is visible in the Files app. When a file with
  /// that name is already there and holds the same book, the copy is deleted and the existing file
  /// is used, so adding one book twice keeps it once. A different book with the same name is given
  /// a numbered name instead.
  ///
  /// The file is moved, not copied: never pass a file the user owns.
  Future<String> adoptCopy(File copy) async {
    final folder = await Directory('${mediaRoot.path}/$name')
        .create(recursive: true);
    final (stem, extension) = _splitName(_fileName(copy.path));
    for (var n = 1; ; n++) {
      final fileName = n == 1 ? '$stem$extension' : '$stem ($n)$extension';
      final target = File('${folder.path}/$fileName');
      if (!await target.exists()) {
        await _move(copy, target);
      } else if (await _sameBook(copy, target)) {
        await copy.delete();
      } else {
        continue;
      }
      return '$name/$fileName';
    }
  }
}

String _fileName(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  return name.isEmpty ? 'book' : name;
}

/// A file name split before its extension, which keeps its dot.
(String, String) _splitName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot > 0
      ? (fileName.substring(0, dot), fileName.substring(dot))
      : (fileName, '');
}

Future<void> _move(File from, File to) async {
  try {
    await from.rename(to.path);
  } on FileSystemException {
    // A rename cannot cross file systems. Copy, then remove the original.
    await from.copy(to.path);
    await from.delete();
  }
}

/// Whether two files hold the same book: the same size, and the same bytes at both ends.
///
/// Comparing whole files would read gigabytes to add one book. An MP4 keeps its movie box, with the
/// duration and sample tables, at one end or the other, so two different books that agree on their
/// size and on both ends are not a practical concern.
Future<bool> _sameBook(File a, File b) async {
  final size = await a.length();
  if (size != await b.length()) return false;
  final first = await a.open();
  final second = await b.open();
  try {
    for (final offset in {0, math.max(0, size - _sampleBytes)}) {
      final length = math.min(_sampleBytes, size - offset);
      await first.setPosition(offset);
      await second.setPosition(offset);
      final left = await first.read(length);
      final right = await second.read(length);
      if (left.length != length || right.length != length) return false;
      for (var i = 0; i < length; i++) {
        if (left[i] != right[i]) return false;
      }
    }
    return true;
  } finally {
    await first.close();
    await second.close();
  }
}
