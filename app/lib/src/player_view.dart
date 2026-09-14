import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart' show NavigationEntry;
import 'package:kikuyomi_playback/kikuyomi_playback.dart'
    show
        PlayerReady,
        SleepAfter,
        SleepAtEndOfChapter,
        SleepTimerRunning,
        SleepTimerTarget;

import 'chapter_list.dart';
import 'format.dart';

/// The sleep timer's menu: §6.5's presets and "end of chapter". A custom duration comes later.
enum _SleepChoice {
  off('Off', null),
  minutes15('15 minutes', SleepAfter(Duration(minutes: 15))),
  minutes30('30 minutes', SleepAfter(Duration(minutes: 30))),
  minutes45('45 minutes', SleepAfter(Duration(minutes: 45))),
  hour('1 hour', SleepAfter(Duration(hours: 1))),
  endOfChapter('End of chapter', SleepAtEndOfChapter());

  const _SleepChoice(this.label, this.target);

  final String label;

  /// What the timer waits for, or null to turn it off.
  final SleepTimerTarget? target;
}

/// From Material's expanded window width up, the chapter list opens beside the controls, where it
/// can stay open while the book plays, rather than in a sheet over them (§2.6's adaptive layout).
const _sidePanelMinWidth = 840.0;

/// The player's controls for an open book. Pure: it renders a [PlayerReady] and reports gestures,
/// and knows nothing of the coordinator, which keeps it testable as a widget on its own.
class PlayerView extends StatefulWidget {
  const PlayerView({
    super.key,
    required this.title,
    required this.state,
    required this.navigation,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSkip,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.onSpeed,
    required this.onSleepTimer,
    required this.onCancelSleepTimer,
  });

  static const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  /// How far the skip buttons move, and the arrow keys with them.
  static const skipInterval = Duration(seconds: 30);

  final String title;
  final PlayerReady state;

  /// The book's chapters, or the embedded markers standing in for them (§4.5), in order. Empty
  /// until they have loaded; the chapter list cannot be opened before then.
  final List<NavigationEntry> navigation;

  final VoidCallback onPlayPause;

  /// A seek to a position in book-global time: from the scrubber, or to the start of a chapter
  /// picked from the list.
  final ValueChanged<int> onSeek;
  final ValueChanged<Duration> onSkip;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final ValueChanged<double> onSpeed;
  final ValueChanged<SleepTimerTarget> onSleepTimer;
  final VoidCallback onCancelSleepTimer;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  /// Where the thumb is while being dragged, so incoming positions do not fight the finger.
  double? _dragging;

  /// Whether the side panel is open. Only a wide layout shows it; a narrow one opens a sheet instead.
  bool _chaptersOpen = false;

  Future<void> _showChapterSheet() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: _ChapterPanel(
        entries: widget.navigation,
        current: widget.state.entry,
        onSelected: (entry) {
          Navigator.pop(sheetContext);
          widget.onSeek(entry.startMs);
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _sidePanelMinWidth;
        final panelShown =
            wide && _chaptersOpen && widget.navigation.isNotEmpty;
        // One row whether or not the panel shows, so opening it does not rebuild the controls.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _controls(context, wide: wide, panelShown: panelShown),
            ),
            if (panelShown) ...[
              const VerticalDivider(width: 1),
              SizedBox(
                width: 360,
                child: SafeArea(
                  left: false,
                  top: false,
                  child: _ChapterPanel(
                    entries: widget.navigation,
                    current: widget.state.entry,
                    // The panel stays open, to go on browsing from.
                    onSelected: (entry) => widget.onSeek(entry.startMs),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _controls(
    BuildContext context, {
    required bool wide,
    required bool panelShown,
  }) {
    final state = widget.state;
    final theme = Theme.of(context);
    final total = math.max(state.totalMs, 1).toDouble();
    final shown = (_dragging ?? state.globalMs.toDouble()).clamp(0.0, total);
    final timer = state.sleepTimer;
    final sleeping = timer is SleepTimerRunning ? timer : null;

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
                    onPressed: () => widget.onSkip(-PlayerView.skipInterval),
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
                    onPressed: () => widget.onSkip(PlayerView.skipInterval),
                  ),
                  IconButton(
                    tooltip: 'Next chapter',
                    icon: const Icon(Icons.skip_next),
                    onPressed: widget.onNextChapter,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Chapters',
                    isSelected: panelShown,
                    icon: const Icon(Icons.format_list_bulleted),
                    onPressed: widget.navigation.isEmpty
                        ? null
                        : wide
                        ? () => setState(() => _chaptersOpen = !_chaptersOpen)
                        : _showChapterSheet,
                  ),
                  const SizedBox(width: 16),
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
                  const SizedBox(width: 16),
                  PopupMenuButton<_SleepChoice>(
                    tooltip: 'Sleep timer',
                    onSelected: (choice) {
                      final target = choice.target;
                      if (target == null) {
                        widget.onCancelSleepTimer();
                      } else {
                        widget.onSleepTimer(target);
                      }
                    },
                    itemBuilder: (context) => [
                      for (final choice in _SleepChoice.values)
                        // "Off" only makes sense while a timer is set.
                        if (choice != _SleepChoice.off || sleeping != null)
                          PopupMenuItem(
                            value: choice,
                            child: Text(choice.label),
                          ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            sleeping == null
                                ? Icons.bedtime_outlined
                                : Icons.bedtime,
                            size: 20,
                          ),
                          if (sleeping != null) ...[
                            const SizedBox(width: 4),
                            // Listening time left: it stands still while the book is paused.
                            Text(
                              formatClock(sleeping.remaining.inMilliseconds),
                              style: theme.textTheme.labelLarge,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The chapter list under its heading, as the bottom sheet and the side panel both show it.
class _ChapterPanel extends StatelessWidget {
  const _ChapterPanel({
    required this.entries,
    required this.current,
    required this.onSelected,
  });

  final List<NavigationEntry> entries;
  final NavigationEntry current;
  final ValueChanged<NavigationEntry> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Text(
            'Chapters',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Flexible(
          child: ChapterList(
            entries: entries,
            current: current,
            onSelected: onSelected,
          ),
        ),
      ],
    );
  }
}
