import 'package:flutter/foundation.dart';
import 'package:kikuyomi_domain/kikuyomi_domain.dart';

/// Whether the app offers to set up backups at start.
enum SetupOffer {
  /// Not decided yet. The app shows what it would anyway.
  undecided,

  /// The setup screen is offered, and the router keeps the app on it until it is finished.
  offered,

  /// Not offered, or finished.
  notOffered,
}

/// Decides, once, at start, whether to offer backup setup, and tells the router, which redirects to
/// the setup screen while it is offered (see `setupRedirect` in `routes.dart`).
///
/// The decision is made after the first frame rather than before it, since it needs the database,
/// and the router's `refreshListenable` carries the app to the setup screen once it is made. That
/// costs a moment of the home before setup appears, which a fresh install spends loading an empty
/// library anyway, and keeps start-up waiting on nothing.
class SetupGate extends ChangeNotifier {
  SetupOffer _offer = SetupOffer.undecided;

  SetupOffer get offer => _offer;

  /// Decides whether to offer setup, by [shouldOffer], unless it was decided already. A decision
  /// that fails offers nothing, and the failure is rethrown for reporting.
  Future<void> decide(Future<bool> Function() shouldOffer) async {
    if (_offer != SetupOffer.undecided) return;
    bool offered;
    try {
      offered = await shouldOffer();
    } catch (_) {
      _settle(SetupOffer.notOffered);
      rethrow;
    }
    _settle(offered ? SetupOffer.offered : SetupOffer.notOffered);
  }

  /// Setup is done, or skipped: the app goes to the home, and it is not offered again.
  void finish() => _settle(SetupOffer.notOffered, evenIfDecided: true);

  void _settle(SetupOffer offer, {bool evenIfDecided = false}) {
    if (_offer == offer) return;
    if (_offer != SetupOffer.undecided && !evenIfDecided) return;
    _offer = offer;
    notifyListeners();
  }
}

/// Whether to offer backup setup at start: when the library is empty, as on a fresh install, and
/// setup was neither completed nor skipped, and no backup folder is set.
///
/// Where this device cannot choose a folder, as on iOS for now, there is nothing to offer: neither
/// choosing a folder nor restoring from one could work.
Future<bool> shouldOfferSetup({
  required SettingsStore settings,
  required bool canChooseFolder,
  required Future<bool> Function() libraryIsEmpty,
}) async =>
    canChooseFolder &&
    settings.read(AppSettings.backupSetup) == null &&
    settings.read(AppSettings.backupFolder) == null &&
    await libraryIsEmpty();
