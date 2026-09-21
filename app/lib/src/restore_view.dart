import 'package:flutter/material.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';

import 'backup_text.dart';
import 'restore_session.dart';

/// Restoring from a backup, as the listener sees each step of a [RestoreSession].
///
/// Fed with data rather than watching providers, so it can be tested without a database.
class RestoreView extends StatelessWidget {
  const RestoreView({
    super.key,
    required this.step,
    required this.onChooseFolder,
    required this.onRestore,
    required this.onBackToBackups,
    required this.onDone,
    this.onStartFresh,
  });

  final RestoreStep step;
  final VoidCallback onChooseFolder;
  final ValueChanged<RestorableBackup> onRestore;
  final VoidCallback onBackToBackups;

  /// The restore is done, and the listener has read what it did.
  final VoidCallback onDone;

  /// Where restoring is optional, as at first start: going on without restoring.
  final VoidCallback? onStartFresh;

  /// Wider than this, the content stays at a readable measure in the middle of the window.
  static const _maxWidth = 640.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onStartFresh = this.onStartFresh;
    final startFresh = onStartFresh == null
        ? null
        : TextButton(
            onPressed: onStartFresh,
            child: const Text('Start without restoring'),
          );
    final content = switch (step) {
      RestoreChoosingFolder(:final problem) => _Message(
        icon: Icons.folder_open_outlined,
        title: 'Where are your backups?',
        lines: [
          'Choose the folder your Kikuyomi backups are in. Kikuyomi keeps '
              'backing up to it from then on.',
        ],
        problem: problem,
        actions: [
          FilledButton(
            onPressed: onChooseFolder,
            child: const Text('Choose folder'),
          ),
          ?startFresh,
        ],
      ),
      RestoreLooking(:final folderName) => _Waiting(
        'Looking for backups in $folderName',
      ),
      RestoreChoosingBackup(:final folderName, :final backups) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Backups in $folderName', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            backups.isEmpty
                ? 'There are no Kikuyomi backups in this folder.'
                : 'Choose one to restore. Newest first.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          for (final backup in backups) _BackupTile(backup, onRestore),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: onChooseFolder,
                child: const Text('Choose another folder'),
              ),
              ?startFresh,
            ],
          ),
        ],
      ),
      RestoreRestoring(:final backup) => _Waiting(
        'Restoring the backup from '
        '${formatBackupTime(context, backup.summary.info.createdAt)}',
      ),
      RestoreDone(:final report) => _Message(
        icon: Icons.check_circle_outline,
        title: 'Restored',
        lines: [
          ...describeRestore(report),
          if (report.backup.skipped.isNotEmpty)
            'Left out ${report.backup.skipped.length} '
                '${report.backup.skipped.length == 1 ? 'item' : 'items'} that '
                'could not be restored:',
        ],
        details: report.backup.skipped,
        actions: [FilledButton(onPressed: onDone, child: const Text('Done'))],
      ),
      RestoreFailed(:final reason) => _Message(
        icon: Icons.error_outline,
        title: 'Could not restore the backup',
        lines: ['Your library is as it was.'],
        problem: reason,
        actions: [
          FilledButton(
            onPressed: onBackToBackups,
            child: const Text('Back to the backups'),
          ),
        ],
      ),
    };
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: EdgeInsets.symmetric(
          horizontal: ((constraints.maxWidth - _maxWidth) / 2).clamp(
            16.0,
            double.infinity,
          ),
          vertical: 24,
        ),
        children: [content],
      ),
    );
  }
}

/// One backup in the list: restorable ones can be chosen, others say why not.
class _BackupTile extends StatelessWidget {
  const _BackupTile(this.backup, this.onRestore);

  final ListedBackup backup;
  final ValueChanged<RestorableBackup> onRestore;

  @override
  Widget build(BuildContext context) {
    final backup = this.backup;
    return switch (backup) {
      RestorableBackup(:final summary) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.backup_outlined),
        title: Text(formatBackupTime(context, summary.info.createdAt)),
        subtitle: Text(countBooks(summary.bookCount)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onRestore(backup),
      ),
      UnrestorableBackup(:final takenAt) => ListTile(
        contentPadding: EdgeInsets.zero,
        enabled: false,
        leading: const Icon(Icons.block),
        title: Text(formatBackupTime(context, takenAt)),
        subtitle: Text(
          backup.needsNewerApp
              ? 'Made by a newer version of Kikuyomi. Update the app to '
                    'restore it.'
              : 'Cannot be restored: ${backup.reason}',
        ),
      ),
    };
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: 48),
      const CircularProgressIndicator(),
      const SizedBox(height: 16),
      Text(text, textAlign: TextAlign.center),
    ],
  );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.lines,
    this.problem,
    this.details = const [],
    required this.actions,
  });

  final IconData icon;
  final String title;
  final List<String> lines;
  final String? problem;

  /// Smaller print below the lines, one item each.
  final List<String> details;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = this.problem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 48, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: theme.textTheme.bodyLarge),
          ),
        for (final detail in details)
          Text('• $detail', style: theme.textTheme.bodySmall),
        if (problem != null) ...[
          const SizedBox(height: 8),
          Text(problem, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 24),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }
}
