import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import 'routes.dart';

class KikuyomiApp extends ConsumerStatefulWidget {
  const KikuyomiApp({super.key, this.openOnLaunch});

  /// A book file or folder passed on the command line, to import and open at start. Also how the
  /// app is driven by automated checks, since a file dialog cannot be scripted.
  final String? openOnLaunch;

  @override
  ConsumerState<KikuyomiApp> createState() => _KikuyomiAppState();
}

class _KikuyomiAppState extends ConsumerState<KikuyomiApp> {
  final _navigator = GlobalKey<NavigatorState>();

  /// Made once and kept for the life of the app, so rebuilding the app never loses the screens the
  /// listener has open.
  late final GoRouter _router = createRouter(navigatorKey: _navigator);
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      // §6.4: progress is saved the moment the app leaves the screen, because the system may end it
      // there without warning. Playback carries on.
      onHide: () =>
          unawaited(ref.read(servicesProvider).coordinator.onBackgrounded()),
      // Books may have been copied into the import folder while the app was away.
      onResume: _lookForNewBooks,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Covers for books added before covers were kept wait for the first look in the import
      // folder, whose new books bring their own, so start-up does the one thing at a time.
      unawaited(_lookForNewBooks().then((_) => _lookForMissingCovers()));
      final path = widget.openOnLaunch;
      if (path != null) unawaited(_open(path));
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _router.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    final services = ref.read(servicesProvider);
    try {
      final bookId = await FileSystemEntity.isDirectory(path)
          ? (await services.addFolderBook(path)).bookId
          : await services.addBookInPlace(path);
      await services.openBook(bookId);
      await _router.push<void>(const PlayerRoute().location);
    } catch (error) {
      _tell('Could not open $path: $error');
    }
  }

  /// Adds any books copied into the import folder (§5.1), and says so when there were some.
  Future<void> _lookForNewBooks() async {
    try {
      final added = await ref.read(servicesProvider).scanImportFolder();
      if (added > 0) {
        _tell(
          added == 1
              ? 'Added a book from the Import folder'
              : 'Added $added books from the Import folder',
        );
      }
    } catch (error) {
      _tell('Could not look for new books: $error');
    }
  }

  /// Looks, in the background, for the covers of books whose cover was never looked for. Quietly:
  /// a book shown without its cover is not worth interrupting the listener over, so a failure is
  /// only reported the way Flutter reports errors, for whoever is developing the app.
  Future<void> _lookForMissingCovers() async {
    void report(Object error, StackTrace stack) => FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'kikuyomi',
        context: ErrorDescription("while looking for a book's cover"),
      ),
    );
    try {
      await ref.read(servicesProvider).lookForMissingCovers(onError: report);
    } catch (error, stack) {
      report(error, stack);
    }
  }

  void _tell(String message) {
    final context = _navigator.currentContext;
    if (context != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3949AB);
    return MaterialApp.router(
      title: 'Kikuyomi',
      routerConfig: _router,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
    );
  }
}
