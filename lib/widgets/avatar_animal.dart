import 'package:flutter/material.dart';

import '../services/rang_service.dart';
import 'grade_rang.dart';

/// Un avatar « animal rond » façon Xender : un emoji d'animal posé sur un
/// fond coloré. Chaque animal a un identifiant stable, stocké dans
/// `profiles.avatar` (rien n'est téléchargé : tout est dessiné par Flutter).
class AvatarAnimal {
  const AvatarAnimal({
    required this.id,
    required this.emoji,
    required this.nom,
    required this.couleur,
  });

  final String id;
  final String emoji;
  final String nom;
  final Color couleur;
}

/// Les 10 avatars proposés à l'inscription (identifiants stables : on peut
/// les stocker en base sans casser l'affichage si l'app évolue).
const List<AvatarAnimal> avatarsAnimaux = [
  AvatarAnimal(
    id: 'lion',
    emoji: '🦁',
    nom: 'Lion',
    couleur: Color(0xFFE8590C),
  ),
  AvatarAnimal(
    id: 'tigre',
    emoji: '🐯',
    nom: 'Tigre',
    couleur: Color(0xFFF59F00),
  ),
  AvatarAnimal(
    id: 'panda',
    emoji: '🐼',
    nom: 'Panda',
    couleur: Color(0xFF2F9E44),
  ),
  AvatarAnimal(
    id: 'renard',
    emoji: '🦊',
    nom: 'Renard',
    couleur: Color(0xFFF76707),
  ),
  AvatarAnimal(
    id: 'koala',
    emoji: '🐨',
    nom: 'Koala',
    couleur: Color(0xFF3B5BDB),
  ),
  AvatarAnimal(
    id: 'grenouille',
    emoji: '🐸',
    nom: 'Grenouille',
    couleur: Color(0xFF0CA678),
  ),
  AvatarAnimal(
    id: 'lapin',
    emoji: '🐰',
    nom: 'Lapin',
    couleur: Color(0xFFE64980),
  ),
  AvatarAnimal(
    id: 'chien',
    emoji: '🐶',
    nom: 'Chien',
    couleur: Color(0xFF1565C0),
  ),
  AvatarAnimal(
    id: 'loup',
    emoji: '🐺',
    nom: 'Loup',
    couleur: Color(0xFF7048E8),
  ),
  AvatarAnimal(
    id: 'hibou',
    emoji: '🦉',
    nom: 'Hibou',
    couleur: Color(0xFF5F3DC4),
  ),
];

/// Retrouve un avatar par son identifiant stocké, ou null si inconnu/vide
/// (l'utilisateur n'a pas encore choisi d'avatar).
AvatarAnimal? avatarParId(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final avatar in avatarsAnimaux) {
    if (avatar.id == id) return avatar;
  }
  return null;
}

/// Dessine l'avatar : l'animal en cercle sur son fond coloré, ou l'icône
/// « personne » tant qu'aucun avatar n'est choisi.
///
/// Le grade (étoiles, médailles ou faucon) est affiché **dans** le rond, sous
/// l'animal. Il peut être fourni directement ([niveau] ou [grade]) ou chargé
/// à la volée pour un utilisateur ([userId]) : le cache de [RangService] évite
/// une requête par reconstruction.
class AvatarAnimalWidget extends StatefulWidget {
  const AvatarAnimalWidget({
    super.key,
    this.taille = 90,
    this.avatarId,
    this.grade,
    this.niveau,
    this.userId,
  });

  final double taille;
  final String? avatarId;

  /// Optionnel : petit widget dessiné **à l'intérieur** du rond, sous l'animal
  /// (par exemple le signe du grade : étoiles, médailles ou faucon).
  final Widget? grade;

  /// Niveau de grade déjà connu (1 = Débutant … 8 = Légende). Prioritaire sur
  /// [userId] et inutile si [grade] est fourni.
  final int? niveau;

  /// Identifiant de l'utilisateur dont le grade doit être affiché. Le niveau
  /// est chargé une seule fois puis gardé en cache.
  final String? userId;

  @override
  State<AvatarAnimalWidget> createState() => _AvatarAnimalWidgetState();
}

class _AvatarAnimalWidgetState extends State<AvatarAnimalWidget> {
  int? _niveauCharge;

  @override
  void initState() {
    super.initState();
    _resoudreGrade();
  }

  @override
  void didUpdateWidget(AvatarAnimalWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.niveau != widget.niveau) {
      _resoudreGrade();
    }
  }

  /// Détermine le niveau à afficher : [AvatarAnimalWidget.niveau] d'abord,
  /// puis le cache, puis un chargement réseau silencieux.
  void _resoudreGrade() {
    if (widget.grade != null) {
      _niveauCharge = null;
      return;
    }
    final impose = widget.niveau;
    if (impose != null) {
      _niveauCharge = impose.clamp(1, 8);
      return;
    }
    final id = widget.userId;
    if (id == null || id.isEmpty) {
      _niveauCharge = null;
      return;
    }
    final connu = RangService.instance.niveau(id);
    _niveauCharge = connu;
    if (connu != null) return;
    RangService.instance.charger(id).then((niveau) {
      if (!mounted || widget.userId != id || widget.niveau != null) return;
      if (niveau != null && niveau != _niveauCharge) {
        setState(() => _niveauCharge = niveau);
      }
    });
  }

  /// Taille d'un symbole de grade, calculée pour que la rangée reste dans le
  /// cercle même sur les petits avatars (carte, audio, liste d'amis).
  double _tailleGrade(int niveau) {
    // Largeur relative de la rangée : étoiles/médailles, ou flammes + faucon.
    final poids = switch (niveau) {
      <= 3 => niveau.toDouble(),
      <= 5 => (niveau - 3).toDouble(),
      6 => 2.0,
      7 => 3.7,
      _ => 1.15,
    };
    final dispo = widget.taille - 4;
    final max = (widget.taille * 0.28).clamp(5.0, 18.0);
    if (poids * max + 4 <= dispo) return max;
    return ((dispo - 4) / poids).clamp(3.5, max);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = avatarParId(widget.avatarId);
    final niveau = widget.niveau?.clamp(1, 8) ?? _niveauCharge;
    final grade =
        widget.grade ??
        (niveau == null
            ? null
            : GradeRang(niveau: niveau, taille: _tailleGrade(niveau)));
    // Avec un grade sous l'animal, on réduit un peu l'emoji pour que les deux
    // tiennent dans le cercle sans le déborder.
    final double echelleAnimal = grade == null ? 0.55 : 0.46;
    final Widget animal = avatar == null
        ? Icon(
            Icons.person,
            size: widget.taille * echelleAnimal,
            color: theme.colorScheme.onSurfaceVariant,
          )
        : Text(
            avatar.emoji,
            style: TextStyle(
              fontSize: widget.taille * echelleAnimal,
              height: 1,
            ),
          );

    return Container(
      width: widget.taille,
      height: widget.taille,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: avatar?.couleur ?? theme.colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Center(
        child: grade == null
            ? animal
            : Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [animal, const SizedBox(height: 1), grade],
              ),
      ),
    );
  }
}
