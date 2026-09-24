/// Whether what arrived is actually audio (§5.2's post-processor).
///
/// "The post-processor validates each completed file (status code, a content type that isn't HTML, a
/// plausible size, and a magic-byte check, because many sites return an HTML error page with a 200
/// status)."
///
/// That parenthesis is the whole reason this exists. A download that "succeeded" and left a 2 KB
/// error page on the device is worse than one that failed: the app would mark the chapter downloaded,
/// the listener would go offline trusting it, and the failure would surface as a player error on a
/// train with no signal. Checking costs a few bytes and a comparison.
///
/// What it is deliberately not: a parser. It reads the first few bytes and answers one question —
/// could this plausibly be an audio file? Working out the real duration, the real format and the
/// embedded chapters is `sources_builtin`'s job, once the file has been kept.
library;

/// What the check made of a finished file.
sealed class FileVerdict {
  const FileVerdict();
}

/// It looks like audio, and may be kept.
final class FileAccepted extends FileVerdict {
  const FileAccepted({this.format});

  /// What the first bytes say it is, or null when they say nothing recognisable.
  ///
  /// Only a hint. A container this does not know is still accepted, because refusing everything
  /// unfamiliar would break legitimate files for the sake of a check that was never meant to be a
  /// format whitelist.
  final String? format;

  @override
  String toString() => 'FileAccepted(${format ?? 'unrecognised container'})';
}

/// It is not audio, and keeping it would be worse than failing.
final class FileRefused extends FileVerdict {
  const FileRefused(this.reason);

  /// Why, as a sentence for the console and for a bug report.
  final String reason;

  @override
  String toString() => 'FileRefused($reason)';
}

/// The smallest a real audiobook file could be.
///
/// A second of the lowest bitrate anyone ships is a few kilobytes; an error page is a few hundred
/// bytes to a few kilobytes. The two overlap, which is why this is only the floor and the magic bytes
/// do the real work.
const _smallestPlausibleFile = 512;

/// Whether [head] — the first bytes of a finished download — is plausibly audio.
///
/// [sizeBytes] is the whole file, which the caller knows and this cannot see. [contentType] is what
/// the site said, when it said anything; it is believed when it condemns the file and never when it
/// vouches for one, because a site that serves an error page as `audio/mpeg` is exactly the case this
/// is here to catch.
FileVerdict checkDownloadedFile({
  required List<int> head,
  required int sizeBytes,
  String? contentType,
}) {
  if (sizeBytes <= 0) {
    return const FileRefused('the file is empty');
  }
  if (sizeBytes < _smallestPlausibleFile) {
    return FileRefused(
      'the file is $sizeBytes bytes, too small to be a recording',
    );
  }

  final declared = contentType?.split(';').first.trim().toLowerCase();
  if (declared != null && _isNotAudio(declared)) {
    return FileRefused('the site sent $declared, which is not audio');
  }

  final format = _formatOf(head);
  if (format != null) return FileAccepted(format: format);

  // No signature we know. Before accepting it, rule out the thing §5.2 warns about: a page. A site
  // that answers a download with HTML has not sent audio whatever its headers claim.
  final looksLikeText = _looksLikeMarkupOrJson(head);
  if (looksLikeText != null) {
    return FileRefused('the site sent $looksLikeText, not audio');
  }

  return const FileAccepted();
}

/// Content types that settle the question on their own.
bool _isNotAudio(String type) =>
    type == 'text/html' ||
    type == 'application/xhtml+xml' ||
    type == 'application/json' ||
    type == 'text/plain' ||
    type.startsWith('image/') ||
    type.startsWith('text/');

/// The container [head] begins with, or null when it is not one this knows.
String? _formatOf(List<int> head) {
  if (_startsWith(head, 'fLaC')) return 'flac';
  if (_startsWith(head, 'OggS')) return 'ogg';
  // MP4 and its audio-only relatives put a four-byte length first and `ftyp` second.
  if (head.length >= 8 && _startsWith(head, 'ftyp', from: 4)) return 'm4a';
  if (_startsWith(head, 'ID3')) return 'mp3';
  // A bare MP3 or an ADTS AAC stream begins with a frame sync: eleven set bits. The real format is
  // worked out by a proper reader later; all this has to know is that it is not a web page.
  if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
    return 'mp3';
  }
  return null;
}

/// What [head] looks like if it looks like text rather than a recording, or null.
String? _looksLikeMarkupOrJson(List<int> head) {
  final start = _asciiOf(head, 64).trimLeft().toLowerCase();
  if (start.isEmpty) return null;
  if (start.startsWith('<!doctype html') || start.startsWith('<html')) {
    return 'a web page';
  }
  if (start.startsWith('<?xml') || start.startsWith('<')) return 'a document';
  if (start.startsWith('{') || start.startsWith('[')) return 'a JSON answer';
  return null;
}

bool _startsWith(List<int> bytes, String ascii, {int from = 0}) {
  if (bytes.length < from + ascii.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[from + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

/// The first [take] bytes as ASCII, with anything outside it dropped.
String _asciiOf(List<int> bytes, int take) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes.length && i < take; i++) {
    final byte = bytes[i];
    if (byte >= 0x20 && byte < 0x7f) buffer.writeCharCode(byte);
    // A byte outside printable ASCII in the first few is itself a sign this is not text, and the
    // caller has already tried the signatures, so nothing is lost by skipping it.
  }
  return buffer.toString();
}
