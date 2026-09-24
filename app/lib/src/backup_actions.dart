import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_backup/kikuyomi_backup.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'backup_text.dart';
import 'providers.dart';
import 'services.dart';
import 'snack_bars.dart';

/// Shows the folder picker and makes the folder chosen the one backups go to. Returns it, or null
/// when the listener cancels or the folder cannot be chosen, which a snack bar explains.
///
/// With [backUpAfter], a backup is written there straight away, so that a library already worth
/// keeping is kept from the moment it has a folder, not from its next change.
Future<UserFolder?> chooseBackupFolder(
  BuildContext context,
  WidgetRef ref, {
  required bool backUpAfter,
}) async {
  final services = ref.read(servicesProvider);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final folder = await services.backups.chooseFolder();
    if (folder != null && backUpAfter) {
      unawaited(backUpNow(services, messenger));
    }
    return folder;
  } on FolderException catch (error) {
    tellInSnackBar(messenger, 'Could not choose the folder: ${error.message}');
  } catch (error) {
    tellInSnackBar(messenger, 'Could not choose the folder: $error');
  }
  return null;
}

/// Backs up now, and says how that went.
Future<BackupOutcome> backUpNow(
  AppServices services,
  ScaffoldMessengerState messenger,
) async {
  final outcome = await services.backupScheduler.backUpNow();
  tellInSnackBar(messenger, describeBackupOutcome(outcome));
  return outcome;
}
