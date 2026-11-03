import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import '../widgets/avatar_animal.dart';

/// Liste des comptes que j'ai bloqués, avec possibilité de débloquer.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  bool _chargement = true;
  List<Map<String, dynamic>> _blocages = const [];

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final liste = await SupabaseService().mesBlocages();
    if (!mounted) return;
    setState(() {
      _blocages = liste;
      _chargement = false;
    });
  }

  Future<void> _debloquer(Map<String, dynamic> b) async {
    final id = b['user_id']?.toString() ?? '';
    if (id.isEmpty) return;
    final ok = await SupabaseService().debloquerUtilisateur(id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Déblocage impossible. Réessayez.')),
      );
      return;
    }
    setState(() {
      _blocages = [
        for (final e in _blocages)
          if (e['user_id']?.toString() != id) e,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Utilisateurs bloqués'),
        centerTitle: true,
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : _blocages.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Aucun utilisateur bloqué.\n\n'
                  'Vous pouvez bloquer quelqu’un depuis sa fiche profil.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: _blocages.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final b = _blocages[index];
                final prenom = '${b['prenom'] ?? ''}'.trim();
                final nom = '${b['nom'] ?? ''}'.trim();
                return ListTile(
                  leading: AvatarAnimalWidget(
                    taille: 44,
                    avatarId: b['avatar'] as String?,
                  ),
                  title: Text(
                    [prenom, nom].where((e) => e.isNotEmpty).join(' '),
                  ),
                  trailing: TextButton(
                    onPressed: () => _debloquer(b),
                    child: const Text('Débloquer'),
                  ),
                );
              },
            ),
    );
  }
}
