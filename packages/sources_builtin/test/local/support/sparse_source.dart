// A file far larger than the memory it takes, for testing that the readers read only what they
// need of a large one.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kikuyomi_sources_builtin/kikuyomi_sources_builtin.dart';

/// A file of [length] bytes, zero except where [parts] put bytes at their offsets, so that a test
/// can shape a file far larger than the memory it takes. Counts the bytes read from it.
final class SparseSource implements ByteSource {
  SparseSource(this.length, this.parts);

  @override
  final int length;
  final Map<int, List<int>> parts;
  int bytesRead = 0;

  @override
  Future<Uint8List> read(int offset, int count) async {
    final end = math.min(offset + count, length);
    final bytes = Uint8List(math.max(end - offset, 0));
    for (final MapEntry(key: start, value: part) in parts.entries) {
      final to = math.min(start + part.length, end);
      for (var i = math.max(start, offset); i < to; i++) {
        bytes[i - offset] = part[i - start];
      }
    }
    bytesRead += bytes.length;
    return bytes;
  }
}
