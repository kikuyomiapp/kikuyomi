import 'package:flutter/material.dart';

/// A reminder at the top of the home, until a backup folder is chosen, of why one matters.
///
/// Fed with callbacks rather than reading providers, so it can be tested without a database.
class BackupReminderCard extends StatelessWidget {
  const BackupReminderCard({
    super.key,
    required this.onChooseFolder,
    required this.onNotNow,
  });

  final VoidCallback onChooseFolder;

  /// Hides the reminder until the app next starts.
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.backup_outlined,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Back up your library',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a folder for automatic backups, so your library and '
              'listening progress survive reinstalling the app.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 8,
                children: [
                  TextButton(onPressed: onNotNow, child: const Text('Not now')),
                  FilledButton.tonal(
                    onPressed: onChooseFolder,
                    child: const Text('Choose folder'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
