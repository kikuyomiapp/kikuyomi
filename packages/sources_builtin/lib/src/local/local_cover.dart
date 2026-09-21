/// Cover art for local books, read from the books' own files.
///
/// §3.10's Local source takes a single file as a book, and a folder of files as one, and either may
/// carry its cover: an image saved beside the audio, or a picture embedded in the audio itself. This
/// reads whichever the book has, for the library to keep (§5.1).
library;

import 'dart:io';

import 'embedded_picture.dart';
import 'local_audio.dart';
import 'mp4_chapters.dart';

/// Reads a local book's cover.
///
/// [image] is a cover image saved beside the book's audio, such as the one `findFolderCoverImage`
/// finds in a folder. It is taken when its bytes open as a JPEG, PNG, GIF or WebP image. Its name
/// alone is not trusted, because a folder picks its cover by name and a damaged or misnamed file
/// would otherwise hide a good embedded picture. Otherwise, or with no [image], the cover is the
/// picture embedded in [audio], the book's file or its first file, read as the format its extension
/// names, as [readLocalAudioInfo] and `readFolderBook` read files.
///
/// Returns null when neither gives a picture, which includes an [audio] file this package cannot
/// read as audio. Throws a [FileSystemException] when [audio] cannot be opened, as when it is
/// missing, so a caller can tell a book with no cover from one whose files are not there.
Future<EmbeddedPicture?> readLocalCover(File audio, {File? image}) async {
  if (image != null) {
    final picture = await _readImage(image);
    if (picture != null) return picture;
  }
  final source = await FileByteSource.open(audio);
  try {
    final info = await readLocalAudioInfo(
      source,
      extension: _extension(audio.path),
      withCover: true,
    );
    return info?.cover;
  } on FormatException {
    // A damaged file, whose picture cannot be found. It has no cover this can read.
    return null;
  } finally {
    await source.close();
  }
}

/// Reads [image] as a cover, or returns null when it is too large, not an image whose type its bytes
/// show, or no longer readable.
Future<EmbeddedPicture?> _readImage(File image) async {
  try {
    if (await image.length() > maxPictureBytes) return null;
    final bytes = await image.readAsBytes();
    final mimeType = pictureMimeType(bytes);
    return mimeType == null
        ? null
        : EmbeddedPicture(mimeType: mimeType, bytes: bytes);
  } on FileSystemException {
    // Gone or locked since it was found. The embedded picture may still serve.
    return null;
  }
}

/// The extension of the file at [path], or nothing when its name has none.
String _extension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1);
}
