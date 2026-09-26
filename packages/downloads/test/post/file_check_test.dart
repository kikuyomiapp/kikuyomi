// Whether what arrived is audio (§5.2's post-processor).
//
// The case this exists for is the one in the design's own parenthesis: a site that answers a download
// with an HTML error page and a 200 status. Keeping that file is worse than failing the download,
// because the app would mark the chapter downloaded and the listener would find out on a train.

import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';
import 'package:test/test.dart';

/// [ascii] followed by enough padding to pass the size floor.
List<int> beginning(String ascii, {int size = 4096}) => [
  ...ascii.codeUnits,
  ...List.filled(size - ascii.length, 0),
];

/// A file big enough to be real, whose first bytes are [head].
FileVerdict check(
  List<int> head, {
  int sizeBytes = 4 * 1024 * 1024,
  String? contentType,
}) => checkDownloadedFile(
  head: head,
  sizeBytes: sizeBytes,
  contentType: contentType,
);

String? refusalOf(FileVerdict verdict) =>
    verdict is FileRefused ? verdict.reason : null;

String? formatOf(FileVerdict verdict) =>
    verdict is FileAccepted ? verdict.format : null;

void main() {
  group('what audio looks like', () {
    test('an MP3 with a tag', () {
      expect(formatOf(check(beginning('ID3\u0003'))), 'mp3');
    });

    test('an MP3 with no tag, by its frame sync', () {
      expect(formatOf(check([0xFF, 0xFB, 0x90, 0x00])), 'mp3');
    });

    test('an M4B, whose ftyp comes after its length', () {
      expect(formatOf(check([0, 0, 0, 0x20, ...'ftypM4B '.codeUnits])), 'm4a');
    });

    test('a FLAC', () {
      expect(formatOf(check(beginning('fLaC'))), 'flac');
    });

    test('an Ogg', () {
      expect(formatOf(check(beginning('OggS'))), 'ogg');
    });

    test('a container this does not know is still kept', () {
      // Refusing everything unfamiliar would break legitimate files for the sake of a check that was
      // never meant to be a format whitelist. The real reader runs afterwards.
      final verdict = check([0x1A, 0x45, 0xDF, 0xA3, 0x99, 0x42]);

      expect(verdict, isA<FileAccepted>());
      expect(formatOf(verdict), isNull);
    });
  });

  group('what a site sends instead', () {
    test('an HTML error page with a 200 (§5.2)', () {
      final verdict = check(
        beginning('<!DOCTYPE html>\n<html><head><title>Not found'),
      );

      expect(refusalOf(verdict), contains('a web page'));
    });

    test('an HTML page that does not bother with a doctype', () {
      expect(
        refusalOf(check(beginning('<html lang="en"><body>Error'))),
        contains('a web page'),
      );
    });

    test('an XML or other document', () {
      expect(
        refusalOf(check(beginning('<?xml version="1.0"?><error/>'))),
        contains('a document'),
      );
    });

    test('a JSON answer', () {
      expect(
        refusalOf(check(beginning('{"error":"not authorised"}'))),
        contains('a JSON answer'),
      );
      expect(
        refusalOf(check(beginning('[{"message":"gone"}]'))),
        contains('a JSON answer'),
      );
    });

    test('leading whitespace does not disguise it', () {
      expect(
        refusalOf(check(beginning('\n\n   <!DOCTYPE html>'))),
        contains('a web page'),
      );
    });
  });

  group('what the site said it was sending', () {
    test('is believed when it condemns the file', () {
      expect(
        refusalOf(check(beginning('fLaC'), contentType: 'text/html')),
        contains('text/html'),
      );
    });

    test('is read without its charset', () {
      expect(
        refusalOf(
          check(beginning('x'), contentType: 'text/html; charset=utf-8'),
        ),
        contains('text/html'),
      );
    });

    test('is never believed when it vouches for one', () {
      // A site that serves an error page as audio/mpeg is exactly the case this is here to catch, so
      // a friendly content type does not get a file past the bytes.
      expect(
        refusalOf(
          check(beginning('<!DOCTYPE html><html>'), contentType: 'audio/mpeg'),
        ),
        contains('a web page'),
      );
    });

    test('is not needed at all', () {
      expect(check(beginning('fLaC')), isA<FileAccepted>());
    });
  });

  group('size', () {
    test('nothing at all is refused', () {
      expect(refusalOf(check(const [], sizeBytes: 0)), contains('empty'));
    });

    test('too small to be a recording is refused, and says how small', () {
      expect(
        refusalOf(check(beginning('fLaC', size: 100), sizeBytes: 100)),
        allOf(contains('100 bytes'), contains('too small')),
      );
    });

    test('a real file passes the floor', () {
      expect(
        check(beginning('fLaC'), sizeBytes: 512),
        isA<FileAccepted>(),
        reason: 'the floor is the smallest plausible file, not a minimum size',
      );
    });
  });

  test('a verdict says what it is, for the console', () {
    expect('${const FileAccepted(format: 'mp3')}', contains('mp3'));
    expect('${const FileAccepted()}', contains('unrecognised'));
    expect('${const FileRefused('a web page')}', contains('a web page'));
  });
}
