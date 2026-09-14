import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'routes.dart';

/// Opens book [bookId] in the player and shows the player screen.
///
/// The book resumes where it was left, with smart rewind applied. With [fromStart] it plays from
/// the beginning instead, which is what a finished book needs: resuming one would land a few
/// seconds from its end.
///
/// A book that cannot be opened is reported in a snack bar, so a tap never silently does nothing.
Future<void> openBookInPlayer(
  BuildContext context,
  WidgetRef ref,
  int bookId, {
  bool fromStart = false,
}) async {
  final services = ref.read(servicesProvider);
  try {
    await services.openBook(bookId);
    if (fromStart) await services.coordinator.seekTo(0);
    if (context.mounted) {
      await const PlayerRoute().push<void>(context);
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the book: $error')),
      );
    }
  }
}
