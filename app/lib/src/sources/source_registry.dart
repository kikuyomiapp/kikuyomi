import 'dart:async';

import 'package:kikuyomi_data/kikuyomi_data.dart';
import 'package:kikuyomi_extension_manager/kikuyomi_extension_manager.dart';
import 'package:kikuyomi_networking/kikuyomi_networking.dart';
import 'package:kikuyomi_source_api/kikuyomi_source_api.dart';
import 'package:kikuyomi_source_runtime/kikuyomi_source_runtime.dart';

import 'bundled_extensions.dart';

/// One source the app knows of, from its manifest alone.
///
/// §3.6: "The `SourceRegistry` knows every installed source from manifests alone. App launch never
/// executes extension code, which is what keeps hundreds of installed sources cheap." So everything
/// a source list shows is here, and nothing here has run a line of JavaScript.
final class SourceDescription {
  const SourceDescription({
    required this.id,
    required this.key,
    required this.name,
    required this.lang,
    required this.capabilities,
    this.extensionId,
    this.contentRating,
  });

  /// The §3.7 id: the first 8 bytes of SHA-256 over `{extensionId}/{sourceKey}/{lang}/{versionId}`,
  /// or [localSourceId] for the built-in Local files source.
  final int id;
  final String key;
  final String name;

  /// A BCP 47 tag, or `multi` for a catalogue that is not one language.
  final String lang;

  /// What the manifest says the source can do. What it really has is asked of the extension when it
  /// is first opened, so a manifest that over-claims costs a tab, never a failed tap.
  final Set<SourceCapability> capabilities;

  /// Null for a built-in source.
  final String? extensionId;
  final String? contentRating;

  /// Whether a listener can browse this source's catalogue.
  ///
  /// False for Local files, whose books come from the device and are the library itself. The Local
  /// source proper (§3.10) will implement the contract and browse folders; until it does, Browse
  /// lists it and sends the listener to the library rather than pretending to have a catalogue.
  bool get canBrowse => extensionId != null;
}

/// Every source the app offers, and the runtimes behind them (§3.6).
///
/// **What it does at start.** Reads the bundled manifests, works out each source's id, and writes a
/// `source` row for each (§4.3). No extension code runs.
///
/// **What it does on first use.** [open] starts that extension's runtime in a worker isolate of its
/// own and keeps it. One worker per extension, as §3.6 has it; the pool with least-recently-used
/// eviction goes in front of this, not inside it.
final class SourceRegistry {
  SourceRegistry._(
    this._database,
    this._network,
    this._store,
    this._log,
    this._host,
    this._engineFactory,
    List<BundledExtension> extensions,
    List<SourceDescription> sources,
  ) : _extensions = {for (final e in extensions) e.manifest.id: e},
      _sources = List.unmodifiable(sources);

  /// Reads the bundled extensions and registers every source, the built-in Local one included.
  ///
  /// An extension this app's contract version cannot run (§3.7) is left out with a word to
  /// [onError], rather than offered and then failing when it is tapped.
  static Future<SourceRegistry> start({
    required KikuyomiDatabase database,
    required NetworkService network,
    required ExtensionStore store,
    required ExtensionLogSink log,
    required HostFacts host,
    required ScriptEngineFactory engineFactory,
    required String appVersion,
    List<BundledExtension>? extensions,
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    final bundled = extensions ?? await loadBundledExtensions(onError: onError);
    final usable = <BundledExtension>[];
    final sources = <SourceDescription>[
      const SourceDescription(
        id: localSourceId,
        key: 'local',
        name: 'Local files',
        lang: 'und',
        capabilities: {},
      ),
    ];
    for (final extension in bundled) {
      final manifest = extension.manifest;
      final refusal = _refusalFor(manifest, appVersion);
      if (refusal != null) {
        onError?.call(refusal, StackTrace.current);
        continue;
      }
      usable.add(extension);
      for (final source in manifest.sources) {
        sources.add(
          SourceDescription(
            id: source.idWithin(manifest.id),
            key: source.key,
            name: source.name,
            lang: source.lang,
            capabilities: manifest.declaredCapabilities,
            extensionId: manifest.id,
            contentRating: manifest.contentRating.name,
          ),
        );
      }
    }

    for (final source in sources) {
      await registerSource(
        database,
        id: source.id,
        key: source.key,
        name: source.name,
        lang: source.lang,
        extensionId: source.extensionId,
        contentRating: source.contentRating,
      );
    }

    return SourceRegistry._(
      database,
      network,
      store,
      log,
      host,
      engineFactory,
      usable,
      sources,
    );
  }

  /// Why this app cannot run [manifest], or null when it can (§3.7).
  static ExtensionLoadException? _refusalFor(
    ExtensionManifest manifest,
    String appVersion,
  ) {
    final reason = switch (manifest.compatibility()) {
      ApiCompatibility.supported => null,
      ApiCompatibility.needsNewerApp =>
        'it targets SourceAPI ${manifest.apiVersion}, and this app implements '
            '$apiVersion',
      ApiCompatibility.obsolete =>
        'it targets SourceAPI ${manifest.apiVersion}, which this app no longer '
            'supports',
    };
    if (reason != null) return ExtensionLoadException(manifest.id, reason);
    // The app's own version may carry a build number, which is not part of the comparison.
    final version = SoftwareVersion.parse(appVersion.split('+').first);
    if (!manifest.runsOn(version)) {
      return ExtensionLoadException(
        manifest.id,
        'it needs Kikuyomi ${manifest.minAppVersion} or newer, and this is '
        '$version',
      );
    }
    return null;
  }

  final KikuyomiDatabase _database;
  final NetworkService _network;
  final ExtensionStore _store;
  final ExtensionLogSink _log;
  final HostFacts _host;
  final ScriptEngineFactory _engineFactory;
  final Map<String, BundledExtension> _extensions;
  final List<SourceDescription> _sources;

  /// The worker of each extension that has been used, and the one being started. Kept as a future,
  /// so two screens opening a source at once join one start rather than racing to make two
  /// runtimes.
  final _workers = <String, Future<ExtensionWorker>>{};
  final _opened = <int, ContentSource>{};

  /// Every source, Local first and then the extensions' in manifest order.
  List<SourceDescription> get sources => _sources;

  /// The sources a listener can browse.
  List<SourceDescription> get browsable => [
    for (final source in _sources)
      if (source.canBrowse) source,
  ];

  SourceDescription? describe(int sourceId) =>
      _sources.where((source) => source.id == sourceId).firstOrNull;

  /// Opens the source with [sourceId], starting its extension's runtime if this is its first use.
  ///
  /// Throws [ExtensionLoadException] when the extension will not load, [ArgumentError] for a source
  /// this app does not know, and [UnsupportedError] for one that has no `ContentSource` yet, which
  /// today is only Local files.
  Future<ContentSource> open(int sourceId) async {
    final opened = _opened[sourceId];
    if (opened != null) return opened;

    final description = describe(sourceId);
    if (description == null) {
      throw ArgumentError.value(sourceId, 'sourceId', 'no such source');
    }
    final extensionId = description.extensionId;
    if (extensionId == null) {
      throw UnsupportedError(
        '"${description.name}" has no catalogue to browse: its books come from '
        'this device',
      );
    }
    final worker = await _workerFor(extensionId);
    final source = await JsSourceAdapter.open(
      runtime: worker,
      sourceKey: description.key,
    );
    return _opened[sourceId] = source;
  }

  Future<ExtensionWorker> _workerFor(String extensionId) {
    final running = _workers[extensionId];
    if (running != null) return running;
    final extension = _extensions[extensionId];
    if (extension == null) {
      throw ExtensionLoadException(extensionId, 'it is not installed');
    }
    final starting = ExtensionWorker.start(
      engineFactory: _engineFactory,
      bundle: ExtensionBundle(
        extensionId: extensionId,
        code: extension.code,
        domains: extension.manifest.domains,
      ),
      host: _host,
      bridges: [
        HttpBridge(
          client: httpClientFor(extensionId),
          domains: extension.manifest.domains,
        ),
        StorageBridge(extensionId: extensionId, store: _store),
        LogBridge(extensionId: extensionId, sink: _log),
      ],
    );
    // A start that fails is not remembered, so the next attempt tries again rather than handing
    // back the same failure for the life of the app.
    _workers[extensionId] = starting.catchError((Object error) {
      _workers.remove(extensionId);
      throw error;
    });
    return _workers[extensionId]!;
  }

  /// The transport one extension sees: its own cookie jar and its own rate limits (§2.7). Also what
  /// fetches its covers, so a cover is asked for as politely as a page.
  SourceHttpClient httpClientFor(String extensionId) =>
      _network.clientFor(extensionId);

  /// The extension behind [sourceId], or null for a built-in source.
  String? extensionIdOf(int sourceId) => describe(sourceId)?.extensionId;

  /// Every URL the extension behind [sourceId] may be fetched at, or null for a built-in source.
  ///
  /// SourceAPI 1.0 holds cover URLs to the manifest's domains as it holds `http.fetch`, "so the
  /// domains shown on the permissions screen before install are every domain the source can make the
  /// app contact". A cover the app fetches is the app contacting a domain, so it is checked here
  /// too, and again on every redirect.
  DomainAllowlist? domainsOf(int sourceId) {
    final extensionId = extensionIdOf(sourceId);
    return extensionId == null
        ? null
        : _extensions[extensionId]?.manifest.domains;
  }

  /// How to fetch the cover at [url] for a book of [sourceId]: through the source's own
  /// `getImageRequest` when it declares one, and a plain GET otherwise.
  ///
  /// §6.3: "Many sources require specific headers (a referer, a token, cookies)." A source that
  /// needs none declares no `imageRequest` capability, and then nothing is asked of the extension
  /// at all — which is the whole point of declaring capabilities rather than calling to find out.
  Future<HttpRequest> imageRequestFor(int sourceId, Uri url) async {
    final description = describe(sourceId);
    if (description == null ||
        !description.capabilities.contains(SourceCapability.imageRequest)) {
      return HttpRequest(url: url);
    }
    final source = await open(sourceId);
    if (!source.capabilities.contains(SourceCapability.imageRequest)) {
      return HttpRequest(url: url);
    }
    return source.getImageRequest(url);
  }

  /// Stops every runtime. The app does this as it closes; a pool will do it on eviction.
  Future<void> dispose() async {
    final workers = List.of(_workers.values);
    _workers.clear();
    _opened.clear();
    for (final worker in workers) {
      try {
        await (await worker).dispose();
      } catch (_) {
        // A worker that never started has nothing to stop.
      }
    }
  }

  /// The database rows are written by [open]; kept for callers that want the same connection.
  KikuyomiDatabase get database => _database;
}
