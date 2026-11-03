import 'package:flutter/material.dart';

import '../models/publication.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';
import 'avatar_anonyme.dart';
import 'avatar_animal.dart';

/// Carte d'un reportage : auteur, titre, texte, photos et actions.
///
/// Utilisée dans « Ma page », dans l'espace d'un informateur et dans l'écran
/// de détail. Les photos sont privées : chaque vignette demande une URL
/// signée (mise en cache par [SupabaseService]).
class CartePublication extends StatelessWidget {
  const CartePublication({
    super.key,
    required this.publication,
    this.onSupprimer,
    this.onAppui,
    this.onLike,
    this.onCommentaires,
  });

  final Publication publication;
  final VoidCallback? onSupprimer;
  final VoidCallback? onAppui;
  final VoidCallback? onLike;
  final VoidCallback? onCommentaires;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (libelle, icone, couleur) = typeInfos(publication.typeInfo);

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: InkWell(
        onTap: onAppui,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _enteteAuteur(theme, couleur, icone, libelle),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  publication.titre,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
              if (publication.contenu.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    publication.contenu,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                ),
              ],
              if (publication.aDesPhotos) ...[
                const SizedBox(height: 12),
                _PhotosPublication(chemins: publication.photos),
              ],
              const SizedBox(height: 6),
              _actions(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _enteteAuteur(
    ThemeData theme,
    Color couleur,
    IconData icone,
    String libelle,
  ) {
    return Row(
      children: [
        if (publication.anonyme)
          const AvatarAnonyme(taille: 30)
        else
          AvatarAnimalWidget(taille: 30, avatarId: publication.auteurAvatar),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                publication.nomAffiche,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Row(
                children: [
                  Icon(icone, size: 12, color: couleur),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      publication.lieu == null
                          ? libelle
                          : '$libelle · ${publication.lieu}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Text(
          dateCourte(publication.creeA),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (onSupprimer != null)
          IconButton(
            onPressed: onSupprimer,
            tooltip: 'Supprimer',
            iconSize: 20,
            icon: const Icon(Icons.delete_outline),
          )
        else
          const SizedBox(width: 8),
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    final aime = publication.jaiLike;
    return Row(
      children: [
        _boutonAction(
          theme,
          icone: aime ? Icons.favorite : Icons.favorite_border,
          libelle: '${publication.nbLikes}',
          couleur: aime ? const Color(0xFFE53935) : null,
          onTap: onLike,
        ),
        const SizedBox(width: 6),
        _boutonAction(
          theme,
          icone: Icons.mode_comment_outlined,
          libelle: '${publication.nbCommentaires}',
          onTap: onCommentaires,
        ),
      ],
    );
  }

  Widget _boutonAction(
    ThemeData theme, {
    required IconData icone,
    required String libelle,
    required VoidCallback? onTap,
    Color? couleur,
  }) {
    final teinte = couleur ?? theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icone, size: 18, color: teinte),
            const SizedBox(width: 5),
            Text(
              libelle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: teinte,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Libellé, icône et couleur d'un type de reportage.
  static (String, IconData, Color) typeInfos(String type) {
    return switch (type) {
      'trafic' => ('Trafic', Icons.traffic, KinColors.accentTranche),
      'eau' => ('Eau', Icons.water_drop, const Color(0xFF1E88E5)),
      'courant' => ('Courant', Icons.bolt, const Color(0xFFF9A825)),
      'internet' => ('Internet', Icons.wifi, const Color(0xFF7C4DFF)),
      'securite' => (
        'Sécurité',
        Icons.shield_outlined,
        KinColors.grosEmbouteillages,
      ),
      _ => ('Info', Icons.info_outline, KinColors.primary),
    };
  }
}

/// Date courte et lisible, partagée par les cartes et les commentaires.
String dateCourte(DateTime d) {
  final difference = DateTime.now().difference(d);
  if (difference.inMinutes < 1) return 'à l\'instant';
  if (difference.inMinutes < 60) return 'il y a ${difference.inMinutes} min';
  if (difference.inHours < 24) return 'il y a ${difference.inHours} h';
  if (difference.inDays < 7) return 'il y a ${difference.inDays} j';
  final jour = d.day.toString().padLeft(2, '0');
  final mois = d.month.toString().padLeft(2, '0');
  return '$jour/$mois/${d.year}';
}

class _PhotosPublication extends StatelessWidget {
  const _PhotosPublication({required this.chemins});

  final List<String> chemins;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chemins.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 118,
              height: 118,
              child: FutureBuilder<String?>(
                future: SupabaseService().urlPhotoPublication(chemins[index]),
                builder: (context, snapshot) {
                  final url = snapshot.data;
                  if (url == null || url.isEmpty) {
                    return ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: snapshot.connectionState == ConnectionState.waiting
                          ? const Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Icon(
                              Icons.broken_image_outlined,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    );
                  }
                  return Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
