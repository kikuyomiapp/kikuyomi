import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import 'restore_session.dart';
import 'restore_view.dart';
import 'routes.dart';

/// Restoring from a backup, from Settings. Reached through [RestoreRoute].
class RestoreScreen extends ConsumerStatefulWidget {
  const RestoreScreen({super.key});

  @override
  ConsumerState<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends ConsumerState<RestoreScreen> {
  late final RestoreSession _session;

  @override
  void initState() {
    super.initState();
    _session = newRestoreSession(ref);
    unawaited(_session.start());
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Restore from a backup')),
    body: ListenableBuilder(
      listenable: _session,
      builder: (context, _) => RestoreView(
        step: _session.step,
        onChooseFolder: _session.chooseFolder,
        onRestore: _session.restore,
        onBackToBackups: _session.backToBackups,
        onDone: () {
          // A screen opened straight at its location may have nothing beneath it to return to.
          if (context.canPop()) {
            context.pop();
          } else {
            const HomeRoute().go(context);
          }
        },
      ),
    ),
  );
}

/// A restore session over the app's backups, which settles the library once a restore succeeds as
/// start does: new books in the import folder added, and covers looked for.
RestoreSession newRestoreSession(WidgetRef ref) {
  final services = ref.read(servicesProvider);
  return RestoreSession(
    backups: services.backups,
    afterRestore: () => services.settleRestoredLibrary(
      onError: (error, stack) => FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'kikuyomi',
          context: ErrorDescription('while settling a restored library'),
        ),
      ),
    ),
  );
}
