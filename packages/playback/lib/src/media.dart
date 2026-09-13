import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// A queue item made playable: the Timeline's stretch of a file, and where to fetch that file from.
///
/// [ResolvedMedia] and the resolver that produces it are domain types; pairing one with a queue item
/// is the engine's concern, so this stays in playback.
final class EngineItem {
  const EngineItem({required this.item, required this.media});

  final QueueItem item;
  final ResolvedMedia media;
}
