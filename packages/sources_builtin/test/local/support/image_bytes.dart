// The openings of JPEG and PNG files, for the cover art tests: each format's signature followed by
// filler, which is all a reader looks at to tell the format. None of them is an image, and no image
// of any kind is in the repository.

/// [length] bytes opening with the JPEG signature, then [fill].
List<int> jpegBytes({int length = 64, int fill = 0x11}) => [
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  ...List.filled(length - 4, fill),
];

/// [length] bytes opening with the PNG signature, then [fill].
List<int> pngBytes({int length = 64, int fill = 0x22}) => [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  ...List.filled(length - 8, fill),
];
