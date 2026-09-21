import 'package:flutter/material.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show BookmarkOverview;

import 'format.dart';

/// A book's bookmarks, each with its name, where it is and the start of its note, and a menu to
/// rename it, write its note or delete it.
///
/// Pure, like the chapter list beside it: it reports what was picked and leaves seeking and changing
/// bookmarks to the caller.
///
/// A bookmark with no place in the book being played, because its chapter was removed from the book
/// or cannot be played yet, is listed where its chapter was and says why, but cannot be picked. Its
/// menu still works, so it can be kept for its note or deleted.
class BookmarkList extends StatelessWidget {
  const BookmarkList({
    super.key,
    required this.bookmarks,
    required this.onSeek,
    required this.onRename,
    required this.onEditNote,
    required this.onDelete,
  });

  /// In playing order.
  final List<BookmarkOverview> bookmarks;

  /// A seek to the bookmark picked, in book-global time.
  final ValueChanged<int> onSeek;

  final ValueChanged<BookmarkOverview> onRename;
  final ValueChanged<BookmarkOverview> onEditNote;
  final ValueChanged<BookmarkOverview> onDelete;

  @override
  Widget build(BuildContext context) {
    if (bookmarks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Text(
          'No bookmarks yet. Add one with the bookmark button to come back '
          'to this place later.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      // Sized to its rows when there are few, under the switch to the chapters.
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: bookmarks.length,
      itemBuilder: (context, index) {
        final bookmark = bookmarks[index];
        return _BookmarkRow(
          bookmark: bookmark,
          onSeek: onSeek,
          onChosen: (action) => switch (action) {
            _RowAction.rename => onRename(bookmark),
            _RowAction.note => onEditNote(bookmark),
            _RowAction.delete => onDelete(bookmark),
          },
        );
      },
    );
  }
}

enum _RowAction { rename, note, delete }

class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({
    required this.bookmark,
    required this.onSeek,
    required this.onChosen,
  });

  final BookmarkOverview bookmark;
  final ValueChanged<int> onSeek;
  final ValueChanged<_RowAction> onChosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final global = bookmark.globalPositionMs;
    final title = bookmark.title;
    final note = bookmark.note;
    // A bookmark with no name of its own goes by its chapter's.
    final name = title ?? bookmark.chapterTitle;
    final where = [
      if (global != null)
        formatClock(global)
      else
        '${formatClock(bookmark.chapterPositionMs)} into the chapter',
      if (title != null) bookmark.chapterTitle,
      if (bookmark.removedFromSource)
        'Chapter removed from the book'
      else if (global == null)
        'Cannot be played yet',
    ].join(' · ');

    return Tooltip(
      message: switch (global) {
        final ms? => 'Go to ${formatClock(ms)}',
        null when bookmark.removedFromSource =>
          'Its chapter is no longer in the book',
        null => 'Its chapter cannot be played yet',
      },
      child: ListTile(
        // Marked by an icon as well as in words, and the icon's meaning is in the words, so it is left
        // out of what a screen reader reads.
        leading: bookmark.removedFromSource
            ? Icon(Icons.error_outline, color: theme.colorScheme.error)
            : Icon(
                Icons.bookmark_outline,
                color: global == null ? theme.disabledColor : null,
              ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(where, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (note != null)
              Text(
                note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
          ],
        ),
        isThreeLine: note != null,
        onTap: global == null ? null : () => onSeek(global),
        trailing: PopupMenuButton<_RowAction>(
          tooltip: 'Options for $name',
          onSelected: onChosen,
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _RowAction.rename,
              child: Text('Rename'),
            ),
            PopupMenuItem(
              value: _RowAction.note,
              child: Text(note == null ? 'Add note' : 'Edit note'),
            ),
            const PopupMenuItem(
              value: _RowAction.delete,
              child: Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }
}
