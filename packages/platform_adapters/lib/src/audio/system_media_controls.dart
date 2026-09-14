import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kikuyomi_playback/kikuyomi_playback.dart';

import 'audio_service_bridge.dart';
import 'smtc_bridge.dart';

/// §6.5's system media controls, from whichever platform integration this device has, so that the
/// composition root never asks which platform it runs on.
///
/// Android and iOS get [AudioServiceBridge]: the notification, the lock screen, Now Playing and
/// Bluetooth buttons. Windows gets SMTC's media keys and volume flyout through `SmtcBridge`.
abstract final class SystemMediaControls {
  /// Starts the controls. Call once, at start.
  ///
  /// [skipInterval] is what the skip buttons are labelled with where the platform shows a number,
  /// as Android's notification and iOS's lock screen do. The move itself is made by
  /// `MediaSessionSync`, so Windows, which shows none, has no use for it.
  ///
  /// On Windows, controls that fail to start are reported and left out, and the app runs without
  /// them: a media key that does nothing must not stop anyone listening.
  static Future<MediaSessionBridge> start({
    required Duration skipInterval,
  }) async {
    if (!Platform.isWindows) {
      return AudioServiceBridge.start(skipInterval: skipInterval);
    }
    try {
      return await SmtcBridge.start();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'kikuyomi_platform_adapters',
          context: ErrorDescription(
            'while starting the Windows media controls',
          ),
        ),
      );
      return const _NoControls();
    }
  }
}

/// Controls that show nothing and never press a button.
final class _NoControls implements MediaSessionBridge {
  const _NoControls();

  @override
  Stream<MediaCommand> get commands => const Stream.empty();

  @override
  void update(MediaSessionState? state) {}
}
