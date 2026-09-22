// What every decoder test needs: an extension's declared domains, a decoder over them, and a
// matcher for the refusal an extension author would read in the console.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

/// The domains of the extension under test: one host, and everything under a CDN.
final domains = DomainAllowlist(['example.org', '*.cdn.example.org']);

/// A decoder for that extension.
final decoder = PlainDataDecoder(domains);

/// The call failed as `Parse`, with a message naming [path] and saying [problem].
Matcher rejects(String path, [String? problem]) => throwsA(
  isA<ParseException>().having(
    (error) => error.message,
    'message',
    problem == null
        ? startsWith('$path: ')
        : allOf(startsWith('$path: '), contains(problem)),
  ),
);

/// A string of [length] characters, for testing a limit at its boundary.
String text(int length, [String unit = 'a']) => unit * length;

/// The smallest book summary that is a book summary.
Map<String, Object?> summary({
  String key = 'b1',
  Object? title = 'Moby-Dick',
}) => {'key': key, 'title': title};

/// The smallest page that is a page.
Map<String, Object?> page(List<Object?> items, {bool hasNextPage = false}) => {
  'items': items,
  'hasNextPage': hasNextPage,
};

/// The smallest book details that are book details.
Map<String, Object?> details({Map<String, Object?> and = const {}}) => {
  'key': 'b1',
  'title': 'Moby-Dick',
  'authors': ['Herman Melville'],
  'narrators': ['Stewart Wills'],
  'genres': ['Fiction'],
  'status': 'complete',
  ...and,
};

/// The smallest request that is a request.
Map<String, Object?> request({
  String url = 'https://example.org/a.mp3',
  Map<String, Object?> and = const {},
}) => {'url': url, ...and};

/// The smallest segment that is a segment.
Map<String, Object?> segment({Map<String, Object?> and = const {}}) => {
  'fileKey': 'f1',
  'request': request(),
  ...and,
};

/// The smallest resolution that is a resolution.
Map<String, Object?> resolution({
  List<Object?>? segments,
  Map<String, Object?> and = const {},
}) => {
  'segments': segments ?? [segment()],
  ...and,
};
