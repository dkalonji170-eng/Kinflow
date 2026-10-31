import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'home_screen.dart';
import 'auth_screen.dart';
import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import '../theme/theme_provider.dart';
import '../widgets/logo_kinflow.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    verifierProfil();
  }

  Future<void> verifierProfil() async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    await Future.delayed(const Duration(seconds: 2));

    String? nom;
    bool? modeSombre;

    // 1) Compte déjà lié à cet appareil : on ouvre directement l'accueil,
    //    instantanément et même hors ligne, sans attendre Supabase. C'est ce
    //    qui évite de renvoyer un utilisateur connu vers inscription/connexion.
    try {
      final compteLocal = await SupabaseService().lireCompteLieLocal();
      final nomLocal = (compteLocal['nom'] ?? '').trim();
      if (nomLocal.isNotEmpty) {
        nom = nomLocal;
        final cache = await SupabaseService().chargerProfilCache();
        modeSombre = cache?['mode_sombre'] as bool?;
        Journal.i('DEMARRAGE', 'Compte retrouvé depuis le cache local', {
          'nom': nomLocal,
        });
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur cache local: $e');
    }

    // 2) Aucun compte local : on interroge Supabase (première session
    //    restaurée par le SDK, ou compte non encore mis en cache).
    if ((nom ?? '').isEmpty) {
      try {
        await SupabaseService().ready.timeout(const Duration(seconds: 25));
      } catch (e) {
        debugPrint('[KinFlow] Supabase non prêt: $e');
        Journal.a('DEMARRAGE', 'Serveur non prêt à l\'ouverture', {
          'erreur': '$e',
        });
      }

      try {
        final profile = await SupabaseService().loadProfile().timeout(
          const Duration(seconds: 10),
        );
        final nomServeur = (profile?['nom'] as String? ?? '').trim();
        if (nomServeur.isNotEmpty) {
          nom = nomServeur;
          modeSombre = profile?['mode_sombre'] as bool?;
        }
      } catch (e) {
        debugPrint('[KinFlow] Erreur chargement profil: $e');
        Journal.a('DEMARRAGE', 'Profil illisible à l\'ouverture', {
          'erreur': '$e',
        });
      }
    }

    // 3) Dernier repli : le drapeau « compte lié » posé localement.
    if ((nom ?? '').isEmpty) {
      try {
        if (await SupabaseService().estCompteLie()) {
          final compteLocal = await SupabaseService().lireCompteLieLocal();
          nom = (compteLocal['nom'] ?? '').trim();
        }
      } catch (_) {}
    }

    // Première ouverture (aucun compte) : thème blanc.
    // Compte connecté : son thème enregistré.
    themeProvider.appliquerTheme(modeSombre ?? false);

    if (!mounted) return;

    if (nom == null || nom.isEmpty) {
      Journal.i('ECRAN', 'Redirection vers l\'écran d\'inscription');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const AuthScreen()),
      );
    } else {
      Journal.i('ECRAN', 'Redirection vers l\'accueil (compte : $nom)');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Transform.translate(
          offset: const Offset(0, -40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [const LogoKinflow(hauteur: 90)],
          ),
        ),
      ),
    );
  }
}
