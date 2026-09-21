/// Books dropped onto the window on desktop (§2.6, §3.10): what each dropped path is, adding the
/// books among them, and the one message that tells the listener how it went.
///
/// Plain Dart with no plugin, widget or database in it, so it can be tested on its own. The adding
/// itself is handed in, and it is the adding the "Add book" button does.
library;

import 'dart:io';

import 'package:kikuyomi_domain/kikuyomi_domain.dart'
    show UnplayableFormatException;
import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart'
    show audioExtensions;

import 'book_files.dart';

/// A path dropped onto the window, sorted by what it is.
sealed class DroppedItem {
  const DroppedItem(this.path);

  /// Where the item is, as the platform reported it.
  final String path;

  /// The item's own name, without the folders it is in, for telling the listener about it.
  String get name {
    final segments = path.split(RegExp(r'[\\/]'))
      ..removeWhere((segment) => segment.isEmpty);
    return segments.isEmpty ? path : segments.last;
  }
}

/// A file named as an audiobook file: added as a book of its own, where it is.
final class DroppedFile extends DroppedItem {
  const DroppedFile(super.path);
}

/// A folder: added as one book of the audio files in it, where they are.
final class DroppedFolder extends DroppedItem {
  const DroppedFolder(super.path);
}

/// Anything else, such as a text file, an image or a shortcut: never added.
final class UnsupportedItem extends DroppedItem {
  const UnsupportedItem(super.path);
}

/// Sorts dropped [paths] into audiobook files, folders and unsupported items, keeping their order.
///
/// A file goes by its extension, as the file dialog's filter does; whether it really holds audio
/// this app can read is found when it is added, which then says so. Links are followed, so a link to
/// a folder is a folder. A path that is not there is sorted by its name too: an audiobook file that
/// has gone is still worth reporting as not added.
Future<List<DroppedItem>> sortDropped(Iterable<String> paths) async => [
  for (final path in paths)
    if (await FileSystemEntity.isDirectory(path))
      DroppedFolder(path)
    else if (audioExtensions.contains(_extension(path)))
      DroppedFile(path)
    else
      UnsupportedItem(path),
];

/// What adding a dropped item made: the book's title as the library shows it, and any audio files
/// in a folder that were left out of its book.
typedef AddedBook = ({String title, LeftOut leftOut});

/// What became of one dropped item.
sealed class DropOutcome {
  const DropOutcome(this.item);

  final DroppedItem item;
}

/// The item was added as a book. A book already in the library counts too: adding it again finds
/// the same book, and puts it back if it had been taken out.
final class BookAdded extends DropOutcome {
  const BookAdded(
    super.item, {
    required this.title,
    this.leftOut = LeftOut.none,
  });

  /// The book's title, as the library shows it.
  final String title;

  /// The audio files in a folder that were left out of its book: those that could not be read, and
  /// those this device cannot play.
  final LeftOut leftOut;
}

/// Adding the item as a book failed.
final class BookNotAdded extends DropOutcome {
  const BookNotAdded(super.item, {required this.reason});

  /// Why, in words for the listener, such as "it holds no audio this app can read".
  final String reason;
}

/// The item is not something a book is added from.
final class ItemIgnored extends DropOutcome {
  const ItemIgnored(super.item);
}

/// Adds the books among [items], with [addFile] for an audiobook file and [addFolder] for a folder,
/// and returns what became of every item, in the same order.
///
/// Books are added one at a time, each once the one before has finished, so that a pile of books
/// dropped together is not read all at once. One that cannot be added is reported, and the rest
/// carry on.
Future<List<DropOutcome>> addDropped(
  List<DroppedItem> items, {
  required Future<AddedBook> Function(String path) addFile,
  required Future<AddedBook> Function(String path) addFolder,
}) async {
  final outcomes = <DropOutcome>[];
  for (final item in items) {
    final add = switch (item) {
      DroppedFile() => addFile,
      DroppedFolder() => addFolder,
      UnsupportedItem() => null,
    };
    if (add == null) {
      outcomes.add(ItemIgnored(item));
      continue;
    }
    try {
      final book = await add(item.path);
      outcomes.add(BookAdded(item, title: book.title, leftOut: book.leftOut));
    } catch (error) {
      outcomes.add(BookNotAdded(item, reason: _reason(item, error)));
    }
  }
  return outcomes;
}

/// The one message that tells the listener what became of everything dropped at once: the books
/// added, named when there is only one; the files left out of them, and why; what could not be
/// added and why; and what was ignored.
String summarizeDrop(List<DropOutcome> outcomes) {
  // Text dragged from a browser, say, drops no files at all.
  if (outcomes.isEmpty) return 'Only audiobook files and folders can be added';
  final added = outcomes.whereType<BookAdded>().toList();
  final ignored = outcomes.whereType<ItemIgnored>().toList();
  return [
    if (added case [final book])
      book.leftOut.isEmpty
          ? 'Added ${book.title}'
          : 'Added ${book.title}, leaving out ${book.leftOut.describe()}'
    else if (added.isNotEmpty) ...[
      'Added ${added.length} books',
      for (final book in added)
        if (!book.leftOut.isEmpty)
          'From ${book.title}, left out ${book.leftOut.describe()}',
    ],
    for (final outcome in outcomes.whereType<BookNotAdded>())
      'Could not add ${outcome.item.name}: ${outcome.reason}',
    if (ignored case [final outcome])
      'Ignored ${outcome.item.name}, which is not an audiobook file or folder'
    else if (ignored.isNotEmpty)
      'Ignored ${ignored.length} items that are not audiobook files or '
          'folders',
  ].join('. ');
}

/// Why adding [item] failed, in words for the listener rather than an exception's.
String _reason(DroppedItem item, Object error) => switch (error) {
  // A book in a format this device cannot play, which the message names.
  UnplayableFormatException(:final message) => message,
  // How the readers say a file is not the audio its name promised, and how adding a folder says it
  // found no audio in it.
  FormatException() when item is DroppedFolder =>
    'it holds no audio this app can read',
  FormatException() => 'it is not audio this app can read',
  PathNotFoundException() => 'it is no longer there',
  PathAccessException() => 'this app is not allowed to read it',
  FileSystemException() => 'it could not be read',
  _ => '$error',
};

String? _extension(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? null : path.substring(dot + 1).toLowerCase();
}
