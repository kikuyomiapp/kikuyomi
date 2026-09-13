import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'player_screen.dart';
import 'providers.dart';

/// The files "Add M4B" offers.
///
/// Each platform's picker filters by its own kind of type. Windows and Android go by extension.
/// iOS goes by uniform type identifier, and refuses a group that lists none. Apple types the .m4b
/// extension as com.apple.protected-mpeg-4-audio, a name it gives audiobooks in general whether or
/// not a file is protected, so that type is listed beside audio and MPEG-4 files at large.
const _audiobooks = XTypeGroup(
  label: 'Audiobooks',
  extensions: ['m4b', 'm4a', 'mp4'],
  uniformTypeIdentifiers: [
    'public.audio',
    'public.mpeg-4',
    'com.apple.protected-mpeg-4-audio',
  ],
);

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addBook(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add M4B'),
      ),
      body: library.when(
        data: (books) => books.isEmpty
            ? const Center(
                child: Text('No books yet. Add an M4B to start listening.'),
              )
            : ListView.builder(
                itemCount: books.length,
                itemBuilder: (context, index) {
                  final book = books[index];
                  return ListTile(
                    leading: const Icon(Icons.headphones),
                    title: Text(book.title),
                    subtitle: Text(formatClock(book.totalDurationMs ?? 0)),
                    onTap: () => _open(context, ref, book.id),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Could not load the library: $error')),
      ),
    );
  }

  Future<void> _addBook(BuildContext context, WidgetRef ref) async {
    // The picker itself can fail, as it did on iOS before the group had type identifiers, so it
    // sits inside the handler too. Otherwise the button would silently do nothing.
    try {
      final file = await openFile(acceptedTypeGroups: const [_audiobooks]);
      if (file == null) return;
      await ref.read(servicesProvider).addPickedBook(file.path);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add the book: $error')),
        );
      }
    }
  }

  Future<void> _open(BuildContext context, WidgetRef ref, int bookId) async {
    try {
      await ref.read(servicesProvider).openBook(bookId);
      if (context.mounted) {
        await Navigator.of(context).push(PlayerScreen.route());
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the book: $error')),
        );
      }
    }
  }
}
