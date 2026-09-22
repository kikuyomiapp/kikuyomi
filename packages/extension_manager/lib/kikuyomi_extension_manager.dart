/// Repositories, index fetching, install and update, signatures, trust store, `SourceRegistry`.
///
/// Registration is manifest-first: runtimes are created lazily and pooled rather than started for
/// every installed extension at launch (§3.6).
///
/// So far it holds the manifest alone: what an extension says about itself before any of its code
/// runs, and whether this app's contract version can run it. Signatures, repositories and
/// installing (§3.8, §3.9) come later.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;

export 'src/manifest.dart';
