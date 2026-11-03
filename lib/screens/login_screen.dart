import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/supabase_service.dart';
import '../theme/theme_provider.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _nomController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _motDePasseController = TextEditingController();
  bool _chargement = false;
  bool _modeEmail = false;
  bool _masquerMotDePasse = true;

  @override
  void dispose() {
    _nomController.dispose();
    _codeController.dispose();
    _emailController.dispose();
    _motDePasseController.dispose();
    super.dispose();
  }

  Future<void> _connecterCode() async {
    final nom = _nomController.text.trim();
    final code = _codeController.text.trim();
    if (nom.isEmpty || code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Entrez votre nom et votre code.')),
      );
      return;
    }

    setState(() => _chargement = true);
    final profil = await SupabaseService().connecterAvecCode(code, nom: nom);
    if (!mounted) return;
    setState(() => _chargement = false);
    _traiterConnexion(profil);
  }

  Future<void> _connecterEmail() async {
    final email = _emailController.text.trim();
    final motDePasse = _motDePasseController.text;
    if (email.isEmpty || motDePasse.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Entrez votre email et votre mot de passe.'),
        ),
      );
      return;
    }

    setState(() => _chargement = true);
    final profil = await SupabaseService().connecterAvecEmail(
      email: email,
      motDePasse: motDePasse,
    );
    if (!mounted) return;
    setState(() => _chargement = false);
    _traiterConnexion(profil);
  }

  void _traiterConnexion(Map<String, dynamic>? profil) {
    if (profil == null) {
      final detail =
          SupabaseService().derniereErreur ?? 'Vérifiez vos informations.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connexion impossible. $detail')));
      return;
    }

    Provider.of<ThemeProvider>(
      context,
      listen: false,
    ).appliquerTheme(profil['mode_sombre'] as bool? ?? false);

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const HomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final couleur = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Connexion'), centerTitle: true),
      body: SingleChildScrollView(
        // Le clavier peut masquer le bas du formulaire : on laisse défiler
        // le contenu et on ajoute la hauteur du clavier en bas.
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text(
                _modeEmail
                    ? 'Connectez-vous avec votre email'
                    : 'Entrez votre nom et votre code',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              if (_modeEmail) ...[
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: _motDePasseController,
                  obscureText: _masquerMotDePasse,
                  onSubmitted: (_) {
                    if (!_chargement) _connecterEmail();
                  },
                  decoration: InputDecoration(
                    labelText: 'Mot de passe',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _masquerMotDePasse
                          ? 'Afficher le mot de passe'
                          : 'Masquer le mot de passe',
                      icon: Icon(
                        _masquerMotDePasse
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () => setState(
                        () => _masquerMotDePasse = !_masquerMotDePasse,
                      ),
                    ),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _nomController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nom',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Code',
                    hintText: 'XXXX-XXXX',
                  ),
                  onSubmitted: (_) {
                    if (!_chargement) _connecterCode();
                  },
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  foregroundColor: couleur.onSurface,
                ),
                onPressed: _chargement
                    ? null
                    : (_modeEmail ? _connecterEmail : _connecterCode),
                child: _chargement
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Se connecter'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _chargement
                    ? null
                    : () => setState(() => _modeEmail = !_modeEmail),
                child: Text(
                  _modeEmail
                      ? 'Utiliser mon nom et mon code'
                      : 'J’ai sauvegardé mon compte avec un email',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
