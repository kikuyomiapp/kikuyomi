import 'package:flutter/material.dart';

/// A snack bar saying [message] and offering [action].
///
/// Flutter keeps a snack bar with an action on screen until the action is taken. This one goes after
/// the usual few seconds instead, so that changes made one after another, such as bookmarks added in
/// the player, do not leave a message standing over the controls. Someone using a screen reader or
/// switch access may need longer to reach the action, so for them it stays, with a button to close
/// it.
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
    persist: assisted,
    showCloseIcon: assisted,
  );
}

/// Says [message] in a plain snack bar, such as what went wrong.
void tellInSnackBar(ScaffoldMessengerState messenger, String message) =>
    messenger.showSnackBar(SnackBar(content: Text(message)));
