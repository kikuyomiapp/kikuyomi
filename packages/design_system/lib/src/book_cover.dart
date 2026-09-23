import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A book's cover art, or a placeholder where there is none.
///
/// §2.4 gives the design system the cover component and image loading. It takes the image's file
/// rather than a book, so it knows nothing of where covers are kept or how books name them.
///
/// The image is decoded at the size it is shown, in device pixels, rather than at its own size. A
/// picture embedded in an audiobook can run to 16 megabytes and thousands of pixels a side, and
/// decoded at full size one such cover would take more memory than a whole shelf of them needs.
/// This is what `Image.file` does with `cacheWidth` and `cacheHeight`, with the fit policy added,
/// so a cover that is not square keeps its shape: it is shown whole on the tinted surface, never
/// stretched or cropped.
///
/// While the image loads, the tinted surface shows alone. A cover that cannot be read or decoded,
/// like a book with none, shows headphones on it instead.
///
/// [BookCover.network] is the same cover for a book being browsed at a source, whose image is a URL
/// and not a file yet. It is decoded at the size it is shown in the same way, and it takes the
/// headers §6.3 says some sites need. Nothing is written to disk: a book's cover is kept only once
/// the book is in the library, and the image cache is what makes scrolling back up cheap.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.file,
    required this.size,
    required this.semanticLabel,
  }) : url = null,
       headers = const {};

  const BookCover.network({
    super.key,
    required this.url,
    required this.size,
    required this.semanticLabel,
    this.headers = const {},
  }) : file = null;

  /// The image, or null for a book with no cover.
  final File? file;

  /// Where the image is, for a book that is not in the library yet, or null.
  final Uri? url;

  /// What the site needs on the request for it (§6.3).
  final Map<String, String> headers;

  /// The cover's width and height in logical pixels. Covers are square, the shape audiobook art
  /// almost always has.
  final double size;

  /// What a screen reader announces, such as "Cover of Middlemarch".
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final image = imageProvider(context);
    final placeholder = Center(
      child: Icon(
        Icons.headphones,
        size: size / 2,
        color: colors.onSurfaceVariant,
      ),
    );
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular((size / 8).clamp(4.0, 16.0)),
        child: SizedBox.square(
          dimension: size,
          child: ColoredBox(
            color: colors.surfaceContainerHighest,
            child: image == null
                ? placeholder
                : Image(
                    image: image,
                    width: size,
                    height: size,
                    fit: BoxFit.contain,
                    // A cover that changes, as one arriving for a book shown without, replaces the
                    // old one only once it is ready.
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) => placeholder,
                  ),
          ),
        ),
      ),
    );
  }

  /// The image this cover shows, decoded no larger than the cover in device pixels, or null for a
  /// book with neither a file nor a URL.
  @visibleForTesting
  ImageProvider<Object>? imageProvider(BuildContext context) {
    final file = this.file;
    if (file != null) return _sized(FileImage(file), context);
    final url = this.url;
    if (url != null) {
      return _sized(NetworkImage(url.toString(), headers: headers), context);
    }
    return null;
  }

  /// The image [file] as this cover decodes it: no larger than the cover in device pixels.
  @visibleForTesting
  ImageProvider<Object> coverImage(File file, BuildContext context) =>
      _sized(FileImage(file), context);

  ImageProvider<Object> _sized(
    ImageProvider<Object> image,
    BuildContext context,
  ) {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final pixels = math.max(1, (size * ratio).round());
    return ResizeImage(
      image,
      width: pixels,
      height: pixels,
      policy: ResizeImagePolicy.fit,
    );
  }
}
