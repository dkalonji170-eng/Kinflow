import 'package:flutter/material.dart';

/// Aperçu du message cité, affiché DANS la bulle d'une réponse (façon
/// WhatsApp) : une barre verticale, le nom de l'expéditeur du message d'origine
/// et son résumé sur deux lignes maximum.
///
/// Un appui sur l'aperçu appelle [onTap] : la discussion remonte alors jusqu'au
/// message d'origine. Le widget ne connaît ni le serveur ni la conversation, ce
/// qui le rend utilisable partout (texte, vocal, photo) et facile à tester.
class CitationMessage extends StatelessWidget {
  const CitationMessage({
    super.key,
    required this.nom,
    required this.resume,
    this.onTap,
    this.fond,
    this.couleurBarre,
  });

  /// Nom de la personne qui a écrit le message cité (« Vous » ou l'ami(e)).
  final String nom;

  /// Résumé du message cité : son texte, ou une étiquette pour un média.
  final String resume;

  /// Appui sur l'aperçu : revenir au message d'origine. Null = non cliquable.
  final VoidCallback? onTap;

  /// Fond de l'aperçu. Par défaut un blanc translucide, lisible sur les bulles
  /// colorées (vert/bleu) comme sur une photo assombrie.
  final Color? fond;

  /// Couleur de la barre verticale et du nom.
  final Color? couleurBarre;

  @override
  Widget build(BuildContext context) {
    final barre = couleurBarre ?? Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: fond ?? Colors.white.withValues(alpha: 0.16),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 5, 8, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      nom,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: barre,
                      ),
                    ),
                    Text(
                      resume,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: barre),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
