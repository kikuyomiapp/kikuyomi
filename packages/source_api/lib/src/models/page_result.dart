/// SourceAPI 1.0's `PageResult`: one page of a list the source serves a page at a time.
library;

import '../equality.dart';

/// One page of results. Pages are numbered from 1.
final class PageResult<T> {
  PageResult({required List<T> items, required this.hasNextPage})
    : items = List.unmodifiable(items);

  final List<T> items;

  /// Whether asking for the next page may give more.
  final bool hasNextPage;

  @override
  bool operator ==(Object other) =>
      other is PageResult<T> &&
      other.hasNextPage == hasNextPage &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(Object.hashAll(items), hasNextPage);

  @override
  String toString() =>
      'PageResult(${items.length} items${hasNextPage ? ', more' : ''})';
}
