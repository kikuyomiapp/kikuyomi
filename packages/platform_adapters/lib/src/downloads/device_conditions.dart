/// What the device can offer the download queue right now (§5.2).
///
/// The scheduler applies a network policy and a free-space floor, and neither is something pure Dart
/// can answer. This is the adapter that does, and it answers one of them honestly and the other
/// honestly too — by saying it cannot.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';
import 'package:kikuyomi_downloads/kikuyomi_downloads.dart';

/// Reads the connection and the disk for the download driver.
final class DeviceConditionsSource {
  DeviceConditionsSource({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// What the driver asks each pass.
  Future<DeviceConditions> read() async =>
      (network: await networkKind(), freeSpaceBytes: await freeSpaceBytes());

  /// A signal every time the connection changes, so the queue can be pumped rather than waited on.
  ///
  /// A listener who walks into Wi-Fi expects the book they queued on the train to start, and a poll
  /// every minute would make that a minute of nothing happening for no reason.
  Stream<void> get changes => _connectivity.onConnectivityChanged.map((_) {});

  /// What kind of connection this is (§5.2).
  ///
  /// Mobile is the one case that is certainly metered. Wi-Fi, Ethernet and the rest are taken as
  /// unmetered, which is the ordinary truth and occasionally wrong — a phone sharing its connection
  /// looks like Wi-Fi to everything above the system. Android can be asked properly, and that is the
  /// obvious improvement here; until then the listener's own setting is the backstop, since they can
  /// turn the policy off when they know better than the app does.
  Future<NetworkKind> networkKind() async {
    final results = await _connectivity.checkConnectivity();
    if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
      return NetworkKind.none;
    }
    final unmetered = results.any(
      (result) =>
          result == ConnectivityResult.wifi ||
          result == ConnectivityResult.ethernet,
    );
    if (unmetered) return NetworkKind.unmetered;
    return results.any((r) => r == ConnectivityResult.mobile)
        ? NetworkKind.metered
        : NetworkKind.unmetered;
  }

  /// What is left on the device, or null because nothing here can say yet.
  ///
  /// Measuring it takes a platform call — `StatFs` on Android, `statvfs` on Apple platforms,
  /// `GetDiskFreeSpaceEx` on Windows — and the packages that wrap those support Android and iOS and
  /// stop there, which fails CLAUDE.md's rule that a dependency must cover Windows as well. So this
  /// says it does not know, and §5.2's floor is simply not applied.
  ///
  /// That is a real answer rather than a missing one, and the queue is built to take it: a file whose
  /// size the site has not stated is let through the same check for the same reason. What is lost is
  /// the courtesy of stopping before the disk fills; what still stops it is the transport failing when
  /// there is no room, which is a worse message and not a worse outcome.
  ///
  /// The known alternative, when this matters enough: `dart:ffi` for `GetDiskFreeSpaceExW` on Windows
  /// and a method channel for the two mobile platforms. A day's work, and nothing above this file
  /// changes when it lands.
  Future<int?> freeSpaceBytes() async => null;
}
