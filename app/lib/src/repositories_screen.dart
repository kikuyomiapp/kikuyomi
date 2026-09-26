import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show RepositoryRow;
import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';

import 'providers.dart';
import 'repositories_view.dart';
import 'snack_bars.dart';
import 'sources/repository_library.dart';

/// Repositories: the addresses extensions can be taken from (§3.8).
///
/// Under Extensions, because a repository is where an extension comes from and Extensions is where
/// they are managed. ADR-0017's folder is the author's door; this is the listener's.
///
/// **Adding one is two steps on purpose.** §3.8's trust is trust on first use: the app reads what is
/// at the address, shows the signing key's fingerprint, and keeps nothing until the listener says
/// yes. A one-step add would pin a key nobody had looked at, which is the whole thing the fingerprint
/// exists to prevent.
class RepositoriesScreen extends ConsumerStatefulWidget {
  const RepositoriesScreen({super.key});

  @override
  ConsumerState<RepositoriesScreen> createState() => _RepositoriesScreenState();
}

class _RepositoriesScreenState extends ConsumerState<RepositoriesScreen> {
  /// The row being worked on. [_adding] stands for the add flow, which is no row's id yet.
  static const _adding = -1;

  int? _busyWith;

  /// What each repository has been found to offer. Held here rather than watched, because a listing
  /// is fetched rather than stored (see `RepositoryLibrary`).
  final _listings = <int, RepositoryIndex>{};

  @override
  Widget build(BuildContext context) {
    final repositories = ref.watch(repositoriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Repositories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busyWith == null ? _add : null,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: repositories.when(
        data: (rows) => RepositoriesView(
          repositories: rows,
          listings: _listings,
          busyWith: _busyWith,
          onAdd: _add,
          onBrowse: _browse,
          onRefresh: _refresh,
          onRemove: _remove,
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('The repositories could not be read: $error'),
          ),
        ),
      ),
    );
  }

  Future<void> _add() async {
    final typed = await _askForAddress();
    if (typed == null || !mounted) return;

    await _work(_adding, () async {
      final offer = await ref.read(servicesProvider).repositories.look(typed);
      if (!mounted) return;
      if (offer.alreadyAdded) {
        _tell('${offer.info.name} is already in your list.');
        return;
      }
      if (!await _confirmKey(offer) || !mounted) return;
      final id = await ref.read(servicesProvider).repositories.accept(offer);
      setState(() => _listings[id] = offer.index);
      _tell('Added ${offer.info.name}.');
    });
  }

  Future<String?> _askForAddress() {
    final field = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a repository'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.org/repo',
            helperText: 'A GitHub project page works too',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Look'),
          ),
        ],
      ),
    ).whenComplete(field.dispose);
  }

  /// §3.8's trust on first use, as a question.
  ///
  /// The fingerprint is shown whole. A listener comparing it against what a repository's operator
  /// published can only do that if all of it is there, and a shortened one is a fingerprint that can
  /// be forged into.
  Future<bool> _confirmKey(RepositoryOffer offer) async {
    final theme = Theme.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Trust ${offer.info.name}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'It offers ${offer.offers == 1 ? '1 extension' : '${offer.offers} extensions'}. '
                  'Extensions from a repository run code on this device, so add '
                  'one only if you trust whoever runs it.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Text('Signing key', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                SelectableText(
                  offer.fingerprint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Check this matches what its operator published. Kikuyomi '
                  'does not verify signatures yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Add it'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _browse(RepositoryRow repository) =>
      _work(repository.id, () async {
        final index = await ref
            .read(servicesProvider)
            .repositories
            .browse(repository);
        if (mounted) setState(() => _listings[repository.id] = index);
      });

  Future<void> _refresh(RepositoryRow repository) =>
      _work(repository.id, () async {
        final index = await ref
            .read(servicesProvider)
            .repositories
            .refresh(repository);
        if (!mounted) return;
        setState(() => _listings[repository.id] = index);
        _tell('${repository.name} offers ${index.offered.length} extensions.');
      });

  Future<void> _remove(RepositoryRow repository) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Remove ${repository.name}?'),
            content: const Text(
              'Extensions you installed from it stay installed and keep '
              'working. What you lose is updates from it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep it'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _work(repository.id, () async {
      await ref.read(servicesProvider).repositories.remove(repository);
      if (mounted) setState(() => _listings.remove(repository.id));
    });
  }

  /// Runs [action] with the row marked busy, and turns whatever it throws into a sentence.
  ///
  /// Every failure here is one a listener can act on — an address that is not a repository, a host
  /// that did not answer, a key that has changed — so each is shown rather than only logged.
  Future<void> _work(int id, Future<void> Function() action) async {
    if (_busyWith != null) return;
    setState(() => _busyWith = id);
    try {
      await action();
    } on RepositoryException catch (error) {
      _tell(error.message);
    } catch (error) {
      _tell('$error');
    } finally {
      if (mounted) setState(() => _busyWith = null);
    }
  }

  void _tell(String message) {
    if (!mounted) return;
    tellInSnackBar(ScaffoldMessenger.of(context), message);
  }
}
