/// The app's version, as `pubspec.yaml` gives it, written into every backup for diagnosing a restore
/// (ADR-0008). Never acted on.
///
/// Flutter hands the version to each platform's build but not to Dart, and a plugin that reads it
/// back while the app runs would be a dependency on three platforms for one string. A test keeps this
/// equal to `pubspec.yaml` instead.
const appVersion = '1.0.0+1';
