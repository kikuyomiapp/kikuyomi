import 'package:flutter/material.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show BookmarkOverview;

import 'bookmark_text_dialog.dart';
import 'snack_bars.dart';

/// The changes to bookmarks the player asks for.
///
/// Whoever shows the player makes them: the player screen makes them in the database. The prompts
/// below only ask the listener and report back through these, so the player can be tested without a
/// database, as it is without a coordinator.
final class BookmarkCommands {
  const BookmarkCommands({
    required this.add,
    required this.rename,
    required this.setNote,
    required this.delete,
    required this.restore,
  });

  /// Adds a bookmark where playback is now and returns its id, or null when no book is ready.
  final Future<int?> Function() add;

  /// Names a bookmark, or with null or a blank name takes its name away.
  final Future<void> Function(int bookmarkId, String? title) rename;

  /// Replaces a bookmark's note, or with null or a blank note takes it away.
  final Future<void> Function(int bookmarkId, String? note) setNote;

  final Future<void> Function(BookmarkOverview bookmark) delete;

  /// Puts back a bookmark just deleted, as it was.
  final Future<void> Function(BookmarkOverview bookmark) restore;
}

/// Adds a bookmark where playback is, as the bookmark button and the B key both do, and says so in a
/// snack bar whose action adds a note to it.
///
/// The snack bar replaces whatever snack bar is showing, so bookmarks added one after another are
/// confirmed one at a time rather than queueing up.
Future<void> addBookmarkHere(
  BuildContext context,
  BookmarkCommands commands,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final int? added;
  try {
    added = await commands.add();
  } catch (error) {
    tellInSnackBar(messenger, 'Could not add the bookmark: $error');
    return;
  }
  if (added == null || !context.mounted) return;
  final bookmarkId = added;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      offeringSnackBar(
        context,
        message: 'Bookmark added',
        action: 'Add note',
        onPressed: () {
          if (context.mounted) {
            promptBookmarkNote(
              context,
              commands,
              bookmarkId: bookmarkId,
              note: null,
            );
          }
        },
      ),
    );
}

/// Asks for a new name for [bookmark] and gives it that name.
Future<void> promptBookmarkName(
  BuildContext context,
  BookmarkCommands commands,
  BookmarkOverview bookmark,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final title = await showBookmarkTextDialog(
    context,
    heading: 'Rename bookmark',
    label: 'Name',
    initial: bookmark.title,
    // What the bookmark is called while it has no name of its own.
    hint: bookmark.chapterTitle,
  );
  if (title == null || title == (bookmark.title ?? '')) return;
  try {
    await commands.rename(bookmark.bookmarkId, title);
  } catch (error) {
    tellInSnackBar(messenger, 'Could not rename the bookmark: $error');
  }
}

/// Asks for a note for bookmark [bookmarkId], starting from its [note], and saves it.
Future<void> promptBookmarkNote(
  BuildContext context,
  BookmarkCommands commands, {
  required int bookmarkId,
  required String? note,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final entered = await showBookmarkTextDialog(
    context,
    heading: note == null ? 'Add note' : 'Edit note',
    label: 'Note',
    initial: note,
    multiline: true,
  );
  if (entered == null || entered == (note ?? '')) return;
  try {
    await commands.setNote(bookmarkId, entered);
  } catch (error) {
    tellInSnackBar(messenger, 'Could not save the note: $error');
  }
}

/// Deletes [bookmark] straight away, and offers to undo that in a snack bar, rather than asking
/// first: a bookmark is quick to lose and quick to put back.
Future<void> deleteBookmarkWithUndo(
  BuildContext context,
  BookmarkCommands commands,
  BookmarkOverview bookmark,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await commands.delete(bookmark);
  } catch (error) {
    tellInSnackBar(messenger, 'Could not delete the bookmark: $error');
    return;
  }
  if (!context.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      offeringSnackBar(
        context,
        message: 'Bookmark deleted',
        action: 'Undo',
        onPressed: () async {
          try {
            await commands.restore(bookmark);
          } catch (error) {
            if (messenger.mounted) {
              tellInSnackBar(
                messenger,
                'Could not put the bookmark back: $error',
              );
            }
          }
        },
      ),
    );
}
