// Contrôles UI flottants de la carte : boutons d'action, mode carte,
// pose d'épingle et marqueur de POI. Extraits de `traffic_map.dart`.
import 'dart:math' show max;

import 'package:flutter/material.dart';

import '../theme/kinflow_theme.dart';
import 'map_painters.dart' show PeintreEpingle;

/// Boutons d'actions contextuels affichés au-dessus du point bleu de
/// position : « Définir itinéraire », « Détails » et « Supprimer ».
class BoutonsActions extends StatelessWidget {
  final VoidCallback? onDefinirItineraire;

  /// Libellé du bouton principal (« Définir itinéraire » ou « Ajouter à
  /// l'itinéraire » selon le contexte).
  final String libelleDefinirItineraire;

  final VoidCallback? onSupprimer;

  /// Affiche les coordonnées géographiques du point bleu de position.
  final VoidCallback? onVoirDetails;

  final bool afficherDefinirItineraire;

  final VoidCallback onInteractionStart;

  final VoidCallback onInteractionEnd;

  const BoutonsActions({
    super.key,
    this.onDefinirItineraire,
    this.libelleDefinirItineraire = 'Définir itinéraire',
    this.onSupprimer,
    this.onVoirDetails,
    this.afficherDefinirItineraire = true,
    required this.onInteractionStart,
    required this.onInteractionEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => onInteractionStart(),
      onPointerUp: (_) => onInteractionEnd(),
      onPointerCancel: (_) => onInteractionEnd(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (afficherDefinirItineraire)
            BoutonAction(
              onPressed: onDefinirItineraire,
              icone: Icons.route,
              libelle: libelleDefinirItineraire,
              couleur: Colors.black,
            ),
          if (afficherDefinirItineraire) const SizedBox(width: 8),
          // Le point bleu de position affiche « Détails » + « Supprimer ».
          if (onVoirDetails != null) ...[
            BoutonAction(
              onPressed: onVoirDetails,
              icone: Icons.info_outline,
              libelle: 'Détails',
              couleur: Colors.black,
            ),
            const SizedBox(width: 8),
          ],
          BoutonAction(
            onPressed: onSupprimer,
            icone: Icons.delete,
            libelle: 'Supprimer',
            couleur: Colors.black,
          ),
        ],
      ),
    );
  }
}

class BoutonAction extends StatelessWidget {
  static const double paddingHorizontal = 12;

  static const double paddingVertical = 8;

  static const double iconeTaille = 18;

  static const double ecartIcone = 6;

  static const double tailleTexte = 12;

  static double largeurPour(
    String texte,
    TextStyle styleBase,
    TextScaler textScaler,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: texte, style: styleBase),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    return tp.width + (2 * paddingHorizontal) + iconeTaille + ecartIcone + 4;
  }

  static double hauteurPour(
    TextStyle styleBase,
    TextScaler textScaler,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: 'Ag', style: styleBase),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    return max(iconeTaille, tp.height) + (2 * paddingVertical);
  }

  final VoidCallback? onPressed;

  final IconData icone;

  final String libelle;

  final Color couleur;

  const BoutonAction({
    super.key,
    this.onPressed,
    required this.icone,
    required this.libelle,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    final actif = onPressed != null;
    final couleurBtn = actif ? couleur : Colors.grey;
    return Material(
      color: actif ? Colors.white : Colors.grey.shade200,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
          color: actif ? Colors.black : Colors.grey,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: paddingHorizontal,
            vertical: paddingVertical,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icone, size: iconeTaille, color: couleurBtn),
              const SizedBox(width: ecartIcone),
              Flexible(
                child: Text(
                  libelle,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: tailleTexte,
                    fontWeight: FontWeight.w600,
                    color: couleurBtn,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MarqueurPoi extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String nom;
  const MarqueurPoi({
    super.key,
    required this.icone,
    required this.couleur,
    required this.nom,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: couleur, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Icon(icone, size: 15, color: couleur),
        ),
        if (nom.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(maxWidth: 104),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              nom,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
      ],
    );
  }
}

class BoutonPoserEpingle extends StatelessWidget {
  /// Vrai quand le mode pose d'épingle est actif : le bouton est mis en
  /// évidence pour indiquer qu'un deuxième appui annule la pose.
  final bool actif;

  final VoidCallback onPressed;

  const BoutonPoserEpingle({
    super.key,
    required this.actif,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: actif ? KinColors.primary.withValues(alpha: 0.12) : Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: actif
            ? const BorderSide(color: KinColors.primary, width: 2)
            : const BorderSide(color: Colors.black26),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: CustomPaint(
              size: const Size(26, 26),
              painter: PeintreEpingle(Colors.red),
            ),
          ),
        ),
      ),
    );
  }
}

class BoutonPoser extends StatelessWidget {
  final VoidCallback onPressed;

  /// Vrai pour la pose d'un lieu personnel (maison/travail) : gabarit réduit
  /// (icône et texte plus petits) pour ne pas dominer la carte qu'on déplace
  /// sous la prévisualisation. La pose d'épingle garde le gabarit d'origine.
  final bool compact;

  const BoutonPoser({
    super.key,
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onPressed,
        child: Padding(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 14, vertical: 6)
              : const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check,
                size: compact ? 14 : 16,
                color: KinColors.primary,
              ),
              SizedBox(width: compact ? 5 : 6),
              Text(
                "Poser",
                style: TextStyle(
                  fontSize: compact ? 12 : 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BoutonModeCarte extends StatelessWidget {
  final VoidCallback onPressed;
  const BoutonModeCarte({
    super.key,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Colors.black26),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onPressed,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.layers,
                size: 18,
                color: Colors.black87,
              ),
              SizedBox(width: 6),
              Text(
                "Cartes",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OptionModeCarte extends StatelessWidget {
  final IconData icone;
  final String libelle;
  final bool selectionne;
  final bool sombre;
  final VoidCallback onTap;
  const OptionModeCarte({
    super.key,
    required this.icone,
    required this.libelle,
    required this.selectionne,
    this.sombre = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final couleurTexte = sombre ? KinColors.texteSombre : Colors.black87;
    return ListTile(
      leading: Icon(icone, color: couleurTexte),
      title: Text(
        libelle,
        style: TextStyle(fontSize: 15, color: couleurTexte),
      ),
      trailing: selectionne
          ? const Icon(Icons.check_circle, color: KinColors.primary)
          : null,
      onTap: onTap,
    );
  }
}