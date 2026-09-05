import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'home_screen.dart';
import 'auth_screen.dart';
import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import '../theme_provider.dart';

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

    try {
      await SupabaseService().ready.timeout(const Duration(seconds: 25));
    } catch (e) {
      debugPrint('[KinFlow] Supabase non prêt: $e');
      Journal.a('DEMARRAGE', 'Serveur non prêt à l\'ouverture', {
        'erreur': '$e',
      });
    }

    String? nom;
    bool? modeSombre;
    try {
      final profile = await SupabaseService().loadProfile().timeout(
        const Duration(seconds: 10),
      );
      nom = profile?['nom'] as String? ?? '';
      modeSombre = profile?['mode_sombre'] as bool?;
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargement profil: $e');
      Journal.a('DEMARRAGE', 'Profil illisible à l\'ouverture', {
        'erreur': '$e',
      });
    }

    // Première ouverture (aucun compte) : thème blanc.
    // Compte connecté : son thème enregistré.
    themeProvider.appliquerTheme(modeSombre ?? false);

    if (!mounted) return;

    if (nom == null) {
      Journal.i(
        'ECRAN',
        'Redirection vers l\'accueil (aucun profil lié à cet appareil)',
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
      return;
    }

    if (nom.isEmpty) {
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
      body: Center(
        child: Transform.translate(
          offset: const Offset(0, -40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset("assets/image.png", width: 220),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
