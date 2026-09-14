import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_screen.dart';
import 'player_screen.dart';
import 'providers.dart';

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
      unawaited(_lookForNewBooks());
      final path = widget.openOnLaunch;
      if (path != null) unawaited(_open(path));
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    final services = ref.read(servicesProvider);
    try {
      final bookId = await FileSystemEntity.isDirectory(path)
          ? (await services.addFolderBook(path)).bookId
          : await services.addBookInPlace(path);
      await services.openBook(bookId);
      await _navigator.currentState?.push(PlayerScreen.route());
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
    return MaterialApp(
      title: 'Kikuyomi',
      navigatorKey: _navigator,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const LibraryScreen(),
    );
  }
}
