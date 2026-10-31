import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostics_service.dart';
import '../services/serie_activite_service.dart';
import '../services/supabase_service.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/carte_grade.dart';
import '../widgets/grade_rang.dart';
import 'edit_profile_screen.dart';

/// Mon profil : l'avatar (avec le grade dessiné dans le rond) puis trois
/// sections DÉPLIABLES, comme dans les Paramètres — un appui sur la ligne fait
/// descendre la flèche et ouvre le contenu :
///
///  - « Code du compte » : le code privé qui sert à se reconnecter ;
///  - « Code ami » : le code public à partager pour qu'on t'ajoute ;
///  - « Grade » : ton grade actuel et les symboles de tous les grades.
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

  Map<String, dynamic>? _rangSignalements;
  bool _chargementRang = true;
  int _serie = 0;
  int _meilleureSerie = 0;

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
    _chargerRang();
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

  Future<void> _chargerRang() async {
    if (!mounted) return;
    setState(() => _chargementRang = true);
    Map<String, dynamic>? rang;
    try {
      rang = await SupabaseService().monRangSignalements();
    } catch (_) {}
    await SerieActivite.instance.charger();
    if (!mounted) return;
    setState(() {
      _rangSignalements = rang;
      _serie = SerieActivite.instance.serie;
      _meilleureSerie = SerieActivite.instance.meilleure;
      _chargementRang = false;
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
    required String resume,
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
          subtitle: Text(resume),
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

  /// Une ligne de la liste des grades : symbole, nom, et mention du grade
  /// actuel. Aucun palier chiffré, aucune référence aux signalements.
  Widget _ligneGrade(int niveau, int niveauActuel) {
    final couleur = Theme.of(context).colorScheme;
    final actuel = niveau == niveauActuel;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: actuel
            ? couleur.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: actuel
            ? Border.all(color: couleur.primary.withValues(alpha: 0.35))
            : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Center(child: GradeRang(niveau: niveau, taille: 14)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              GradeRang.noms[niveau - 1],
              style: TextStyle(
                fontSize: 13,
                fontWeight: actuel ? FontWeight.w700 : FontWeight.w500,
                color: actuel ? couleur.primary : null,
              ),
            ),
          ),
          Text(
            actuel ? 'Ton grade' : '',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: couleur.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final niveauActuel = (_rangSignalements?['niveau'] as num?)?.toInt() ?? 1;

    return Scaffold(
      appBar: AppBar(title: const Text("Mon profil"), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
        children: [
          Center(
            child: AvatarAnimalWidget(
              taille: 108,
              avatarId: avatar,
              // Grade du compte, dessiné à l'intérieur du rond, sous l'animal.
              grade: _rangSignalements == null
                  ? null
                  : GradeRang(niveau: niveauActuel, taille: 20),
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
            resume: 'Privé — pour te reconnecter',
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
            resume: 'Public — à partager pour qu\'on t\'ajoute',
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

          // 3) Grade — rang actuel + symboles de tous les grades.
          _section(
            icone: Icons.military_tech,
            titre: 'Grade',
            resume: _chargementRang
                ? 'Chargement…'
                : '${GradeRang.noms[niveauActuel.clamp(1, 8) - 1]}'
                      ' · Grade $niveauActuel sur ${GradeRang.noms.length}',
            contenu: [
              if (_chargementRang)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_rangSignalements == null)
                _texteSecondaire('Grade indisponible pour le moment.')
              else ...[
                CarteGrade(
                  niveau: niveauActuel,
                  nbSignalements:
                      (_rangSignalements!['nb_signalements'] as num?)?.toInt() ??
                      0,
                  estMax: _rangSignalements!['est_max'] == true,
                  serie: _serie,
                  piedDePage: _meilleureSerie > _serie
                      ? 'Meilleure série : $_meilleureSerie jours. '
                            'Ton grade et ta série sont attachés à ce compte.'
                      : 'Ton grade et ta série sont attachés à ce compte : '
                            'ils te suivent partout dans KinFlow.',
                ),
                const SizedBox(height: 14),
                const Text(
                  'Les grades KinFlow',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                _texteSecondaire(
                  'Ta progression monte en utilisant KinFlow : plus tu '
                  'utilises ton compte, plus ton grade avance.',
                ),
                const SizedBox(height: 8),
                for (var n = 1; n <= GradeRang.noms.length; n++)
                  _ligneGrade(n, niveauActuel),
              ],
            ],
          ),

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
