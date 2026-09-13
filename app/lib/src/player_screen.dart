import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart'
    show PlayerFailed, PlayerIdle, PlayerLoading, PlayerReady;

import 'player_view.dart';
import 'providers.dart';

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const PlayerScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(playerStateProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Now playing')),
      body: playerState.when(
        data: (state) => switch (state) {
          PlayerIdle() => const Center(child: Text('Nothing is playing')),
          PlayerLoading() => const Center(child: CircularProgressIndicator()),
          PlayerFailed(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Playback failed: $error',
                textAlign: TextAlign.center,
              ),
            ),
          ),
          PlayerReady() => _ReadyPlayer(state: state),
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
      ),
    );
  }
}

class _ReadyPlayer extends ConsumerWidget {
  const _ReadyPlayer({required this.state});

  final PlayerReady state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinator = ref.watch(servicesProvider).coordinator;
    final title = ref
        .watch(bookProvider(state.bookId))
        .when(
          data: (book) => book?.title ?? '',
          loading: () => '',
          error: (_, _) => '',
        );
    return PlayerView(
      title: title,
      state: state,
      onPlayPause: () =>
          state.playing ? coordinator.pause() : coordinator.play(),
      onSeek: coordinator.seekTo,
      onSkip: coordinator.skip,
      onPreviousChapter: coordinator.previousChapter,
      onNextChapter: coordinator.nextChapter,
      onSpeed: coordinator.setSpeed,
    );
  }
}
