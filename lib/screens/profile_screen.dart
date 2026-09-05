import 'package:flutter/material.dart';
import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String nom = "";
  String prenom = "";
  String sexe = "";
  String date = "";
  String telephone = "";
  String email = "";
  String code = "";

  String _formaterCode(String c) {
    final propre = c.trim();
    if (propre.length == 8) {
      return '${propre.substring(0, 4)}-${propre.substring(4)}';
    }
    return propre;
  }

  @override
  void initState() {
    super.initState();
    chargerProfil();
  }

  Future<void> chargerProfil() async {
    Journal.i('PROFIL', 'Chargement du profil depuis le serveur');
    try {
      final profile = await SupabaseService().loadProfile();
      if (!mounted) return;
      if (profile != null) {
        setState(() {
          nom = profile['nom'] as String? ?? '';
          prenom = profile['prenom'] as String? ?? '';
          sexe = profile['sexe'] as String? ?? '';
          date = profile['date'] as String? ?? '';
          telephone = profile['telephone'] as String? ?? '';
          email = profile['email'] as String? ?? '';
          code = profile['code'] as String? ?? '';
        });
      } else {
        Journal.a(
          'PROFIL',
          'Aucun profil renvoyé par le serveur (non connecté ?)',
        );
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargement profil: $e');
      Journal.e('PROFIL', 'Chargement du profil planté', {'erreur': '$e'});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text("Mon profil"), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            CircleAvatar(
              radius: 45,
              backgroundColor: colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.person,
                size: 50,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 15),
            Text(
              "$nom $prenom",
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            if (code.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.onSurface.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      "Code",
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      _formaterCode(code),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 30),
            Card(
              child: ListTile(
                title: Text("Sexe : $sexe"),
                subtitle: Text(
                  "Date de naissance : $date\n"
                  "Téléphone : $telephone\n"
                  "Email : $email",
                ),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                foregroundColor: colorScheme.onSurface,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const EditProfileScreen(),
                  ),
                ).then((value) {
                  chargerProfil();
                });
              },
              icon: const Icon(Icons.edit),
              label: const Text("Modifier mon profil"),
            ),
          ],
        ),
      ),
    );
  }
}
