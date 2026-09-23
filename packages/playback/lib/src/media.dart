import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// A queue item made playable: the Timeline's stretch of a file, and where to fetch that file from.
///
/// [ResolvedMedia] and the resolver that produces it are domain types; pairing one with a queue item
/// is the engine's concern, so this stays in playback.
///
/// **Why the media may be missing.** SourceAPI 1.0 says a chapter's layout is known before it has
/// been resolved, but its URL is not: "stream URLs are ephemeral, header-dependent, and often come
/// in quality variants, so they are fetched immediately before use" (§1.2). Resolving every file of
/// a streamed book before the engine is loaded therefore means one call to the source per chapter
/// before a single note is heard, which for a long book is most of the wait. So the coordinator
/// hands over what it already has — for a local book, that is every file — and leaves the rest to
/// [resolve], which an engine calls when it first needs that item's bytes.
final class EngineItem {
  const EngineItem({
    required this.item,
    required this.media,
    required this.resolve,
  });

  final QueueItem item;

  /// Where this item's file is, when that is already known. Null for an item to be resolved when
  /// the engine first opens it.
  final ResolvedMedia? media;

  /// Resolves this item's file. An engine calls it only for an item it was given no [media] for,
  /// and only when it needs the bytes; calling it twice for one item is allowed and answers from
  /// whatever the resolver is holding.
  final Future<ResolvedMedia> Function() resolve;
}
