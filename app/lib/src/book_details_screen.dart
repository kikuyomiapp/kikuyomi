import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show removeBookFromLibrary;

import 'book_details_view.dart';
import 'open_book.dart';
import 'providers.dart';

/// A book's details, watched from the database, so progress saved while the book plays shows here
/// on returning from the player without anything being refreshed.
class BookDetailsScreen extends ConsumerWidget {
  const BookDetailsScreen({super.key, required this.bookId});

  static Route<void> route(int bookId) =>
      MaterialPageRoute(builder: (_) => BookDetailsScreen(bookId: bookId));

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
                onPlay: (from) => openBookInPlayer(
                  context,
                  ref,
                  bookId,
                  fromStart: from == PlayFrom.start,
                ),
                onRemove: () => _remove(context, ref, book.title),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not load the book: $error')),
      ),
    );
  }

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
      messenger.showSnackBar(
        SnackBar(content: Text('Removed $title from the library')),
      );
      if (context.mounted) Navigator.of(context).pop();
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not remove the book: $error')),
      );
    }
  }
}
