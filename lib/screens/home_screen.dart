import 'dart:async';

import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import 'fil_ville_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'traffic_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const Duration _rafraichissementBadge = Duration(seconds: 60);

  /// Nombre d'infos du Fil Social arrivées depuis la dernière visite :
  /// affiché en rouge sur le bouton « Social » (0 = pas de badge).
  int _nouvelles = 0;
  Timer? _minuteur;

  @override
  void initState() {
    super.initState();
    _actualiserBadge();
    _minuteur = Timer.periodic(
      _rafraichissementBadge,
      (_) => _actualiserBadge(),
    );
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    super.dispose();
  }

  Future<void> _actualiserBadge() async {
    final service = SupabaseService();
    final dernierVu = await service.lireDernierVuFil();
    if (dernierVu == null) {
      if (!mounted) return;
      setState(() => _nouvelles = 0);
      return;
    }
    final compteur = await service.compterNouvellesInfos(dernierVu);
    if (!mounted) return;
    setState(() => _nouvelles = compteur);
  }

  Future<void> _ouvrirSocial() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const FilVilleScreen()),
    );
    // De retour : le fil a marqué les infos comme vues → le badge retombe à 0.
    _actualiserBadge();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            );
          },
          icon: const Icon(Icons.settings),
          tooltip: 'Réglages',
        ),
        title: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Image.asset(
            Theme.of(context).brightness == Brightness.dark
                ? "assets/kinflow_dark.jpg"
                : "assets/kinflow.jpg",
            height: 70,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
            icon: const Icon(Icons.person),
            tooltip: 'Profil',
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 90, color: Colors.blue),
              const SizedBox(height: 20),
              Text(
                "Bienvenue sur KinFlow",
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "La circulation intelligente de Kinshasa",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 40),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const TrafficScreen(),
                    ),
                  );
                },
                child: const Text("Voir le trafic"),
              ),
              const SizedBox(height: 12),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: _ouvrirSocial,
                    child: const Text("Social"),
                  ),
                  if (_nouvelles > 0)
                    Positioned(
                      right: -8,
                      top: -8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        constraints: const BoxConstraints(minWidth: 20),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                        child: Text(
                          _nouvelles > 99 ? '99+' : '$_nouvelles',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}