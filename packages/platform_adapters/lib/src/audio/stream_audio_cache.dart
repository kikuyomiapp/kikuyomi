/// Where the bytes of a streamed book are kept once they have been fetched.
///
/// §6.3 resolves a stream just before it is played, and the engine then fetches the file over the
/// network every time it needs a byte of it. On a stream that means a seek is a new request, a
/// chapter played twice is downloaded twice, and closing the app throws away everything it had. A
/// cache under the engine turns all three into a read from a file on the device.
///
/// **It is not a download.** §5.2's downloads are the listener's, chosen book by book, kept until
/// they delete them and recorded in the database; Phase 3 owns them and the folder they live in.
/// This is the opposite: nobody asks for it, nothing in the database knows about it, and it is
/// thrown away when it gets too large or when the system wants the space back. So it lives in the
/// platform's cache folder, which is exactly the folder an OS is allowed to empty.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The cache folder, and the rules for what may stay in it.
final class StreamAudioCache {
  StreamAudioCache(this.folder, {this.maxBytes = 512 * 1024 * 1024});

  /// The folder the files are kept in. Created when the first file is asked for.
  final Directory folder;

  /// How much of it may be kept. What is over the limit goes, least recently used first.
  ///
  /// Half a gigabyte is a few hours of a book at LibriVox's bitrates: enough that moving about in
  /// the book being listened to never re-fetches anything, and small enough to be unremarkable
  /// beside the books themselves.
  final int maxBytes;

  /// Where file [fileId] of the library is kept when it is fetched from [uri].
  ///
  /// Named by the file's id *and* by where the bytes come from. The id alone would be enough if
  /// ids were never reused, but a row deleted by a restore or by taking a book out of the library
  /// frees its id for the next file, and serving one book's audio for another's is the one mistake
  /// a cache must not make. Only the host and the path are taken, never the query, so a source
  /// whose URLs carry a token that changes every time still finds what it fetched before.
  Future<File> fileFor({required int fileId, required Uri uri}) async {
    await folder.create(recursive: true);
    final origin = sha256
        .convert(utf8.encode('${uri.host}${uri.path}'))
        .toString()
        .substring(0, 16);
    return File('${folder.path}${Platform.pathSeparator}$fileId-$origin$_ext');
  }

  static const _ext = '.audio';

  /// Deletes the least recently used files until what is left fits in [maxBytes].
  ///
  /// A file still being fetched is left alone, whatever its age: its bytes are in a `.part` file
  /// beside it, and taking either away underneath the engine would stop playback. Failures are
  /// swallowed on purpose — a file another process is holding open is a reason to keep it, not a
  /// reason to fail whatever asked for the space.
  Future<void> prune() async {
    if (!await folder.exists()) return;
    final kept = <({File file, DateTime at, int bytes})>[];
    var total = 0;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith(_ext)) continue;
      if (await File('${entry.path}.part').exists()) continue;
      try {
        final stat = await entry.stat();
        kept.add((file: entry, at: stat.accessed, bytes: stat.size));
        total += stat.size;
      } on FileSystemException {
        continue;
      }
    }
    if (total <= maxBytes) return;
    kept.sort((a, b) => a.at.compareTo(b.at));
    for (final entry in kept) {
      if (total <= maxBytes) return;
      total -= entry.bytes;
      await _remove(entry.file);
    }
  }

  /// Empties the cache of everything not being fetched right now.
  Future<void> clear() async {
    if (!await folder.exists()) return;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith(_ext)) continue;
      if (await File('${entry.path}.part').exists()) continue;
      await _remove(entry);
    }
  }

  /// A cached file and the note of its media type that `just_audio` keeps beside it.
  static Future<void> _remove(File file) async {
    for (final path in [file.path, '${file.path}.mime']) {
      try {
        final beside = File(path);
        if (await beside.exists()) await beside.delete();
      } on FileSystemException {
        // Held open by something else. It will be offered again the next time.
      }
    }
  }
}
