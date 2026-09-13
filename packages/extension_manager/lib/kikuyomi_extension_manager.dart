/// Repositories, index fetching, install and update, signatures, trust store, `SourceRegistry`.
///
/// Registration is manifest-first: runtimes are created lazily and pooled rather than started for
/// every installed extension at launch.
///
/// Pure Dart. This package must never import Flutter or a platform plugin.
library;
