import 'package:flutter/material.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart' show NavigationEntry;

import 'format.dart';

/// Every entry of a book's navigation with its length, the one playing marked, scrolled so that one
/// is in view.
///
/// The entries are the book's chapters, or the markers embedded in its file standing in for them
/// (§4.5). Pure, like the player view it opens from: it reports the entry picked and leaves seeking
/// to the caller.
class ChapterList extends StatefulWidget {
  const ChapterList({
    super.key,
    required this.entries,
    required this.current,
    required this.onSelected,
  });

  final List<NavigationEntry> entries;

  /// The entry playback is in. Matched by its start rather than by equality: the list and the
  /// player's state are loaded separately, and entries cover the book without overlapping, so a
  /// start names exactly one of them.
  final NavigationEntry current;

  final ValueChanged<NavigationEntry> onSelected;

  @override
  State<ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<ChapterList> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Only once laid out does the list know its height, which placing the current entry needs.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the current entry to the middle of the list, or as near as the ends allow.
  ///
  /// Rows are built only as they scroll into view, so the current row cannot be asked where it is.
  /// Every row takes the prototype's height instead, and the scroll extent, which is all rows end to
  /// end, gives that height away.
  void _revealCurrent() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final index = widget.entries.indexWhere(
      (entry) => entry.startMs == widget.current.startMs,
    );
    if (index < 0 || position.maxScrollExtent <= 0) return;
    final rowExtent =
        (position.maxScrollExtent + position.viewportDimension) /
        widget.entries.length;
    final centred = (index + 0.5) * rowExtent - position.viewportDimension / 2;
    _scroll.jumpTo(centred.clamp(0.0, position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      // Sized to its rows when there are few, under the switch to the bookmarks. No padding, which
      // would throw out the row height worked out above.
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: widget.entries.length,
      prototypeItem: const _ChapterRow(title: '', durationMs: 0),
      itemBuilder: (context, index) {
        final entry = widget.entries[index];
        return _ChapterRow(
          title: entry.title,
          durationMs: entry.durationMs,
          current: entry.startMs == widget.current.startMs,
          onTap: () => widget.onSelected(entry),
        );
      },
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.title,
    required this.durationMs,
    this.current = false,
    this.onTap,
  });

  final String title;
  final int durationMs;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: current,
      // Marked by an icon as well as by colour, which not everyone can tell apart.
      leading: SizedBox(
        width: 24,
        child: current
            ? const Icon(Icons.graphic_eq, semanticLabel: 'Playing')
            : null,
      ),
      // One line each, since every row is as tall as the prototype.
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(formatClock(durationMs)),
      onTap: onTap,
    );
  }
}
