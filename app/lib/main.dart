import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kikuyomi_platform_adapters/kikuyomi_platform_adapters.dart';

import 'src/app.dart';
import 'src/launch_arguments.dart';
import 'src/providers.dart';
import 'src/services.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  JustAudioEngine.initialize();
  final arguments = LaunchArguments.parse(args);
  final services = await AppServices.open();
  runApp(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: KikuyomiApp(
        openOnLaunch: arguments.openOnLaunch,
        installExtensionsFrom: arguments.extensionFolders,
      ),
    ),
  );
}
