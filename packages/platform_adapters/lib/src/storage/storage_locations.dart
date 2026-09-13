import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// §5.1's single adapter for storage paths, so that no feature builds a platform path itself.
final class StorageLocations {
  const StorageLocations._({
    required this.appData,
    required this.mediaRoot,
    required this.pickerHandsOverCopies,
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
      );
    }
    return StorageLocations._(
      appData: appData,
      mediaRoot: appData,
      pickerHandsOverCopies: Platform.isAndroid,
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
}
