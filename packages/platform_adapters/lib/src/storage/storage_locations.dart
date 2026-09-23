import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../drop/file_drop_target.dart';

/// §5.1's single adapter for storage paths, so that no feature builds a platform path itself.
final class StorageLocations {
  const StorageLocations._({
    required this.appData,
    required this.covers,
    required this.streamCache,
    required this.mediaRoot,
    required this.pickerHandsOverCopies,
    required this.importFolderIsVisible,
    required this.canPickFolders,
    required this.acceptsDroppedFiles,
  });

  /// The locations on this device. Asynchronous because `path_provider` asks the platform.
  static Future<StorageLocations> forThisDevice() async {
    final appData = await getApplicationSupportDirectory();
    await appData.create(recursive: true);
    final streamCache = Directory(
      '${(await getApplicationCacheDirectory()).path}'
      '${Platform.pathSeparator}streams',
    );
    // §5.1 keeps library covers in internal storage on every platform. Application Support is that
    // on iOS too, where Documents would show them in the Files app beside the imported books.
    final covers = Directory('${appData.path}${Platform.pathSeparator}covers');
    if (Platform.isIOS) {
      return StorageLocations._(
        appData: appData,
        covers: covers,
        streamCache: streamCache,
        // §5.1 keeps iOS imports in a folder the Files app shows, and Documents is the folder it
        // shows, given UIFileSharingEnabled in Info.plist.
        mediaRoot: await getApplicationDocumentsDirectory(),
        pickerHandsOverCopies: true,
        importFolderIsVisible: true,
        canPickFolders: false,
        acceptsDroppedFiles: platformReportsDroppedPaths,
      );
    }
    final android = Platform.isAndroid;
    return StorageLocations._(
      appData: appData,
      covers: covers,
      streamCache: streamCache,
      mediaRoot: appData,
      pickerHandsOverCopies: android,
      importFolderIsVisible: false,
      canPickFolders: !android,
      acceptsDroppedFiles: platformReportsDroppedPaths,
    );
  }

  /// App-internal data: the database and the device id.
  final Directory appData;

  /// The covers of books in the library (§5.1), inside [appData]. It may not exist yet: whatever
  /// writes the first cover creates it.
  ///
  /// Book rows record a cover by its name in this folder, never by an absolute path, since on iOS
  /// the app's container can move when the app is updated or reinstalled.
  final Directory covers;

  /// Where the bytes of a streamed book are kept while they are worth keeping.
  ///
  /// In the platform's cache folder, not in app data and never in the downloads folder §5.2 gives
  /// the listener: nobody asked for these files, nothing in the database refers to them, and an OS
  /// that wants the space back is welcome to it. It may not exist yet; the cache makes it.
  final Directory streamCache;

  /// What paths to media in the app's own storage are stored relative to.
  final Directory mediaRoot;

  /// Whether a file the user picks arrives as a temporary copy rather than as the file itself.
  ///
  /// The iOS picker copies the chosen file into the app's temporary folder, and the Android picker
  /// copies it into the app's cache, and the system may clear either. Such a copy has to be moved
  /// into app storage to be kept. A desktop picker returns the user's own file, which stays where
  /// the user keeps it.
  final bool pickerHandsOverCopies;

  /// Whether the user can see the import folder and copy books into it themselves, as they can on
  /// iOS through the Files app.
  ///
  /// The folder is looked in for new books wherever it is; this says only whether it is worth
  /// telling the user about.
  final bool importFolderIsVisible;

  /// Whether a folder the user picks can be read where it is, as a book of several files.
  ///
  /// Only on desktop for now. Android hands over a picked folder as a content address that plain
  /// file access cannot open, and iOS has no folder picker; both wait for §3.10's folder access
  /// through the Storage Access Framework and security-scoped bookmarks.
  final bool canPickFolders;

  /// Whether files and folders dropped onto the window arrive as paths that can be read where they
  /// are, so that a `FileDropTarget` can add them as a picked file or folder is added.
  ///
  /// Only on desktop. Android reports a drop from another app as content addresses, for the reason
  /// [canPickFolders] gives, and iOS reports none to the app at all.
  final bool acceptsDroppedFiles;
}
