// A book's chapters. Their keys are identities the app matches on when a book is refreshed (§4.4),
// and their order is the book's order, so both are held tightly.

import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Map<String, Object?> chapter({
    String key = 'c1',
    String title = 'Loomings',
    Map<String, Object?> and = const {},
  }) => {'key': key, 'title': title, ...and};

  final released = DateTime.utc(2026, 3, 14, 9, 30);

  test('reads chapters in the order the source lists them', () {
    final chapters = decoder.decodeChapters([
      chapter(and: {'durationMs': 930000, 'group': 'Part One'}),
      chapter(
        key: 'c2',
        title: 'The Carpet-Bag',
        and: {'publishedAt': released.millisecondsSinceEpoch},
      ),
    ]);

    expect(chapters, [
      const ChapterInfo(
        key: 'c1',
        title: 'Loomings',
        durationMs: 930000,
        group: 'Part One',
      ),
      ChapterInfo(key: 'c2', title: 'The Carpet-Bag', publishedAt: released),
    ]);
    expect(chapters[1].publishedAt!.isUtc, isTrue);
  });

  test('takes a book with no chapters yet, as a serial before its first', () {
    expect(decoder.decodeChapters(<Object?>[]), isEmpty);
  });

  test('refuses two chapters sharing a key, which would make progress land on one of them', () {
    expect(
      () => decoder.decodeChapters([
        chapter(),
        chapter(key: 'c2'),
        chapter(title: 'Loomings (again)'),
      ]),
      rejects('chapters[2].key', 'repeats the key of chapters[0]'),
    );
  });

  test('holds 20,000 chapters, and refuses 20,001', () {
    List<Object?> chapters(int count) => [
      for (var i = 0; i < count; i++) chapter(key: 'c$i'),
    ];
    expect(decoder.decodeChapters(chapters(20000)), hasLength(20000));
    expect(
      () => decoder.decodeChapters(chapters(20001)),
      rejects('chapters', 'at most 20,000'),
    );
  });

  test('holds a key of 512 characters, and refuses 513', () {
    expect(
      decoder.decodeChapters([chapter(key: text(512))]).single.key,
      hasLength(512),
    );
    expect(
      () => decoder.decodeChapters([chapter(key: text(513))]),
      rejects('chapters[0].key', 'longer than 512 characters'),
    );
  });

  test('refuses a chapter with no key or no title', () {
    expect(
      () => decoder.decodeChapters([
        {'title': 'Loomings'},
      ]),
      rejects('chapters[0].key'),
    );
    expect(
      () => decoder.decodeChapters([
        {'key': 'c1'},
      ]),
      rejects('chapters[0].title'),
    );
    expect(
      () => decoder.decodeChapters([chapter(key: '')]),
      rejects('chapters[0].key', 'is empty'),
    );
    expect(
      () => decoder.decodeChapters([chapter(title: '   ')]),
      rejects('chapters[0].title', 'is empty'),
    );
  });

  test('refuses anything but an array of chapters', () {
    expect(
      () => decoder.decodeChapters({'chapters': []}),
      rejects('chapters', 'expected an array'),
    );
    expect(
      () => decoder.decodeChapters(null),
      rejects('chapters', 'got nothing'),
    );
    expect(
      () => decoder.decodeChapters(['c1']),
      rejects('chapters[0]', 'expected an object'),
    );
  });

  test('reads a duration the source does not have as unknown rather than as no time at all', () {
    expect(
      decoder
          .decodeChapters([
            chapter(and: {'durationMs': 0}),
          ])
          .single
          .durationMs,
      isNull,
    );
    expect(decoder.decodeChapters([chapter()]).single.durationMs, isNull);
  });

  test('refuses a duration that is not a whole number of milliseconds', () {
    for (final duration in [
      1500.5,
      double.nan,
      double.infinity,
      -1,
      '930000',
    ]) {
      expect(
        () => decoder.decodeChapters([
          chapter(and: {'durationMs': duration}),
        ]),
        rejects('chapters[0].durationMs'),
        reason: '$duration',
      );
    }
  });

  test('takes a duration written as a whole double, as JavaScript writes every number', () {
    expect(
      decoder
          .decodeChapters([
            chapter(and: {'durationMs': 930000.0}),
          ])
          .single
          .durationMs,
      930000,
    );
  });

  test('refuses a published time outside the range a date can hold', () {
    expect(
      () => decoder.decodeChapters([
        chapter(and: {'publishedAt': 8640000000000001}),
      ]),
      rejects('chapters[0].publishedAt', 'is not a time'),
    );
  });

  test('folds a title written across lines into one line', () {
    expect(
      decoder
          .decodeChapters([chapter(title: '  Chapter 1:\n\tLoomings  ')])
          .single
          .title,
      'Chapter 1: Loomings',
    );
  });

  test('refuses a control character in a title or a key', () {
    expect(
      () => decoder.decodeChapters([chapter(title: 'Loomings\u0000')]),
      rejects('chapters[0].title', 'control character (U+0000)'),
    );
    expect(
      () => decoder.decodeChapters([chapter(key: 'c\n1')]),
      rejects('chapters[0].key', 'control character (U+000A)'),
    );
  });

  test('keeps a key exactly as the source wrote it, spaces and all', () {
    // Trimming a key would make the app's identity for a chapter differ from the source's.
    expect(decoder.decodeChapters([chapter(key: ' c1 ')]).single.key, ' c1 ');
  });
}
