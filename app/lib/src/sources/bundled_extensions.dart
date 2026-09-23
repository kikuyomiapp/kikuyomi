import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';

/// The extensions that ship inside the app (§3.10).
///
/// "An official repository hosts JavaScript extensions for public-domain and openly licensed
/// catalogues such as LibriVox and Internet Archive public-domain collections. It proves the whole
/// extension pipeline end to end, serves as the reference implementation extension authors copy
/// from, and gives new users something to listen to on first launch."
///
/// The repository, its signing keys and installing from it (§3.8, §3.9) come later. Until they do,
/// the same extension ships as an asset, in exactly the package format §3.3 describes — a
/// `manifest.json` and one bundled ES2020 `main.js` — so the loader here is the loader an installed
/// extension will use, and the manifest is read as strictly as a downloaded one would be.
///
/// Each name is a folder under `assets/extensions/`. Adding one means listing it here and in
/// `pubspec.yaml`'s assets.
const bundledExtensionNames = ['librivox'];

/// An extension read out of the app's own assets: its manifest, and the code its sources live in.
final class BundledExtension {
  const BundledExtension({required this.manifest, required this.code});

  final ExtensionManifest manifest;

  /// `main.js`, verified against the hash the manifest names.
  final String code;
}

/// An asset that is not the extension the manifest says it is.
///
/// Distinct from [ManifestException], which means the manifest itself could not be read: this one
/// means the manifest read but its files did not match it, which for a bundled extension can only
/// be a build that went wrong.
final class BundledExtensionException implements Exception {
  const BundledExtensionException(this.name, this.message);

  final String name;
  final String message;

  @override
  String toString() =>
      'the bundled extension $name could not be read: $message';
}

/// Reads every extension in [bundledExtensionNames].
///
/// One that cannot be read is left out rather than stopping the app, and reported through
/// [onError]: a broken extension should cost its own source and nothing else, which is the same
/// rule §3.9 gives an installed one.
Future<List<BundledExtension>> loadBundledExtensions({
  AssetBundle? bundle,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  final assets = bundle ?? rootBundle;
  final extensions = <BundledExtension>[];
  for (final name in bundledExtensionNames) {
    try {
      extensions.add(await loadBundledExtension(name, bundle: assets));
    } catch (error, stack) {
      onError?.call(error, stack);
    }
  }
  return extensions;
}

/// Reads the extension in `assets/extensions/[name]/`.
///
/// The manifest's `files` hashes are checked before the code is ever handed to a runtime, which is
/// what §3.8 calls re-checking at load. For a bundled extension the check cannot catch tampering —
/// an attacker who can change the asset can change the manifest beside it — but it does catch the
/// mistake that will actually happen: a `main.js` edited and a manifest left behind.
///
/// Throws [ManifestException] for a manifest that cannot be read, and [BundledExtensionException]
/// for one whose files do not match it.
Future<BundledExtension> loadBundledExtension(
  String name, {
  AssetBundle? bundle,
}) async {
  final assets = bundle ?? rootBundle;
  final folder = 'assets/extensions/$name';
  final manifest = ExtensionManifest.parse(
    await assets.loadString('$folder/manifest.json'),
  );
  final code = await assets.load('$folder/main.js');
  final bytes = code.buffer.asUint8List(code.offsetInBytes, code.lengthInBytes);

  final declared = manifest.files['main.js'];
  if (declared == null) {
    throw BundledExtensionException(name, 'its manifest does not list main.js');
  }
  final actual = 'sha256-${base64.encode(sha256.convert(bytes).bytes)}';
  if (declared != actual) {
    throw BundledExtensionException(
      name,
      'main.js is $actual, and its manifest says $declared',
    );
  }
  return BundledExtension(manifest: manifest, code: utf8.decode(bytes));
}
