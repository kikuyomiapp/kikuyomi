import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show removeBookFromLibrary;

import 'book_details_view.dart';
import 'listened_commands.dart';
import 'open_book.dart';
import 'providers.dart';
import 'routes.dart';
import 'services.dart';
import 'snack_bars.dart';

/// A book's details, watched from the database, so progress saved while the book plays shows here
/// on returning from the player without anything being refreshed. Reached through [BookRoute].
class BookDetailsScreen extends ConsumerWidget {
  const BookDetailsScreen({super.key, required this.bookId});

  final int bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(bookOverviewProvider(bookId));
    return Scaffold(
      appBar: AppBar(),
      body: overview.when(
        data: (book) => book == null
            ? const Center(child: Text('This book is no longer available'))
            : BookDetailsView(
                book: book,
                covers: ref.watch(servicesProvider).covers,
                onPlay: (from) => openBookInPlayer(
                  context,
                  ref,
                  bookId,
                  fromStart: from == PlayFrom.start,
                ),
                onRemove: () => _remove(context, ref, book.title),
                listenedCommands: _listenedCommands(
                  ref.watch(servicesProvider),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not load the book: $error')),
      ),
    );
  }

  /// Marks made in the database through [AppServices], which tells the player too, so a book open
  /// there agrees about being finished. The details update by themselves, since they watch the
  /// database.
  ListenedCommands _listenedCommands(AppServices services) => ListenedCommands(
    markChapters: (chapterIds, listened) =>
        services.markChaptersListened(bookId, chapterIds, listened: listened),
    markFinished: () => services.markBookFinished(bookId),
    markNotFinished: () => services.markBookNotFinished(bookId),
  );

  /// Takes the book out of the library and leaves its details, since there is nothing more to do
  /// with it here. A book that is playing carries on playing.
  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    String title,
  ) async {
    final services = ref.read(servicesProvider);
    // The app's messenger outlives this screen, so the message survives leaving it.
    final messenger = ScaffoldMessenger.of(context);
    try {
      await removeBookFromLibrary(
        services.database,
        bookId,
        clock: services.clock,
      );
      tellInSnackBar(messenger, 'Removed $title from the library');
      if (context.mounted) {
        // A screen opened straight at its location may have nothing beneath it to return to.
        if (context.canPop()) {
          context.pop();
        } else {
          const HomeRoute().go(context);
        }
      }
    } catch (error) {
      tellInSnackBar(messenger, 'Could not remove the book: $error');
    }
  }
}
