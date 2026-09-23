import 'package:flutter/material.dart';
import 'package:kikuyomi_design_system/kikuyomi_design_system.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';

import 'format.dart';

/// A book at a source, before it is in the library: what it is, who made it, and what is in it.
///
/// Fed with the contract's own types rather than a database row, because that is all the app knows
/// about a book nobody has added yet. Once it is added, its details screen takes over and it behaves
/// exactly like a local book.
class SourceBookView extends StatelessWidget {
  const SourceBookView({
    super.key,
    required this.details,
    required this.chapters,
    required this.inLibrary,
    required this.adding,
    required this.onAdd,
    required this.onOpenAtSource,
  });

  final BookDetails details;
  final List<ChapterInfo> chapters;

  /// True once the book is in the library, when Add becomes Open.
  final bool inLibrary;

  /// True while it is being added, so the button says so rather than looking stuck.
  final bool adding;

  final VoidCallback onAdd;

  /// Opens the book's own page on the site. Null when the source gave no page.
  final VoidCallback? onOpenAtSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = details.description;
    final total = details.totalDurationMs;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover.network(
              url: details.coverUrl,
              size: 132,
              semanticLabel: 'Cover of ${details.title}',
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(details.title, style: theme.textTheme.titleLarge),
                  if (details.subtitle != null)
                    Text(
                      details.subtitle!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (details.authors.isNotEmpty)
                    _Credit(label: 'By', names: details.authors),
                  if (details.narrators.isNotEmpty)
                    _Credit(label: 'Read by', names: details.narrators),
                  const SizedBox(height: 8),
                  Text(
                    _facts(details, chapters.length),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: adding ? null : onAdd,
                icon: Icon(
                  inLibrary ? Icons.library_add_check : Icons.library_add,
                ),
                label: Text(
                  adding
                      ? 'Adding…'
                      : inLibrary
                      ? 'Open in library'
                      : 'Add to library',
                ),
              ),
            ),
            if (onOpenAtSource != null) ...[
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: 'Open at the source',
                onPressed: onOpenAtSource,
                icon: const Icon(Icons.open_in_new),
              ),
            ],
          ],
        ),
        if (details.genres.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final genre in details.genres) Chip(label: Text(genre)),
            ],
          ),
        ],
        if (description != null) ...[
          const SizedBox(height: 16),
          Text('About', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(description, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 16),
        Text(
          chapters.isEmpty ? 'Chapters' : 'Chapters (${chapters.length})',
          style: theme.textTheme.titleMedium,
        ),
        if (chapters.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('This source lists no chapters for this book.'),
          ),
        for (final (index, chapter) in chapters.indexed)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Text('${index + 1}'),
            title: Text(chapter.title),
            subtitle: chapter.group == null ? null : Text(chapter.group!),
            trailing: chapter.durationMs == null
                ? null
                : Text(formatClock(chapter.durationMs!)),
          ),
        if (total != null) ...[
          const SizedBox(height: 8),
          Text(
            'Total ${formatDuration(Duration(milliseconds: total))}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  /// The one-line summary under the credits: language, year, publisher and length, whichever the
  /// source gave.
  static String _facts(BookDetails details, int chapters) {
    final parts = <String>[
      if (details.publishedDate != null) details.publishedDate!,
      if (details.language != null) details.language!.toUpperCase(),
      if (details.publisher != null) details.publisher!,
      if (chapters > 0) '$chapters chapters',
      if (details.totalDurationMs != null)
        formatDuration(Duration(milliseconds: details.totalDurationMs!)),
      if (details.status == BookStatus.ongoing) 'Still being released',
    ];
    return parts.join(' · ');
  }
}

class _Credit extends StatelessWidget {
  const _Credit({required this.label, required this.names});

  final String label;
  final List<String> names;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: names.join(', '),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}
