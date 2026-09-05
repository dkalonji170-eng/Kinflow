import 'package:flutter/material.dart';
import 'home_screen.dart';

class CodeScreen extends StatelessWidget {
  final String code;
  const CodeScreen({super.key, required this.code});

  String get _codeAffiche {
    final c = code.trim();
    if (c.length == 8) return '${c.substring(0, 4)}-${c.substring(4)}';
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final couleur = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Votre code'),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.key, size: 64, color: couleur.primary),
            const SizedBox(height: 16),
            const Text(
              'Notez bien ce code',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Il vous permettra de vous connecter à votre compte '
              'sur un autre téléphone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: couleur.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: couleur.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: couleur.onSurface.withValues(alpha: 0.2),
                ),
              ),
              child: SelectableText(
                _codeAffiche,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                  color: couleur.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => const HomeScreen()),
                    (route) => false,
                  );
                },
                child: const Text('Continuer'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
