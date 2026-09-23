import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_shell.dart';
import 'providers.dart';
import 'routes.dart';
import 'sources/source_registry.dart';

/// Browse: every source the app knows of (§2.6).
///
/// The list is read from manifests alone, so opening this screen runs no extension code (§3.6).
class BrowseScreen extends ConsumerWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppShell(
    tab: AppTab.browse,
    appBar: AppBar(title: const Text('Browse')),
    body: SourcesView(
      sources: ref.watch(sourceRegistryProvider).sources,
      onOpen: (source) => source.canBrowse
          ? SourceRoute(sourceId: source.id).push<void>(context)
          : const HomeRoute().go(context),
    ),
  );
}

/// The sources, as a list to choose from.
///
/// Fed with descriptions rather than watching the registry, so it can be tested without one.
class SourcesView extends StatelessWidget {
  const SourcesView({super.key, required this.sources, required this.onOpen});

  final List<SourceDescription> sources;
  final ValueChanged<SourceDescription> onOpen;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No sources yet. Extensions you install will appear here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: sources.length,
      itemBuilder: (context, index) {
        final source = sources[index];
        return ListTile(
          leading: Icon(
            source.canBrowse ? Icons.public : Icons.folder_outlined,
          ),
          title: Text(source.name),
          subtitle: Text(_describe(source)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onOpen(source),
        );
      },
    );
  }

  static String _describe(SourceDescription source) => source.canBrowse
      ? '${_language(source.lang)} · ${source.extensionId}'
      : 'Books you added from this device';

  static String _language(String lang) =>
      lang == 'multi' ? 'Several languages' : lang.toUpperCase();
}
