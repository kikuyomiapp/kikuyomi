import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player_screen.dart';
import 'providers.dart';

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
