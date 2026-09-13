import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_screen.dart';
import 'player_screen.dart';
import 'providers.dart';

class KikuyomiApp extends ConsumerStatefulWidget {
  const KikuyomiApp({super.key, this.openOnLaunch});

  /// A book file passed on the command line, to import and open at start. Also how the app is
  /// driven by automated checks, since a file dialog cannot be scripted.
  final String? openOnLaunch;

  @override
  ConsumerState<KikuyomiApp> createState() => _KikuyomiAppState();
}

class _KikuyomiAppState extends ConsumerState<KikuyomiApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    final path = widget.openOnLaunch;
    if (path != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(path));
    }
  }

  Future<void> _open(String path) async {
    final services = ref.read(servicesProvider);
    try {
      final bookId = await services.addBookInPlace(path);
      await services.openBook(bookId);
      await _navigator.currentState?.push(PlayerScreen.route());
    } catch (error) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open $path: $error')));
      }
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
