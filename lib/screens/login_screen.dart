import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/supabase_service.dart';
import '../theme_provider.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _nomController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  bool _chargement = false;

  @override
  void dispose() {
    _nomController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _connecter() async {
    final nom = _nomController.text.trim();
    final code = _codeController.text.trim();
    if (nom.isEmpty || code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Entrez votre nom et votre code.')),
      );
      return;
    }

    setState(() => _chargement = true);
    final profil =
        await SupabaseService().connecterAvecCode(code, nom: nom);
    if (!mounted) return;
    setState(() => _chargement = false);

    if (profil == null) {
      final detail =
          SupabaseService().derniereErreur ?? 'Vérifiez vos informations.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connexion impossible. $detail')),
      );
      return;
    }

    Provider.of<ThemeProvider>(context, listen: false)
        .appliquerTheme(profil['mode_sombre'] as bool? ?? false);

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
      appBar: AppBar(
        title: const Text('Connexion'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            const Text(
              'Entrez votre nom et votre code',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
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
              onSubmitted: (_) => _connecter(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                foregroundColor: couleur.onSurface,
              ),
              onPressed: _chargement ? null : _connecter,
              child: _chargement
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Se connecter'),
            ),
          ],
        ),
      ),
    );
  }
}
