import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/download_helper.dart' show telechargerViaAncre;
import '../theme/kinflow_theme.dart';
import 'edit_profile_screen.dart';
import 'login_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacite;
  late final Animation<Offset> _decalage;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _opacite = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _decalage = Tween<Offset>(
      begin: const Offset(0, 0.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Image.asset('assets/image.png', width: 300),
              const Spacer(flex: 3),
              FadeTransition(
                opacity: _opacite,
                child: SlideTransition(
                  position: _decalage,
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: KinColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const EditProfileScreen(premiereFois: true),
                              ),
                            );
                          },
                          child: const Text(
                            "S'inscrire",
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: KinColors.primary,
                            side: const BorderSide(
                              color: KinColors.primary,
                              width: 1.5,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const LoginScreen(),
                              ),
                            );
                          },
                          child: const Text(
                            'Se connecter',
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: KinColors.accent,
                            side: BorderSide(
                              color: KinColors.accent.withValues(alpha: 0.6),
                              width: 1.5,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: _installerApk,
                          child: const Text(
                            'Installer l\'application (APK)',
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  /// Télécharge puis installe l'application Android (APK).
  ///
  /// Le fichier `app-release.apk` doit être servi à côté de l'application
  /// (par ex. dans le dossier servi par le localhost:8080). Le chemin est
  /// relatif pour fonctionner sur `localhost`, sur l'IP du PC (téléphone sur
  /// le même réseau) ou sur un futur domaine.
  ///
  /// Sur Android, l'ouverture du lien lance le téléchargement de l'APK par le
  /// navigateur : le fichier apparaît ensuite dans le gestionnaire de
  /// fichiers puis se laisse installer (autoriser « sources inconnues »).
  Future<void> _installerApk() async {
    const relatif = 'app-release.apk';
    final uri = Uri.parse(relatif);
    final url = uri.toString();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Téléchargement de l\'APK en cours…'),
        duration: Duration(seconds: 3),
      ),
    );

    // Sur le web, un simple lien d'ancrage force le téléchargement
    // (download=) ; sur mobile/natif, url_launcher ouvre l'URL.
    if (kIsWeb) {
      telechargerViaAncre(url, 'app-release.apk');
      return;
    }

    if (await _lancerUrl(url)) {
      return;
    }

    // Repli : affiche l'adresse à copier si l'ouverture échoue.
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ouvrez : $url')));
    }
  }

  Future<bool> _lancerUrl(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}
