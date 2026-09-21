import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'providers.dart';
import 'restore_screen.dart';
import 'restore_session.dart';
import 'restore_view.dart';
import 'routes.dart';

/// Backup setup, offered once when the app starts with an empty library (§5.1: restore on a fresh
/// install). Reached through [SetupRoute], by the router's redirect while [SetupGate] offers it.
class SetupScreen extends ConsumerWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(servicesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome to Kikuyomi'),
        automaticallyImplyLeading: false,
      ),
      body: SetupFlow(
        backups: services.backups,
        settings: services.settings,
        newSession: () => newRestoreSession(ref),
        onFinished: ref.read(setupGateProvider).finish,
      ),
    );
  }
}

/// The steps of backup setup: choose a folder, restore from one, or skip.
///
/// Given what it works with rather than reading providers, so that the whole flow can be tested
/// against fakes.
class SetupFlow extends StatefulWidget {
  const SetupFlow({
    super.key,
    required this.backups,
    required this.settings,
    required this.newSession,
    required this.onFinished,
  });

  final BackupService backups;
  final SettingsStore settings;

  /// A restore session, for restoring from a folder.
  final RestoreSession Function() newSession;

  /// Setup is done or skipped, and recorded as such.
  final VoidCallback onFinished;

  @override
  State<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<SetupFlow> {
  late final RestoreSession _session = widget.newSession();

  /// Whether the restore steps are showing, rather than the introduction.
  var _restoring = false;

  /// Why the folder chosen could not be used.
  String? _problem;

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  /// Chooses the folder backups go to. A folder that already holds backups is most likely one from
  /// before a reinstall, so its backups are offered for restoring before setup finishes.
  Future<void> _chooseFolder() async {
    setState(() => _problem = null);
    try {
      final folder = await widget.backups.chooseFolder();
      if (folder == null) return;
      await _session.showBackupsIn(folder);
      if (_session.step case RestoreChoosingBackup(:final backups)
          when backups.any((backup) => backup is RestorableBackup)) {
        if (mounted) setState(() => _restoring = true);
      } else {
        await _finish(BackupSetup.completed);
      }
    } on FolderException catch (error) {
      if (mounted) setState(() => _problem = error.message);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _problem = null;
      _restoring = true;
    });
    await _session.chooseFolder();
  }

  /// Going on without restoring: done, if a folder was chosen on the way, and otherwise back to the
  /// choices.
  Future<void> _startFresh() async {
    if (widget.backups.folder != null) {
      await _finish(BackupSetup.completed);
    } else {
      setState(() => _restoring = false);
    }
  }

  Future<void> _finish(BackupSetup setup) async {
    await widget.settings.write(AppSettings.backupSetup, setup);
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    if (!_restoring) {
      return SetupIntroView(
        problem: _problem,
        onChooseFolder: _chooseFolder,
        onRestore: _restore,
        onSkip: () => _finish(BackupSetup.skipped),
      );
    }
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) => RestoreView(
        step: _session.step,
        onChooseFolder: _session.chooseFolder,
        onRestore: _session.restore,
        onBackToBackups: _session.backToBackups,
        onDone: () => _finish(BackupSetup.completed),
        onStartFresh: _startFresh,
      ),
    );
  }
}

/// What setup offers: why backups matter, and the three ways on.
///
/// Fed with data rather than watching providers, so it can be tested without a database.
class SetupIntroView extends StatelessWidget {
  const SetupIntroView({
    super.key,
    this.problem,
    required this.onChooseFolder,
    required this.onRestore,
    required this.onSkip,
  });

  final String? problem;
  final VoidCallback onChooseFolder;
  final VoidCallback onRestore;
  final VoidCallback onSkip;

  static const _maxWidth = 560.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = this.problem;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: EdgeInsets.symmetric(
          horizontal: ((constraints.maxWidth - _maxWidth) / 2).clamp(
            24.0,
            double.infinity,
          ),
          vertical: 32,
        ),
        children: [
          Icon(
            Icons.backup_outlined,
            size: 64,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text('Keep your library safe', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(
            'Kikuyomi can back up your library and listening progress to a '
            'folder you choose, a few minutes after changes, so they survive '
            'reinstalling the app. Choose a folder outside the app, which '
            'reinstalling leaves alone.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Used Kikuyomi before? Restore from the folder your backups are '
            'in.',
            style: theme.textTheme.bodyLarge,
          ),
          if (problem != null) ...[
            const SizedBox(height: 12),
            Text(
              'Could not use that folder: $problem',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onChooseFolder,
            icon: const Icon(Icons.folder_outlined),
            label: const Text('Choose a backup folder'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onRestore,
            icon: const Icon(Icons.restore),
            label: const Text('Restore from a backup'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onSkip, child: const Text('Skip for now')),
        ],
      ),
    );
  }
}
