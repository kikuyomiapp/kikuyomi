/// What the app knows about an extension it has installed, apart from its code.
///
/// §4.3's `extension` table holds these two, and the screens that list extensions read them, so they
/// sit here rather than in `extension_manager`: the package that installs an extension, the package
/// that stores one and the app that shows one all mean the same words by them.
library;

/// Whether an extension may run, and if not, why (§3.8, §4.3).
enum ExtensionStatus {
  /// Installed, verified as far as this app can verify it, and free to run.
  active,

  /// Installed, but nothing has proved its code is what its author published.
  ///
  /// What a folder install is (§3.9). A package's `files` hashes prove that the manifest and the
  /// code were written together, which is exactly what is not true of a folder an author is working
  /// in: the code is edited and the manifest is left behind. So a folder install does not check
  /// them, and says so here instead, rather than refusing the one install an author makes most.
  untrusted,

  /// Written against a contract version this app no longer supports (§3.7).
  obsolete,

  /// Withdrawn by the repository it came from (§3.8). Nothing sets this until repositories arrive.
  revoked,

  /// It loads, but it has failed often enough that the app stopped offering it. Nothing sets this
  /// yet.
  unhealthy;

  /// Whether the app will start a runtime for an extension in this state.
  bool get canRun => this == active || this == untrusted;
}

/// Where an extension came from, which is also how it is read again.
enum ExtensionOrigin {
  /// Inside the app, as an asset (§3.10). There is nothing to install and nothing to remove.
  bundled,

  /// A folder on this device that the listener chose, or copied the extension into.
  folder,

  /// A repository (§3.8). Nothing uses this until the repository door is built.
  repository;

  /// Whether an extension from here can be removed. A bundled one cannot: it is part of the app.
  bool get canRemove => this != bundled;
}
