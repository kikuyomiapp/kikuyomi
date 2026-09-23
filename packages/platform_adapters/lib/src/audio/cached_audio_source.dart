/// A queue item whose URL is fetched when it is first played, and whose bytes are then kept.
///
/// It does two things the plain `AudioSource.uri` cannot, and they are the same thing seen from
/// either end of §6.3:
///
///  * **It resolves late.** Nothing is asked of the source until the engine wants this item's
///    bytes, which for a book of a hundred chapters is the difference between one call before
///    playback starts and a hundred. The contract allows exactly this: a chapter's layout is known
///    before it is resolved, only its URL is not.
///  * **It keeps what it fetched.** Behind it is `just_audio`'s own `LockCachingAudioSource`,
///    which streams the file to a cache file while serving the player and afterwards answers every
///    request from that file. A 30-second skip, a chapter played again and the same book opened
///    tomorrow are then reads from the device, not requests to a site.
///
/// **It is not a way around the allowlist.** The URL it fetches is the one the resolver gave it,
/// which came out of `PlainDataDecoder` and was held to the extension's declared domains there.
/// The local proxy `just_audio` puts in front of it serves that one URL and nothing else: it takes
/// no address from the engine, so there is nothing for a source to point somewhere it may not go.
/// `just_audio` marks `StreamAudioSource` and what goes with it experimental, meaning its shape may
/// change in a later version, not that it is unfinished: it is what the package's own caching and
/// header support are built on, and it has carried them for years. The alternative is writing the
/// caching, the range arithmetic and the local proxy again here, which would be more code and worse
/// tested. The cost of the API moving is this one file.
// ignore_for_file: experimental_member_use
library;

import 'package:just_audio/just_audio.dart' as ja;
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

import 'stream_audio_cache.dart';

/// One streamed file, resolved on demand and cached.
final class CachedAudioSource extends ja.StreamAudioSource {
  CachedAudioSource({
    required this.fileId,
    required this.cache,
    required Future<ResolvedMedia> Function() resolve,
    this.userAgent,
  }) : _resolve = resolve;

  /// The library's id for this file, which is what the cache file is named after.
  final int fileId;

  final StreamAudioCache cache;

  /// How the app names itself to the site it fetches from, or null to say nothing.
  ///
  /// The bytes of a plain `AudioSource.uri` are fetched by the device's own player, which names
  /// itself; these are fetched by Dart, which would otherwise send `Dart/3.x (dart:io)`. §2.7 has
  /// the app decide its User-Agent in one place and lets no extension change it, and a
  /// volunteer-run site being asked for a book deserves to know who is asking.
  final String? userAgent;

  final Future<ResolvedMedia> Function() _resolve;

  Future<ja.LockCachingAudioSource>? _opening;

  @override
  Future<ja.StreamAudioResponse> request([int? start, int? end]) async {
    final opening = _opening ??= _open();
    final ja.LockCachingAudioSource source;
    try {
      source = await opening;
    } catch (_) {
      // A URL that could not be resolved, or a cache folder that could not be made. Forget the
      // attempt so that §6.3's retry, and any later request, starts again rather than being handed
      // the same failure for as long as the book is open.
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
    return source.request(start, end);
  }

  /// The cache-backed source for this file, made once the URL is known.
  ///
  /// It is never attached to the player: this wrapper is what the player holds, and what it asks
  /// for is passed straight through. That is deliberate — `LockCachingAudioSource` needs a player
  /// only to register with the proxy, and this wrapper has already done that for both of them. The
  /// one other thing it would read from a player is the User-Agent, which is passed as a header
  /// here instead, so nothing is lost by leaving it detached.
  Future<ja.LockCachingAudioSource> _open() async {
    final media = await _resolve();
    // The source's own headers come first, and the User-Agent is put in beside them rather than
    // over them: a site that needs a particular one is answering the extension, not the app.
    final headers = {
      if (userAgent != null) 'user-agent': userAgent!,
      ...media.headers,
    };
    return ja.LockCachingAudioSource(
      media.uri,
      headers: headers.isEmpty ? null : headers,
      cacheFile: await cache.fileFor(fileId: fileId, uri: media.uri),
    );
  }
}
