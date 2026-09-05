import 'package:flutter/material.dart';

import 'profile_screen.dart';
import 'settings_screen.dart';
import 'traffic_screen.dart';

/// Hôte principal de l'application : regroupe les trois espaces dans une
/// barre de navigation basse (Carte, Profil, Réglages).
///
/// L'[IndexedStack] conserve l'état de chaque écran lors des changements
/// d'onglet : la carte, le suivi GPS et les téléchargements restent actifs.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.ongletInitial = 0});

  final int ongletInitial;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _onglet;

  @override
  void initState() {
    super.initState();
    _onglet = widget.ongletInitial;
  }

  void changerOnglet(int index) {
    if (index == _onglet) return;
    setState(() => _onglet = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _onglet,
        children: const [
          TrafficScreen(),
          ProfileScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _onglet,
        onDestinationSelected: changerOnglet,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map_rounded),
            label: 'Carte',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profil',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Réglages',
          ),
        ],
      ),
    );
  }
}