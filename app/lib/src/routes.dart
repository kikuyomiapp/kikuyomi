import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'book_details_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';
import 'restore_screen.dart';
import 'settings_screen.dart';

part 'routes.g.dart';

/// The router the app runs on (ADR-0005), starting at [initialLocation].
///
/// Routes are typed: a screen's arguments are fields of its route, checked when the app is compiled
/// rather than parsed out of strings when it runs. Routing is confined to `app`, as ADR-0005
/// requires, so no package below it knows how screens are reached.
///
/// A route's location is its address within the app. §2.6's `kikuyomi://` deep links will resolve
/// through these same routes once the platforms register the scheme. A link meant for sharing will
/// then need a book's global identity, its source and key (§4.4), rather than the database id
/// [BookRoute] carries, which means nothing on another device.
GoRouter createRouter({
  GlobalKey<NavigatorState>? navigatorKey,
  String initialLocation = '/',
}) => GoRouter(
  navigatorKey: navigatorKey,
  initialLocation: initialLocation,
  routes: $appRoutes,
  errorBuilder: (context, state) =>
      _NotFoundScreen(location: state.uri.toString()),
);

/// The home: Continue Listening above the library.
///
/// The book and player routes sit under it, so a book reached by its location alone still has the
/// library beneath it to go back to.
@TypedGoRoute<HomeRoute>(
  path: '/',
  routes: [
    TypedGoRoute<BookRoute>(path: r'book/:bookId(\d+)'),
    TypedGoRoute<PlayerRoute>(path: 'player'),
    TypedGoRoute<SettingsRoute>(
      path: 'settings',
      routes: [TypedGoRoute<RestoreRoute>(path: 'restore')],
    ),
  ],
)
class HomeRoute extends GoRouteData with $HomeRoute {
  const HomeRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const LibraryScreen();
}

/// A book's details.
class BookRoute extends GoRouteData with $BookRoute {
  const BookRoute({required this.bookId});

  /// The book's id in this device's database.
  final int bookId;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      BookDetailsScreen(bookId: bookId);
}

/// The player, showing the book the coordinator has open.
class PlayerRoute extends GoRouteData with $PlayerRoute {
  const PlayerRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const PlayerScreen();
}

/// Settings, from the home's app bar. There is no tabbed shell yet, so it sits above the home.
class SettingsRoute extends GoRouteData with $SettingsRoute {
  const SettingsRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const SettingsScreen();
}

/// Restoring from a backup, from Settings.
class RestoreRoute extends GoRouteData with $RestoreRoute {
  const RestoreRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const RestoreScreen();
}

/// What a location no route matches shows, such as a link written by a newer version of the app.
class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'There is nothing at $location',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => const HomeRoute().go(context),
                child: const Text('Go to the library'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
