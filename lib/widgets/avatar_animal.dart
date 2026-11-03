import 'package:flutter/material.dart';

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
class AvatarAnimalWidget extends StatelessWidget {
  const AvatarAnimalWidget({
    super.key,
    this.taille = 90,
    this.avatarId,
    this.brillance = false,
  });

  final double taille;
  final String? avatarId;

  /// Ajoute un halo et un reflet à l'avatar pour qu'il ressorte davantage
  /// (utilisé sur l'écran de profil).
  final bool brillance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = avatarParId(avatarId);
    final Widget animal = avatar == null
        ? Icon(
            Icons.person,
            size: taille * 0.55,
            color: theme.colorScheme.onSurfaceVariant,
          )
        : Text(
            avatar.emoji,
            style: TextStyle(fontSize: taille * 0.55, height: 1),
          );

    final couleurFond =
        avatar?.couleur ?? theme.colorScheme.surfaceContainerHighest;
    final Widget contenu = Center(child: animal);

    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: brillance ? null : couleurFond,
        gradient: brillance
            ? RadialGradient(
                center: const Alignment(-0.35, -0.45),
                radius: 1.05,
                colors: [
                  Color.lerp(couleurFond, Colors.white, 0.45)!,
                  couleurFond,
                ],
              )
            : null,
        border: Border.all(
          color: brillance
              ? Colors.white.withValues(alpha: 0.6)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          width: brillance ? 1.5 : 1,
        ),
        boxShadow: brillance
            ? [
                BoxShadow(
                  color: couleurFond.withValues(alpha: 0.55),
                  blurRadius: taille * 0.18,
                  spreadRadius: taille * 0.02,
                ),
              ]
            : null,
      ),
      child: brillance
          ? Stack(
              fit: StackFit.expand,
              children: [
                // Reflet lumineux en haut à gauche, comme une surface polie.
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.32),
                        Colors.white.withValues(alpha: 0.0),
                        Colors.black.withValues(alpha: 0.10),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
                contenu,
              ],
            )
          : contenu,
    );
  }
}
