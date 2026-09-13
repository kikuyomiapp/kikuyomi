import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'player_screen.dart';
import 'providers.dart';

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
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Audiobooks', extensions: ['m4b', 'm4a', 'mp4']),
      ],
    );
    if (file == null) return;
    try {
      await ref.read(servicesProvider).importM4b(file.path);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not import ${file.name}: $error')),
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
