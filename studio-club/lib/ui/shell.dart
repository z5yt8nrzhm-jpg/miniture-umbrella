/// The signed-in app: four tabs, plus a front-desk tab for staff.
library;

import 'package:flutter/material.dart';

import '../state/club_controller.dart';
import 'checkin.dart';
import 'home.dart';
import 'me.dart';
import 'staff.dart';
import 'wall.dart';

class ClubShell extends StatefulWidget {
  const ClubShell({super.key, required this.controller, this.demo = false});
  final ClubController controller;
  final bool demo;
  @override
  State<ClubShell> createState() => _ClubShellState();
}

class _ClubShellState extends State<ClubShell> {
  int _i = 0;
  static const _wallIndex = 2;

  @override
  void dispose() {
    widget.controller.setWallVisible(false);
    super.dispose();
  }

  void _go(int i) {
    setState(() => _i = i);
    widget.controller.setWallVisible(i == _wallIndex);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final pages = <Widget>[
            HomeScreen(controller: c),
            CheckInScreen(controller: c),
            WallScreen(controller: c),
            MeScreen(controller: c, demo: widget.demo),
            if (c.isStaff) StaffScreen(controller: c),
          ];
          final index = _i.clamp(0, pages.length - 1);
          return Scaffold(
            body: SafeArea(bottom: false, child: IndexedStack(index: index, children: pages)),
            bottomNavigationBar: NavigationBar(
              selectedIndex: index,
              onDestinationSelected: _go,
              destinations: [
                const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'HOME'),
                const NavigationDestination(icon: Icon(Icons.check_circle_outline), selectedIcon: Icon(Icons.check_circle), label: 'CHECK IN'),
                NavigationDestination(
                  icon: Badge(isLabelVisible: c.pending.isNotEmpty, label: Text('${c.pending.length}'), child: const Icon(Icons.chat_bubble_outline)),
                  selectedIcon: const Icon(Icons.chat_bubble), label: 'WALL',
                ),
                const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'ME'),
                if (c.isStaff) const NavigationDestination(icon: Icon(Icons.badge_outlined), selectedIcon: Icon(Icons.badge), label: 'DESK'),
              ],
            ),
          );
        },
      );
}
