import 'package:flutter/material.dart';

import '../theme/kinflow_theme.dart';

/// Logo « KinFlow » dessiné en code (pas d'image) pour l'AppBar et autres
/// petits affichages.
///
/// Tout est modifiable ici, sans refaire d'image :
///  - « Kin » est en bleu et « Flow » en vert — les deux couleurs de la
///    marque ;
///  - en mode sombre, les couleurs sont automatiquement éclaircies (bleu et
///    vert plus vifs) pour rester aussi brillantes que sur fond clair ;
///  - le reste du rendu (taille, graisse, espacement) est identique dans les
///    deux modes.
///
/// Le logo est affiché à la hauteur demandée, sans largeur forcée : il
/// prend sa largeur naturelle (encadré et réduit via scaleDown seulement si
/// l'espace manque), pour bien occuper l'AppBar sans laisser de vide.
class LogoKinflow extends StatelessWidget {
  const LogoKinflow({super.key, this.hauteur = 40, this.largeur});

  /// Hauteur d'affichage du logo (le mot « KinFlow » est haut de [hauteur]).
  final double hauteur;

  /// Largeur facultative du cadre. Non définie → le logo prend sa largeur
  /// naturelle (recommandé pour éviter le vide autour du mot).
  final double? largeur;

  @override
  Widget build(BuildContext context) {
    final sombre = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: largeur,
      height: hauteur,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text.rich(
          TextSpan(
            style: TextStyle(
              fontSize: hauteur * 0.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
              height: 1,
            ),
            children: [
              TextSpan(
                text: 'Kin',
                style: TextStyle(
                  color: sombre
                      ? const Color(0xFF64B5F6) // bleu clair, lisible sur fond sombre
                      : KinColors.bleu,
                ),
              ),
              TextSpan(
                text: 'Flow',
                style: TextStyle(
                  color: sombre
                      ? const Color(0xFF4CD98E) // vert clair de la marque (thème sombre)
                      : KinColors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Carte d'accueil du logo principal (`assets/image.png`) : bloc blanc
/// arrondi, fine bordure et ombre verte très douce, pour un rendu net sur
/// les écrans d'ouverture (splash et inscription).
class CarteLogoPrincipal extends StatelessWidget {
  const CarteLogoPrincipal({super.key, this.largeurImage = 240});

  /// Largeur de l'image affichée à l'intérieur de la carte.
  final double largeurImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: KinColors.primary.withValues(alpha: 0.08),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: KinColors.primary.withValues(alpha: 0.12),
            blurRadius: 30,
            spreadRadius: -6,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Image.asset(
        'assets/image.png',
        width: largeurImage,
        errorBuilder: (_, _, _) => Icon(
          Icons.navigation,
          size: largeurImage * 0.35,
          color: KinColors.primary,
        ),
      ),
    );
  }
}
