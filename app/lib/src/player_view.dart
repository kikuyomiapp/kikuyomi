import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart' show PlayerReady;

import 'format.dart';

/// The player's controls for an open book. Pure: it renders a [PlayerReady] and reports gestures,
/// and knows nothing of the coordinator, which keeps it testable as a widget on its own.
class PlayerView extends StatefulWidget {
  const PlayerView({
    super.key,
    required this.title,
    required this.state,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSkip,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.onSpeed,
  });

  static const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  final String title;
  final PlayerReady state;
  final VoidCallback onPlayPause;
  final ValueChanged<int> onSeek;
  final ValueChanged<Duration> onSkip;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final ValueChanged<double> onSpeed;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  /// Where the thumb is while being dragged, so incoming positions do not fight the finger.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final total = math.max(state.totalMs, 1).toDouble();
    final shown = (_dragging ?? state.globalMs.toDouble()).clamp(0.0, total);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.title,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                state.entry.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Slider(
                value: shown,
                max: total,
                onChanged: (value) => setState(() => _dragging = value),
                onChangeEnd: (value) {
                  setState(() => _dragging = null);
                  widget.onSeek(value.round());
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatClock(shown.round())),
                    Text('-${formatClock(state.totalMs - shown.round())}'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous chapter',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: widget.onPreviousChapter,
                  ),
                  IconButton(
                    tooltip: 'Back 30 seconds',
                    icon: const Icon(Icons.replay_30),
                    onPressed: () =>
                        widget.onSkip(const Duration(seconds: -30)),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: state.playing ? 'Pause' : 'Play',
                    iconSize: 40,
                    icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                    onPressed: widget.onPlayPause,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Forward 30 seconds',
                    icon: const Icon(Icons.forward_30),
                    onPressed: () => widget.onSkip(const Duration(seconds: 30)),
                  ),
                  IconButton(
                    tooltip: 'Next chapter',
                    icon: const Icon(Icons.skip_next),
                    onPressed: widget.onNextChapter,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              PopupMenuButton<double>(
                tooltip: 'Playback speed',
                initialValue: state.speed,
                onSelected: widget.onSpeed,
                itemBuilder: (context) => [
                  for (final speed in PlayerView.speeds)
                    PopupMenuItem(value: speed, child: Text('${speed}x')),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '${state.speed}x',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
