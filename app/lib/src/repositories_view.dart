import 'package:flutter/material.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart' show RepositoryRow;
import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';

/// What the Repositories screen shows, fed with data rather than reading it, so it can be tested
/// without a network or a database (§2.10).
///
/// A repository expands to what it offers, rather than opening a screen of its own: a listing is
/// short, and seeing two repositories' offerings side by side is how a listener works out which one
/// to take an extension from.
///
/// **Installing is not offered, because it is not built.** Each entry shows the permissions summary
/// §3.8 asks for — the domains it would contact, its content rating, its version — and the screen
/// says plainly that taking one is still to come. A button that did nothing would be worse.
class RepositoriesView extends StatelessWidget {
  const RepositoriesView({
    super.key,
    required this.repositories,
    required this.listings,
    required this.busyWith,
    required this.onAdd,
    required this.onBrowse,
    required this.onRefresh,
    required this.onRemove,
  });

  /// Every repository the listener has added, in the order they added them.
  final List<RepositoryRow> repositories;

  /// What each has been found to offer, by row id, for the ones that have been looked at.
  final Map<int, RepositoryIndex> listings;

  /// The repository being worked on, or null. Adding uses -1, which is no row's id.
  final int? busyWith;

  final VoidCallback onAdd;
  final ValueChanged<RepositoryRow> onBrowse;
  final ValueChanged<RepositoryRow> onRefresh;
  final ValueChanged<RepositoryRow> onRemove;

  @override
  Widget build(BuildContext context) {
    if (repositories.isEmpty) return _NoRepositories(onAdd: onAdd);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: repositories.length,
      itemBuilder: (context, index) => _RepositoryTile(
        repository: repositories[index],
        listing: listings[repositories[index].id],
        busy: busyWith == repositories[index].id,
        onBrowse: onBrowse,
        onRefresh: onRefresh,
        onRemove: onRemove,
      ),
    );
  }
}

class _NoRepositories extends StatelessWidget {
  const _NoRepositories({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('No repositories', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'A repository is a web address that lists extensions. Adding one '
              'lets you see what it offers.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add a repository'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RepositoryTile extends StatelessWidget {
  const _RepositoryTile({
    required this.repository,
    required this.listing,
    required this.busy,
    required this.onBrowse,
    required this.onRefresh,
    required this.onRemove,
  });

  final RepositoryRow repository;
  final RepositoryIndex? listing;
  final bool busy;
  final ValueChanged<RepositoryRow> onBrowse;
  final ValueChanged<RepositoryRow> onRefresh;
  final ValueChanged<RepositoryRow> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offered = listing?.offered ?? const <RepositoryEntry>[];
    return ExpansionTile(
      title: Text(
        repository.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        repository.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      // Asked for the first time it is opened rather than at start: a listener with a dozen
      // repositories should not pay for all of them to answer a question about one.
      onExpansionChanged: (open) {
        if (open && listing == null) onBrowse(repository);
      },
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<VoidCallback>(
              tooltip: 'What to do with this repository',
              onSelected: (action) => action(),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: () => onRefresh(repository),
                  child: const Text('Refresh'),
                ),
                PopupMenuItem(
                  value: () => onRemove(repository),
                  child: const Text('Remove'),
                ),
              ],
            ),
      children: [
        if (listing == null)
          const ListTile(dense: true, title: Text('Reading what it offers…'))
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              // Said once, at the top, rather than as a dead button on every row.
              'Installing from a repository is not built yet. This is what it '
              'offers.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          if (offered.isEmpty)
            const ListTile(dense: true, title: Text('It offers nothing yet.'))
          else
            for (final entry in offered) _OfferTile(entry: entry),
        ],
      ],
    );
  }
}

/// One extension on offer, with the permissions summary §3.8 shows before anything is taken.
class _OfferTile extends StatelessWidget {
  const _OfferTile({required this.entry});

  final RepositoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = entry.manifest;
    final languages = {for (final source in manifest.sources) source.lang};
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      title: Text('${manifest.name} ${manifest.version}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              ...languages,
              if (manifest.contentRating != ExtensionContentRating.everyone)
                manifest.contentRating.name,
            ].join(' · '),
            style: theme.textTheme.labelSmall,
          ),
          Text(
            // The line that matters before installing anything: what it will be allowed to talk to.
            'Contacts ${manifest.domains.domains.join(', ')}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
