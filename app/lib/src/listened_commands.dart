import 'package:flutter/material.dart';

import 'snack_bars.dart';

/// The changes to a book's listened state (§4.5) its details ask for.
///
/// Whoever shows the details makes them: the details screen makes them through `AppServices`, which
/// also tells the player. The details only report back through these, so they can be tested without
/// a database.
final class ListenedCommands {
  const ListenedCommands({
    required this.markChapters,
    required this.markFinished,
    required this.markNotFinished,
  });

  /// Marks chapters listened, or not, and returns those whose state changed.
  final Future<Set<int>> Function(Set<int> chapterIds, bool listened)
  markChapters;

  /// Marks the whole book finished, and returns the chapters that were not listened, which are the
  /// ones to mark not listened again to undo it.
  final Future<Set<int>> Function() markFinished;

  /// Marks the book not finished: its last chapter not listened.
  final Future<void> Function() markNotFinished;
}

/// Marks chapter [chapterId] [listened], or not, and says so in a snack bar only if that fails: the
/// chapter's row shows the change.
Future<void> markChapterListened(
  BuildContext context,
  ListenedCommands commands, {
  required int chapterId,
  required bool listened,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await commands.markChapters({chapterId}, listened);
  } catch (error) {
    tellInSnackBar(messenger, 'Could not mark the chapter: $error');
  }
}

/// Marks the book finished straight away, and offers to undo that in a snack bar rather than asking
/// first. Undoing it marks not listened again exactly the chapters it marked, so each chapter goes
/// back to what it was.
Future<void> markBookFinishedWithUndo(
  BuildContext context,
  ListenedCommands commands,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final Set<int> marked;
  try {
    marked = await commands.markFinished();
  } catch (error) {
    tellInSnackBar(messenger, 'Could not mark the book finished: $error');
    return;
  }
  if (!context.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      offeringSnackBar(
        context,
        message: 'Marked as finished',
        action: 'Undo',
        onPressed: () async {
          try {
            await commands.markChapters(marked, false);
          } catch (error) {
            if (messenger.mounted) {
              tellInSnackBar(messenger, 'Could not undo that: $error');
            }
          }
        },
      ),
    );
}

/// Marks the book not finished, and says so in a snack bar only if that fails: the details show the
/// change.
Future<void> markBookNotFinished(
  BuildContext context,
  ListenedCommands commands,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await commands.markNotFinished();
  } catch (error) {
    tellInSnackBar(messenger, 'Could not mark the book not finished: $error');
  }
}
