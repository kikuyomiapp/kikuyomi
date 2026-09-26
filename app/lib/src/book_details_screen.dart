import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart'
    show removeBookFromLibrary, watchBookDownloads;

import 'book_details_view.dart';
import 'downloads/book_downloads.dart';
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
    final downloads =
        ref.watch(bookDownloadsProvider(bookId)).value ?? BookDownloads.none;
    final book = overview.value;
    return Scaffold(
      appBar: AppBar(),
      // The one thing every visit is for, kept where a thumb reaches it rather than in a row of
      // outlined buttons where it looked like one option among four.
      floatingActionButton: book == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => openBookInPlayer(
                context,
                ref,
                bookId,
                fromStart: playButtonFrom(book) == PlayFrom.start,
              ),
              icon: const Icon(Icons.play_arrow),
              label: Text(playButtonLabel(book)),
            ),
      body: overview.when(
        data: (book) => book == null
            ? const Center(child: Text('This book is no longer available'))
            : BookDetailsView(
                book: book,
                covers: ref.watch(servicesProvider).covers,
                onRemove: () => _remove(context, ref, book.title),
                onOpenAtSource: book.webUrl == null
                    ? null
                    : () => _openAtSource(context, book.webUrl!),
                listenedCommands: _listenedCommands(
                  ref.watch(servicesProvider),
                ),
                downloads: downloads,
                onDownload: () => _download(context, ref),
                onStopDownloading: () => _stopDownloading(ref),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not load the book: $error')),
      ),
    );
  }

  /// Opens the book's page at its source in a browser.
  ///
  /// Outside the app rather than in a view of our own: §3.4 lets a source hand back any page it
  /// likes, and the browser is where a listener already trusts their sign-ins and their blocker.
  Future<void> _openAtSource(BuildContext context, String webUrl) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = Uri.tryParse(webUrl);
    if (url == null ||
        !await launchUrl(url, mode: LaunchMode.externalApplication)) {
      tellInSnackBar(messenger, 'That page could not be opened.');
    }
  }

  /// Asks for every file of the book that is not already here, and says what that came to.
  ///
  /// A book whose files are all on the device already — a local one, or one downloaded before — is
  /// worth saying so about rather than leaving the button to do nothing.
  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final asked = await ref.read(servicesProvider).downloadBook(bookId);
      if (asked.added > 0) {
        tellInSnackBar(
          messenger,
          asked.added == 1
              ? 'Downloading one file'
              : 'Downloading ${asked.added} files',
        );
      } else if (asked.alreadyOnDevice == asked.total && asked.total > 0) {
        tellInSnackBar(messenger, 'Every file is already on this device');
      } else {
        tellInSnackBar(messenger, 'Already downloading');
      }
    } catch (error) {
      tellInSnackBar(messenger, 'Could not start the download: $error');
    }
  }

  /// Gives up on whatever of this book is queued or running.
  Future<void> _stopDownloading(WidgetRef ref) async {
    final services = ref.read(servicesProvider);
    final tasks = await watchBookDownloads(services.database, bookId).first;
    for (final task in tasks) {
      if (!task.state.isFinished) await services.cancelDownload(task.id);
    }
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
