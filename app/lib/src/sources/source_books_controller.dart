import 'package:flutter/foundation.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

/// One page of a source's books, as `getPopular` or `search` gives it.
typedef SourcePageLoader = Future<PageResult<BookSummary>> Function(int page);

/// A list of a source's books that grows as the listener scrolls.
///
/// Pages are numbered from 1 and asked for one at a time; a page is never asked for twice, and
/// nothing is asked for while a page is in flight, so a fast scroll cannot start five requests at a
/// site that only wanted one.
///
/// A failure stops the list where it is and is kept, rather than being thrown away: the screen shows
/// what arrived and says why there is no more, and [retry] asks for the same page again. That is
/// what "no silent empty screens" means for a list that is half full.
///
/// A plain [ChangeNotifier] rather than a provider, so the paging rules can be tested without a
/// widget, a container or a database.
final class SourceBooksController extends ChangeNotifier {
  SourceBooksController(this._load);

  final SourcePageLoader _load;

  final _books = <BookSummary>[];
  final _keys = <String>{};

  /// What has arrived so far, in the order the source gave it.
  List<BookSummary> get books => List.unmodifiable(_books);

  var _page = 0;
  var _hasNextPage = true;
  var _loading = false;
  Object? _error;
  var _disposed = false;

  /// Whether a page is on its way.
  bool get isLoading => _loading;

  /// Whether the source says there may be more.
  bool get hasNextPage => _hasNextPage;

  /// What stopped the list, or null. Read with `describeSourceProblem`.
  Object? get error => _error;

  /// True once the source has answered with nothing at all.
  bool get isEmpty =>
      _books.isEmpty && !_loading && _error == null && _page > 0;

  /// Whether the first page is still on its way, which is the only time a screen shows nothing but a
  /// spinner.
  bool get isLoadingFirstPage => _loading && _books.isEmpty;

  /// Asks for the next page, if there is one and nothing else is in flight.
  Future<void> loadMore() async {
    if (_loading || !_hasNextPage || _error != null || _disposed) return;
    _loading = true;
    notifyListeners();
    final page = _page + 1;
    try {
      final result = await _load(page);
      if (_disposed) return;
      _page = page;
      _hasNextPage = result.hasNextPage;
      for (final book in result.items) {
        // A book a source lists on two pages is kept once: the contract only drops repeats within
        // one page, and a grid that shows the same book twice looks like a bug in the app.
        if (_keys.add(book.key)) _books.add(book);
      }
    } catch (error) {
      if (_disposed) return;
      _error = error;
    } finally {
      if (!_disposed) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Asks for the page that failed again.
  Future<void> retry() async {
    if (_disposed) return;
    _error = null;
    notifyListeners();
    await loadMore();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
