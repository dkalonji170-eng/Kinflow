import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import '../widgets/avatar_animal.dart';
import 'edit_profile_screen.dart';

/// Mon profil : l'avatar puis deux sections DÉPLIABLES, comme dans les
/// Paramètres — un appui sur la ligne fait descendre la flèche et ouvre le
/// contenu :
///
///  - « Code du compte » : le code privé qui sert à se reconnecter ;
///  - « Code ami » : le code public à partager pour qu'on t'ajoute.
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
  String avatar = "";

  /// Code AMI public (distinct du code de compte, qui est privé).
  String _codeAmi = "";
  bool _chargementCodeAmi = true;

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
    _chargerCodeAmi();
  }

  Future<void> _chargerCodeAmi() async {
    final codeAmi = await SupabaseService().monCodeAmi();
    if (!mounted) return;
    setState(() {
      _codeAmi = (codeAmi ?? '').trim();
      _chargementCodeAmi = false;
    });
  }

  Future<void> chargerProfil() async {
    final service = SupabaseService();
    // 1) Affichage instantané depuis le cache local (petit animal tapé) :
    //    pas d'écran vide le temps de la requête réseau.
    final cache = await service.chargerProfilCache();
    if (!mounted) return;
    if (cache != null) _appliquer(cache);
    // 2) Rafraîchissement depuis le serveur (données à jour).
    Journal.i('PROFIL', 'Chargement du profil depuis le serveur');
    try {
      final profile = await service.loadProfile();
      if (!mounted) return;
      if (profile != null) {
        _appliquer(profile);
      } else if (cache == null) {
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

  /// Applique un profil (cache local ou serveur) à l'affichage.
  void _appliquer(Map<String, dynamic> profile) {
    if (!mounted) return;
    setState(() {
      nom = profile['nom'] as String? ?? '';
      prenom = profile['prenom'] as String? ?? '';
      sexe = profile['sexe'] as String? ?? '';
      date = profile['date'] as String? ?? '';
      telephone = profile['telephone'] as String? ?? '';
      email = profile['email'] as String? ?? '';
      code = profile['code'] as String? ?? '';
      avatar = profile['avatar'] as String? ?? '';
    });
  }

  void _copier(String valeur, String message) {
    Clipboard.setData(ClipboardData(text: valeur));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// Ligne dépliable « façon Paramètres » : une ligne avec la flèche à droite,
  /// qui descend et laisse apparaître [contenu] quand on appuie dessus.
  Widget _section({
    required IconData icone,
    required String titre,
    required List<Widget> contenu,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Pas de trait de séparation au-dessus/dessous du contenu ouvert.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icone, color: theme.colorScheme.primary),
          title: Text(
            titre,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          // La flèche par défaut (chevron vers le bas) se retourne vers le
          // haut à l'ouverture : c'est le mouvement demandé.
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: contenu,
        ),
      ),
    );
  }

  Widget _texteSecondaire(String texte) {
    final couleur = Theme.of(context).colorScheme;
    return Text(
      texte,
      style: TextStyle(
        fontSize: 12,
        color: couleur.onSurface.withValues(alpha: 0.6),
      ),
    );
  }

  /// Code présenté en gros, sélectionnable et copiable d'un appui.
  Widget _codeAffichable({
    required String valeur,
    required String messageCopie,
    required String vide,
  }) {
    final couleur = Theme.of(context).colorScheme;
    if (valeur.isEmpty) {
      return _texteSecondaire(vide);
    }
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: couleur.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              _formaterCode(valeur),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copier',
          icon: const Icon(Icons.copy, size: 20),
          onPressed: () => _copier(valeur, messageCopie),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text("Mon profil"), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
        children: [
          Center(
            child: AvatarAnimalWidget(
              taille: 108,
              avatarId: avatar,
              // Un halo lumineux pour que l'avatar ressorte sur le fond.
              brillance: true,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              "$nom $prenom",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 20),

          // 1) Code du compte — privé.
          _section(
            icone: Icons.key,
            titre: 'Code du compte',
            contenu: [
              _codeAffichable(
                valeur: code,
                messageCopie: 'Code de compte copié',
                vide: 'Code indisponible pour le moment.',
              ),
              const SizedBox(height: 8),
              _texteSecondaire('Ne le partage pas : il sert à te reconnecter.'),
            ],
          ),

          // 2) Code ami — public.
          _section(
            icone: Icons.person_add_alt_1,
            titre: 'Code ami',
            contenu: [
              if (_chargementCodeAmi)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                _codeAffichable(
                  valeur: _codeAmi,
                  messageCopie: 'Code ami copié',
                  vide: 'Code ami indisponible pour le moment.',
                ),
              const SizedBox(height: 8),
              _texteSecondaire(
                'Partage-le pour qu\'on t\'ajoute dans les amis(es).',
              ),
            ],
          ),

          // 3) Sexe et coordonnées.
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.badge_outlined, color: colorScheme.primary),
              title: Text("Sexe : $sexe"),
              subtitle: Text(
                "Date de naissance : $date\n"
                "Téléphone : $telephone\n"
                "Email : $email",
              ),
            ),
          ),
          const SizedBox(height: 20),
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
                _chargerCodeAmi();
              });
            },
            icon: const Icon(Icons.edit),
            label: const Text("Modifier mon profil"),
          ),
        ],
      ),
    );
  }
}
