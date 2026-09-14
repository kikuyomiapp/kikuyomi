import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'book_details_screen.dart';
import 'home_view.dart';
import 'open_book.dart';
import 'providers.dart';

/// The files "Add book" offers.
///
/// Each platform's picker filters by its own kind of type. Windows and Android go by extension.
/// iOS goes by uniform type identifier, and refuses a group that lists none. Apple types the .m4b
/// extension as com.apple.protected-mpeg-4-audio, a name it gives audiobooks in general whether or
/// not a file is protected, so that type is listed beside audio and MPEG-4 files at large.
const _audiobooks = XTypeGroup(
  label: 'Audiobooks',
  extensions: ['m4b', 'm4a', 'mp4', 'mp3'],
  uniformTypeIdentifiers: [
    'public.audio',
    'public.mpeg-4',
    'com.apple.protected-mpeg-4-audio',
  ],
);

enum _Adding { file, folder }

/// The app's home: the books to continue listening to, above the library, and where books are
/// added.
///
/// §2.6's adaptive shell will split this into Home and Library tabs. Until that shell exists, this
/// one screen is both.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final continueListening = ref.watch(continueListeningProvider);
    final services = ref.watch(servicesProvider);
    final locations = services.locations;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kikuyomi'),
        actions: [
          if (locations.importFolderIsVisible)
            IconButton(
              tooltip: 'Look for new books in the Import folder',
              icon: const Icon(Icons.refresh),
              onPressed: () => _lookForNewBooks(context, ref),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addBook(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add book'),
      ),
      body: library.when(
        data: (books) => HomeView(
          // The library does not wait for Continue Listening; the shelf fills in when it arrives.
          continueListening: continueListening.value ?? const [],
          library: books,
          covers: services.covers,
          emptyMessage: locations.importFolderIsVisible
              ? 'No books yet. Add an audiobook file, or copy books into the '
                    'Import folder under Kikuyomi in the Files app.'
              : locations.canPickFolders
              ? 'No books yet. Add an audiobook file, or a folder of audio '
                    'files, to start listening.'
              : 'No books yet. Add an audiobook file to start listening.',
          onResume: (bookId) => openBookInPlayer(context, ref, bookId),
          onShowDetails: (bookId) =>
              Navigator.of(context).push(BookDetailsScreen.route(bookId)),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not load the library: $error')),
      ),
    );
  }

  Future<void> _addBook(BuildContext context, WidgetRef ref) async {
    final services = ref.read(servicesProvider);
    final adding = services.locations.canPickFolders
        ? await _askWhatToAdd(context)
        : _Adding.file;
    if (adding == null || !context.mounted) return;
    // The pickers themselves can fail, as the iOS one did before its type group had type
    // identifiers, so they sit inside the handler too. Otherwise the button would silently do
    // nothing.
    try {
      switch (adding) {
        case _Adding.file:
          final file = await openFile(acceptedTypeGroups: const [_audiobooks]);
          if (file == null) return;
          await services.addPickedBook(file.path);
        case _Adding.folder:
          final path = await getDirectoryPath();
          if (path == null) return;
          final added = await services.addFolderBook(path);
          if (added.unreadable.isNotEmpty && context.mounted) {
            _tell(
              context,
              'Added, leaving out files it could not read: '
              '${added.unreadable.join(', ')}',
            );
          }
      }
    } catch (error) {
      if (context.mounted) _tell(context, 'Could not add the book: $error');
    }
  }

  Future<_Adding?> _askWhatToAdd(BuildContext context) =>
      showModalBottomSheet<_Adding>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.audio_file_outlined),
                title: const Text('An audiobook file'),
                subtitle: const Text('An M4B, M4A or MP3 file'),
                onTap: () => Navigator.pop(context, _Adding.file),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('A folder of audio files'),
                subtitle: const Text('Each file becomes a chapter'),
                onTap: () => Navigator.pop(context, _Adding.folder),
              ),
            ],
          ),
        ),
      );

  Future<void> _lookForNewBooks(BuildContext context, WidgetRef ref) async {
    try {
      final added = await ref.read(servicesProvider).scanImportFolder();
      if (context.mounted) {
        _tell(context, switch (added) {
          0 => 'No new books in the Import folder',
          1 => 'Added a book from the Import folder',
          _ => 'Added $added books from the Import folder',
        });
      }
    } catch (error) {
      if (context.mounted) {
        _tell(context, 'Could not look for new books: $error');
      }
    }
  }
}

void _tell(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
