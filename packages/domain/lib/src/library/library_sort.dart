/// How a library is ordered on the shelf (§2.6).
///
/// In the domain rather than in the app because it is stored: `AppSettings.librarySort` keeps the
/// listener's choice between launches, and a setting's type has to live where both the store and the
/// screen can see it.
library;

/// The orders a library can be shown in.
///
/// Deliberately few. Every order here answers a question a listener actually asks of a shelf — what
/// is it called, what did I just add, what will take me all week — and each is answerable from the
/// book row alone, so sorting costs no query.
///
/// "Recently listened" is the obvious absence. It lives in `playback_state` rather than on the book,
/// so it needs a join the library query does not do yet, and Continue Listening already puts exactly
/// those books at the top of the same screen.
enum LibrarySort {
  /// A to Z, ignoring case. The order a shelf is in when nobody has chosen one.
  title('Title'),

  /// Newest first: what was added last, which is usually what is about to be played.
  recentlyAdded('Recently added'),

  /// Longest first. A library sorted this way is being asked "what am I committing to".
  longest('Longest');

  const LibrarySort(this.label);

  /// What to call it in the menu.
  final String label;

  /// The order a library is in before anyone chooses.
  static const fallback = LibrarySort.title;

  /// The value stored under [name], or null for one this build does not know.
  ///
  /// Null rather than a throw: a setting written by a newer build is not worth failing over, and
  /// falling back to [fallback] is what a shelf with no chosen order does anyway.
  static LibrarySort? byName(String name) {
    for (final sort in values) {
      if (sort.name == name) return sort;
    }
    return null;
  }
}
