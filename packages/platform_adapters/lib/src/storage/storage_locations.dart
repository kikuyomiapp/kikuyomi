import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// §5.1's single adapter for storage paths, so that no feature builds a platform path itself.
final class StorageLocations {
  const StorageLocations._({
    required this.appData,
    required this.mediaRoot,
    required this.pickerHandsOverCopies,
    required this.importFolderIsVisible,
    required this.canPickFolders,
  });

  /// The locations on this device. Asynchronous because `path_provider` asks the platform.
  static Future<StorageLocations> forThisDevice() async {
    final appData = await getApplicationSupportDirectory();
    await appData.create(recursive: true);
    if (Platform.isIOS) {
      return StorageLocations._(
        appData: appData,
        // §5.1 keeps iOS imports in a folder the Files app shows, and Documents is the folder it
        // shows, given UIFileSharingEnabled in Info.plist.
        mediaRoot: await getApplicationDocumentsDirectory(),
        pickerHandsOverCopies: true,
        importFolderIsVisible: true,
        canPickFolders: false,
      );
    }
    final android = Platform.isAndroid;
    return StorageLocations._(
      appData: appData,
      mediaRoot: appData,
      pickerHandsOverCopies: android,
      importFolderIsVisible: false,
      canPickFolders: !android,
    );
  }

  /// App-internal data: the database and the device id.
  final Directory appData;

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
}
