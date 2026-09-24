/// Every snack bar the app shows, so that how long they stay and what they look like is decided in
/// one place rather than at fifteen call sites.
///
/// Three things were wrong when each screen built its own. A snack bar carrying an action stays until
/// the action is taken, so "Added … to the library" had to be swiped away by hand. Nothing set a
/// duration, so the rest sat for Flutter's default four seconds. And nothing cleared the one before
/// it, so a handful of changes in a row queued up and each had to be waited out.
library;

import 'package:flutter/material.dart';

/// How long a plain notice stays: long enough to read six words, short enough not to be in the way.
const snackBarNotice = Duration(seconds: 2);

/// How long a notice offering an action stays.
///
/// A second more than a plain one, because it has to be reachable: a button that disappears before it
/// can be pressed is worse than no button. Someone using a screen reader or switch access gets longer
/// still — see [offeringSnackBar].
const snackBarOffer = Duration(seconds: 3);

/// What every snack bar looks like: floating, rounded and inset from the edges, rather than a square
/// bar welded to the bottom of the window.
///
/// Set on the app's theme, so snack bars built anywhere get it.
const kikuyomiSnackBarTheme = SnackBarThemeData(
  behavior: SnackBarBehavior.floating,
  insetPadding: EdgeInsets.all(16),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
  ),
  elevation: 3,
);

/// A snack bar saying [message] and offering [action].
///
/// Flutter keeps a snack bar with an action on screen until the action is taken. This one goes after
/// [snackBarOffer] instead, so that changes made one after another, such as bookmarks added in the
/// player, do not leave a message standing over the controls. Someone using a screen reader or switch
/// access may need longer to reach the action, so for them it stays, with a button to close it.
SnackBar offeringSnackBar(
  BuildContext context, {
  required String message,
  required String action,
  required VoidCallback onPressed,
}) {
  final assisted = MediaQuery.accessibleNavigationOf(context);
  return SnackBar(
    content: Text(message),
    action: SnackBarAction(label: action, onPressed: onPressed),
    duration: snackBarOffer,
    persist: assisted,
    showCloseIcon: assisted,
  );
}

/// Says [message] in a plain snack bar, such as what went wrong.
///
/// Replaces whatever is showing rather than queueing behind it: when several things happen at once —
/// three books added, two covers that could not be fetched — the newest is the one worth reading, and
/// a queue would make the listener wait out all of them.
void tellInSnackBar(ScaffoldMessengerState messenger, String message) =>
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: snackBarNotice),
      );

/// Says [message] and offers [action], replacing whatever is showing.
///
/// The counterpart of [tellInSnackBar] for the notices that offer something to do next.
void offerInSnackBar(
  BuildContext context,
  ScaffoldMessengerState messenger, {
  required String message,
  required String action,
  required VoidCallback onPressed,
}) => messenger
  ..removeCurrentSnackBar()
  ..showSnackBar(
    offeringSnackBar(
      context,
      message: message,
      action: action,
      onPressed: onPressed,
    ),
  );
