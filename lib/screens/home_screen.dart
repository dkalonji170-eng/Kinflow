import 'dart:async';

import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import '../services/position_partage_service.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/logo_kinflow.dart';
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

  /// Nombre total de notifications (nouvelles infos + messages non lus +
  /// demandes d'amis) : affiché en rouge sur le bouton « Social » (0 = pas de
  /// badge).
  int _nouvelles = 0;
  Timer? _minuteur;

  /// Avatar (animal) choisi par l'utilisateur : affiché en haut à gauche de
  /// l'AppBar comme icône du profil. Vide tant que le profil n'est pas chargé.
  String _avatar = '';

  @override
  void initState() {
    super.initState();
    _actualiserBadge();
    _chargerAvatar();
    PositionPartageService.instance.start();
    _minuteur = Timer.periodic(
      _rafraichissementBadge,
      (_) => _actualiserBadge(),
    );
  }

  Future<void> _chargerAvatar() async {
    try {
      final profile = await SupabaseService().loadProfile();
      if (!mounted) return;
      final avatar = profile?['avatar'] as String? ?? '';
      if (avatar != _avatar) setState(() => _avatar = avatar);
    } catch (e) {
      debugPrint('[KinFlow] Erreur avatar AppBar : $e');
    }
  }

  /// Ouvre le profil ; à son retour (l'animal a pu changer dans « Modifier
  /// le profil »), recharge l'avatar pour le garder à jour.
  Future<void> _ouvrirProfil() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ProfileScreen()),
    );
    _chargerAvatar();
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    super.dispose();
  }

  /// Le badge du bouton « Social » additionne tout ce qui est une
  /// notification : nouvelles informations du fil + messages non lus +
  /// demandes d'amis reçues. Chaque élément compte pour +1.
  Future<void> _actualiserBadge() async {
    final service = SupabaseService();
    final dernierVu = await service.lireDernierVuFil();

    final resultats = await Future.wait<Object?>([
      dernierVu == null
          ? Future<int>.value(0)
          : service.compterNouvellesInfos(dernierVu),
      service.nbMessagesNonLusAmis(),
      service.mesDemandesAmis(),
    ]);

    final nouvellesInfos = resultats[0] as int? ?? 0;
    final nonLus = resultats[1] as Map<String, int>? ?? const {};
    final demandes = resultats[2] as List<Map<String, dynamic>>? ?? const [];

    final total = nouvellesInfos +
        nonLus.values.fold<int>(0, (s, v) => s + v) +
        demandes.length;

    if (!mounted) return;
    setState(() => _nouvelles = total);
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
      backgroundColor: Theme.of(context).colorScheme.surface,
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
        title: const LogoKinflow(hauteur: 54),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _ouvrirProfil,
            iconSize: 34,
            icon: AvatarAnimalWidget(
              taille: 34,
              avatarId: _avatar.isEmpty ? null : _avatar,
            ),
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
                    fontSize: 15,
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
                            fontSize: 9,
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
