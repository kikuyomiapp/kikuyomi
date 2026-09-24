/// Keeping a finished download, or refusing it (§5.2's post-processor).
///
/// The transport leaves bytes somewhere of its own choosing. This decides whether they are worth
/// keeping, gives them a name the app can find them by, and moves them into place. Only then is the
/// file written into `media_file.local_path`, which is what makes a chapter playable with no network
/// (§5.7) — so nothing may be recorded as downloaded until it is really here and really audio.
library;

import 'dart:io';

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'file_check.dart';

/// A finished download that will not be kept.
///
/// Thrown rather than returned because the driver treats it as a permanent failure: a file that is
/// not what it claimed to be will not become one by being fetched again from the same place.
final class DownloadRefused implements Exception {
  const DownloadRefused(this.reason);

  final String reason;

  @override
  String toString() => 'the download was refused: $reason';
}

/// Where kept downloads live, and what it takes to join them.
final class DownloadedFiles {
  const DownloadedFiles(this.root);

  /// The folder downloads are kept in. Every path this returns is relative to it, for the reason a
  /// cover's path is: on iOS the app's container moves when the app is updated or reinstalled, and an
  /// absolute path recorded today is wrong tomorrow.
  final Directory root;

  /// How much of a file is read to decide what it is. Enough for any signature, and small enough that
  /// checking costs nothing next to the download that produced it.
  static const headBytes = 64;

  /// Checks the file at [downloadedPath] and moves it into place, returning its path relative to
  /// [root].
  ///
  /// Throws [DownloadRefused] when it is not audio, having left the file alone for whoever wants to
  /// look at it; the transport's temporary directory is emptied by the platform.
  Future<String> keep(DownloadSubject subject, String downloadedPath) async {
    final downloaded = File(downloadedPath);
    if (!await downloaded.exists()) {
      throw const DownloadRefused(
        'the file the transport reported is not there',
      );
    }

    final size = await downloaded.length();
    final verdict = checkDownloadedFile(
      head: await _head(downloaded),
      sizeBytes: size,
    );
    if (verdict is FileRefused) throw DownloadRefused(verdict.reason);

    final extension =
        (verdict as FileAccepted).format ?? _extensionOf(downloadedPath);
    final relative = '${subject.bookId}/${subject.mediaFileId}.$extension';
    final target = File(
      '${root.path}$_slash${relative.replaceAll('/', _slash)}',
    );
    await target.parent.create(recursive: true);

    // A rename is atomic within a volume, which is what makes the file appear whole or not at all. The
    // transport may have written it somewhere else entirely — a cache on another mount, on desktop —
    // and then a rename fails and the bytes have to be copied.
    try {
      await downloaded.rename(target.path);
    } on FileSystemException {
      await downloaded.copy(target.path);
      try {
        await downloaded.delete();
      } on FileSystemException {
        // The copy is what matters. A temporary file left behind is the platform's to clear.
      }
    }
    return relative;
  }

  /// Deletes the file kept at [relativePath], and the book's folder once nothing is left in it.
  ///
  /// For §5.6's storage management, and for a download the listener throws away. Deleting what is not
  /// there is not a failure: the row and the file can disagree, and this is one of the places that
  /// settles it.
  Future<void> discard(String relativePath) async {
    final file = File(
      '${root.path}$_slash${relativePath.replaceAll('/', _slash)}',
    );
    if (await file.exists()) await file.delete();
    final folder = file.parent;
    if (await folder.exists() && await folder.list().isEmpty) {
      await folder.delete();
    }
  }

  /// What all the kept downloads come to, for the Downloads screen's total (§5.6).
  Future<int> totalBytes() async {
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  Future<List<int>> _head(File file) async {
    final handle = await file.open();
    try {
      return await handle.read(headBytes);
    } finally {
      await handle.close();
    }
  }

  /// The extension the transport's own name carried, or a plain one when it carried none.
  static String _extensionOf(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'audio';
    final extension = name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(extension) ? extension : 'audio';
  }
}

final _slash = Platform.pathSeparator;
