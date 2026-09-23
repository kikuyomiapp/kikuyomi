import 'package:flutter_test/flutter_test.dart';
import 'package:kikuyomi/src/sources/source_books_controller.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:kikuyomi_test_support/kikuyomi_test_support.dart';

PageResult<BookSummary> page(List<String> keys, {bool more = false}) =>
    PageResult(
      items: [
        for (final key in keys) BookSummary(key: key, title: 'Book $key'),
      ],
      hasNextPage: more,
    );

void main() {
  test('asks for one page at a time, in order', () async {
    final source = FakeContentSource(
      pages: {
        1: page(['a', 'b'], more: true),
        2: page(['c']),
      },
    );
    final controller = SourceBooksController(source.getPopular);

    await controller.loadMore();
    expect(controller.books.map((b) => b.key), ['a', 'b']);
    expect(controller.hasNextPage, isTrue);

    await controller.loadMore();
    expect(controller.books.map((b) => b.key), ['a', 'b', 'c']);
    expect(controller.hasNextPage, isFalse);
    expect(source.calls, ['getPopular(1)', 'getPopular(2)']);
  });

  test('never asks for more once the source says there is none', () async {
    final source = FakeContentSource(
      pages: {
        1: page(['a']),
      },
    );
    final controller = SourceBooksController(source.getPopular);

    await controller.loadMore();
    await controller.loadMore();
    await controller.loadMore();

    expect(source.calls, ['getPopular(1)']);
  });

  test('a fast scroll does not start five requests', () async {
    final source = FakeContentSource(
      pages: {
        1: page(['a'], more: true),
        2: page(['b']),
      },
      delay: const Duration(milliseconds: 20),
    );
    final controller = SourceBooksController(source.getPopular);

    final first = controller.loadMore();
    controller.loadMore();
    controller.loadMore();
    await first;

    expect(source.calls, ['getPopular(1)']);
  });

  test('a book listed on two pages is kept once', () async {
    // The contract only drops a repeat within one page. A grid that shows the same book twice looks
    // like a bug in the app, so the rest is dropped here.
    final source = FakeContentSource(
      pages: {
        1: page(['a', 'b'], more: true),
        2: page(['b', 'c']),
      },
    );
    final controller = SourceBooksController(source.getPopular);

    await controller.loadMore();
    await controller.loadMore();

    expect(controller.books.map((b) => b.key), ['a', 'b', 'c']);
  });

  test('a failure keeps the books that arrived and stops asking', () async {
    var failing = false;
    final source = FakeContentSource(
      pages: {
        1: page(['a'], more: true),
      },
    );
    final controller = SourceBooksController((page) async {
      if (failing) throw const NetworkException('no route to host');
      return source.getPopular(page);
    });

    await controller.loadMore();
    failing = true;
    await controller.loadMore();
    await controller.loadMore();

    expect(controller.books.map((b) => b.key), ['a']);
    expect(controller.error, isA<NetworkException>());
  });

  test('retrying asks for the page that failed again', () async {
    var attempts = 0;
    final controller = SourceBooksController((page) async {
      attempts++;
      if (attempts == 1) throw const RateLimitedException();
      return page == 1 ? Future.value(_first) : Future.value(_empty);
    });

    await controller.loadMore();
    expect(controller.error, isA<RateLimitedException>());

    await controller.retry();

    expect(controller.error, isNull);
    expect(controller.books.map((b) => b.key), ['a']);
    expect(attempts, 2);
  });

  test('an answer with no books at all is empty rather than loading', () async {
    final controller = SourceBooksController(
      FakeContentSource(pages: const {}).getPopular,
    );

    expect(controller.isEmpty, isFalse, reason: 'nothing has been asked yet');
    await controller.loadMore();

    expect(controller.isEmpty, isTrue);
    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
  });

  test('nothing is touched after it has been disposed', () async {
    final controller = SourceBooksController(
      FakeContentSource(
        pages: {
          1: page(['a']),
        },
        delay: const Duration(milliseconds: 20),
      ).getPopular,
    );

    final loading = controller.loadMore();
    controller.dispose();
    await loading;

    expect(controller.books, isEmpty);
  });
}

final _first = page(['a']);
final _empty = page(const []);
