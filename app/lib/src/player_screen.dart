import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_data/kikuyomi_data.dart'
    show
        addBookmark,
        deleteBookmark,
        renameBookmark,
        restoreBookmark,
        setBookmarkNote;
import 'package:kikuyomi_playback/kikuyomi_playback.dart'
    show
        PlaybackCoordinator,
        PlayerFailed,
        PlayerIdle,
        PlayerLoading,
        PlayerReady;
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart'
    show SourceException;

import 'bookmark_commands.dart';
import 'player_shortcuts.dart';
import 'player_view.dart';
import 'providers.dart';
import 'services.dart';
import 'sources/source_error_view.dart';

/// The player for the book the coordinator has open. Reached through `PlayerRoute`.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(playerStateProvider);
    final services = ref.watch(servicesProvider);
    final coordinator = services.coordinator;
    final ready = switch (playerState) {
      AsyncData(value: final PlayerReady state) => state,
      _ => null,
    };
    // Around the whole screen, app bar included, so the keys work wherever focus is on it.
    return PlayerShortcuts(
      state: ready,
      onPlayPause: () {
        if (ready != null) _playOrPause(coordinator, ready);
      },
      onSkip: coordinator.skip,
      onSpeed: coordinator.setSpeed,
      onAddBookmark: () =>
          addBookmarkHere(context, _bookmarkCommands(services)),
      child: Scaffold(
        appBar: AppBar(title: const Text('Now playing')),
        body: playerState.when(
          data: (state) => switch (state) {
            PlayerIdle() => const Center(child: Text('Nothing is playing')),
            PlayerLoading() => const Center(child: CircularProgressIndicator()),
            PlayerFailed(:final bookId, :final error) => _Failure(
              bookId: bookId,
              error: error,
            ),
            PlayerReady() => _ReadyPlayer(state: state),
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('$error')),
        ),
      ),
    );
  }
}

/// What the player shows when playback failed.
///
/// A streamed book fails with one of the contract's error kinds, and those are shown the way Browse
/// shows them: named after the source, with the extension's own words underneath, and with a way out
/// where there is one. Playing again re-resolves the URL, which is what an expired one needs.
///
/// Anything else — a local file that has gone, an engine that would not open what it was given — is
/// not a source's doing, and is shown as it is.
class _Failure extends ConsumerWidget {
  const _Failure({required this.bookId, required this.error});

  final int bookId;
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = this.error;
    final sourceName = ref.watch(bookSourceNameProvider(bookId)).value;
    if (error is SourceException && sourceName != null) {
      return SourceErrorView(
        error: error,
        sourceName: sourceName,
        onRetry: ref.read(servicesProvider).coordinator.play,
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Playback failed: $error', textAlign: TextAlign.center),
      ),
    );
  }
}

class _ReadyPlayer extends ConsumerWidget {
  const _ReadyPlayer({required this.state});

  final PlayerReady state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(servicesProvider);
    final coordinator = services.coordinator;
    // Nothing is shown while the book loads, or if it cannot be.
    final book = ref.watch(bookProvider(state.bookId)).value;
    // The list stays empty while it loads, which takes a moment only when the player opens.
    final bookmarks = ref.watch(bookmarksProvider(state.bookId)).value;
    return PlayerView(
      title: book?.title ?? '',
      cover: services.covers.fileOf(book?.coverLocalPath),
      state: state,
      bookmarks: bookmarks ?? const [],
      bookmarkCommands: _bookmarkCommands(services),
      onPlayPause: () => _playOrPause(coordinator, state),
      onSeek: coordinator.seekTo,
      onSkip: coordinator.skip,
      onPreviousChapter: coordinator.previousChapter,
      onNextChapter: coordinator.nextChapter,
      onSpeed: coordinator.setSpeed,
      onSleepTimer: coordinator.startSleepTimer,
      onCancelSleepTimer: coordinator.cancelSleepTimer,
    );
  }
}

/// Pauses a playing book and plays a paused one, as the play button and the space bar both do.
void _playOrPause(PlaybackCoordinator coordinator, PlayerReady state) =>
    state.playing ? coordinator.pause() : coordinator.play();

/// The player's bookmark changes, made in the database.
///
/// A bookmark is added where the coordinator is at the moment it is asked, rather than where the
/// screen last showed it, and in the chapter-relative form progress is stored in (§4.5): its chapter
/// and the offset into it, never a global position.
BookmarkCommands _bookmarkCommands(AppServices services) {
  final db = services.database;
  return BookmarkCommands(
    add: () async => switch (services.coordinator.state) {
      PlayerReady(:final bookId, :final position) => await addBookmark(
        db,
        bookId: bookId,
        position: position,
        clock: services.clock,
      ),
      _ => null,
    },
    rename: (bookmarkId, title) => renameBookmark(db, bookmarkId, title),
    setNote: (bookmarkId, note) => setBookmarkNote(db, bookmarkId, note),
    delete: (bookmark) => deleteBookmark(db, bookmark.bookmarkId),
    restore: (bookmark) => restoreBookmark(db, bookmark),
  );
}
