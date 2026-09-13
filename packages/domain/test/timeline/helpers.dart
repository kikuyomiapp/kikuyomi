// Shared fixtures for the Timeline tests.

import 'package:kikuyomi_domain/kikuyomi_domain.dart';

const s = 1000;
const m = 60 * s;

ChapterPosition at(int chapterId, int offsetMs) =>
    ChapterPosition(chapterId: chapterId, offsetMs: offsetMs);

QueuePosition item(int index, int offsetMs) =>
    QueuePosition(itemIndex: index, offsetMs: offsetMs);

TimelineChapter chapter(int id, List<TimelineSegment> segments) =>
    TimelineChapter(id: id, title: 'Chapter $id', segments: segments);

TimelineSegment seg(int fileId, [int startMs = 0, int? endMs]) =>
    TimelineSegment(fileId: fileId, startMs: startMs, endMs: endMs);

/// The layout drawn in §4.5: three files of 40, 35 and 50 minutes, six chapters that ignore the
/// file boundaries, 2h05m in total.
Timeline diagramBook({
  bool firstFileEstimated = false,
  int firstFileMs = 40 * m,
}) => Timeline.build(
  files: [
    TimelineFile(
      id: 1,
      durationMs: firstFileMs,
      durationIsEstimate: firstFileEstimated,
    ),
    const TimelineFile(id: 2, durationMs: 35 * m),
    const TimelineFile(id: 3, durationMs: 50 * m),
  ],
  chapters: [
    chapter(1, [seg(1, 0, 15 * m)]),
    chapter(2, [seg(1, 15 * m), seg(2, 0, 5 * m)]),
    chapter(3, [seg(2, 5 * m, 20 * m)]),
    chapter(4, [seg(2, 20 * m), seg(3, 0, 10 * m)]),
    chapter(5, [seg(3, 10 * m, 25 * m)]),
    chapter(6, [seg(3, 25 * m)]),
  ],
);
