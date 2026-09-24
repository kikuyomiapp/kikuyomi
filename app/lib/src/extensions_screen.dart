import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

import 'extensions_view.dart';
import 'providers.dart';
import 'routes.dart';
import 'snack_bars.dart';
import 'sources/extension_library.dart';

/// Extensions: what is installed, what each one has produced, and installing or removing one (§3.9).
///
/// Reached from Browse, because an extension is where a source comes from and Browse is where sources
/// are. Everything it shows is watched, so an install or a removal appears without anything being
/// refreshed (§2.5).
class ExtensionsScreen extends ConsumerStatefulWidget {
  const ExtensionsScreen({super.key});

  @override
  ConsumerState<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

class _ExtensionsScreenState extends ConsumerState<ExtensionsScreen> {
  /// Which extension is being worked on, so that two taps cannot install the same folder twice. The
  /// empty string while a folder is being picked, when no extension is known yet.
  String? _busyWith;

  @override
  Widget build(BuildContext context) {
    final extensions = ref.watch(extensionsProvider).value ?? const [];
    final library = ref.watch(servicesProvider).extensions;
    // The console is watched, not read, so a failure logged while this screen is open is counted here
    // the moment it happens.
    final problems = <String, int>{};
    for (final line in ref.watch(extensionConsoleProvider).value ?? const []) {
      if (line.level == ExtensionLogLevel.error) {
        problems.update(line.extensionId, (n) => n + 1, ifAbsent: () => 1);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Extensions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Console',
            onPressed: () => const ExtensionConsoleRoute().push<void>(context),
          ),
        ],
      ),
      body: ExtensionsView(
        extensions: extensions,
        problems: problems,
        canChooseFolder: library.canChooseFolder,
        dropFolderName: library.canInstallFromDropFolder
            ? library.dropFolderName
            : null,
        busyWith: _busyWith,
        onInstallFromFolder: _installFromPickedFolder,
        onInstallFromDropFolder: _installFromDropFolder,
        onReload: _reload,
        onRemove: _remove,
        onOpenConsole: (extensionId) =>
            ExtensionConsoleRoute(extensionId: extensionId).push<void>(context),
      ),
    );
  }

  Future<void> _installFromPickedFolder() => _work('', () async {
    final installed = await ref
        .read(servicesProvider)
        .extensions
        .installFromPickedFolder();
    if (installed != null) _tell(_installed(installed));
  });

  /// Installs from the app's own Extensions folder: the way in on iOS, where no folder outside the app
  /// can be kept. One folder is installed without asking; several are offered as a list, since the
  /// listener may have copied in more than one.
  Future<void> _installFromDropFolder() => _work('', () async {
    final library = ref.read(servicesProvider).extensions;
    await library.prepareDropFolder();
    final candidates = await library.dropFolderCandidates();
    if (candidates.isEmpty) {
      _tell(
        'Nothing in the ${library.dropFolderName} folder yet. Copy an '
        'extension folder into it, then try again.',
      );
      return;
    }
    final chosen = candidates.length == 1
        ? candidates.single
        : await _chooseFolder(candidates);
    if (chosen == null) return;
    _tell(_installed(await library.installFromPath(chosen.path)));
  });

  Future<Directory?> _chooseFolder(List<Directory> candidates) =>
      showDialog<Directory>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Which one?'),
          children: [
            for (final folder in candidates)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(folder),
                child: Text(folder.path.split(RegExp(r'[\\/]')).last),
              ),
          ],
        ),
      );

  Future<void> _reload(ExtensionSummary extension) =>
      _work(extension.id, () async {
        final reloaded = await ref
            .read(servicesProvider)
            .extensions
            .reload(extension.id);
        _tell('Reloaded ${reloaded.name} ${reloaded.row.version}.');
      });

  Future<void> _remove(ExtensionSummary extension) async {
    if (!await confirmRemoveExtension(context, extension)) return;
    await _work(extension.id, () async {
      await ref.read(servicesProvider).extensions.remove(extension.id);
      _tell('Removed ${extension.name}.');
    });
  }

  /// Runs [action] with the screen marked busy, and turns whatever it throws into a sentence.
  ///
  /// Every failure here is one a listener can act on — a folder that is not an extension, a folder that
  /// can no longer be read, an extension this app is too old for — so each is shown rather than only
  /// logged.
  Future<void> _work(String id, Future<void> Function() action) async {
    if (_busyWith != null) return;
    setState(() => _busyWith = id);
    try {
      await action();
    } on ExtensionInstallException catch (error) {
      _tell(error.message);
    } on FolderException catch (error) {
      _tell(error.message);
    } catch (error) {
      _tell('$error');
    } finally {
      if (mounted) setState(() => _busyWith = null);
    }
  }

  String _installed(ExtensionSummary extension) =>
      'Installed ${extension.name} ${extension.row.version}. '
              '${extension.isUnverified ? 'Unverified: nothing checked its code.' : ''}'
          .trimRight();

  void _tell(String message) {
    if (!mounted) return;
    tellInSnackBar(ScaffoldMessenger.of(context), message);
  }
}
