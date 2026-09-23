import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'routes.dart';

/// The tabs of §2.6's adaptive shell, as far as there is one.
///
/// §2.6 has four — Library, Home, Browse and More — with Continue Listening on Home and Settings
/// under More. Two exist so far: the library, which is still Home and Library in one screen, and
/// Browse. Settings stays where it is, in the library's app bar, until More has more than it in it.
enum AppTab {
  library('Library', Icons.library_books_outlined, Icons.library_books),
  browse('Browse', Icons.explore_outlined, Icons.explore);

  const AppTab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Where the tab goes. Browse sits under the home, so leaving it goes back to the library rather
  /// than out of the app.
  String get location => switch (this) {
    AppTab.library => const HomeRoute().location,
    AppTab.browse => const BrowseRoute().location,
  };
}

/// The width at which the bottom bar becomes a rail.
///
/// §2.6: "Phones get a bottom navigation bar; wide windows (Windows desktop, tablets) get a
/// navigation rail or side panel." 700 logical pixels is about where a phone in landscape and a
/// small tablet part company, and it is the same figure the player uses to put its chapter list in a
/// side panel.
const shellRailBreakpoint = 700.0;

/// A screen inside the tabbed shell.
///
/// The shell is the Scaffold, so each screen passes what belongs to it — its app bar, its body, its
/// floating button — and the navigation is drawn once, here. Tapping a tab goes to that tab's
/// location rather than pushing it, so the stack never fills with tabs.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.tab,
    required this.body,
    this.appBar,
    this.floatingActionButton,
  });

  final AppTab tab;
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= shellRailBreakpoint;
    void go(int index) {
      final chosen = AppTab.values[index];
      if (chosen != tab) context.go(chosen.location);
    }

    return Scaffold(
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: tab.index,
                  onDestinationSelected: go,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final tab in AppTab.values)
                      NavigationRailDestination(
                        icon: Icon(tab.icon),
                        selectedIcon: Icon(tab.selectedIcon),
                        label: Text(tab.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab.index,
              onDestinationSelected: go,
              destinations: [
                for (final tab in AppTab.values)
                  NavigationDestination(
                    icon: Icon(tab.icon),
                    selectedIcon: Icon(tab.selectedIcon),
                    label: tab.label,
                  ),
              ],
            ),
    );
  }
}
