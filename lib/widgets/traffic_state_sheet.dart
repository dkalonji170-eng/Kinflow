import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/kinflow_theme.dart';

/// Feuille d'état de route : demandée à l'ouverture de la carte, ou quand le
/// conducteur veut modifier son signalement.
///
/// Le panneau est **obligatoire** : on ne peut pas le fermer sans choisir un
/// état (ni par le fond, ni par le geste, ni par le bouton retour). C'est le
/// seul moment où l'app demande quelque chose, et c'est ce qui alimente la
/// carte des autres conducteurs — donc un choix, pas une formalité qu'on
/// balaie.
class TrafficStateSheet extends StatelessWidget {
  const TrafficStateSheet({
    super.key,
    required this.onChoix,
    this.dernierEtat,
    this.carteGrade,
    this.rappelCompte,
  });

  /// Renvoyé avec le libellé exact de l'état choisi (« Fluide », « Route
  /// bloquée »…) qui est stocké tel quel, identique à l'application actuelle.
  final ValueChanged<String> onChoix;

  /// État actuellement signalé, affiché en sous-titre si présent.
  final String? dernierEtat;

  /// Carte de grade du compte, affichée au-dessus des choix : le signalement
  /// est un geste personnel, la progression doit se voir à cet endroit précis.
  final Widget? carteGrade;

  /// Phrase de rattachement au compte (« Signaler avec ton compte… »).
  final String? rappelCompte;

  @override
  Widget build(BuildContext context) {
    final sombre = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      // Aucune sortie sans choix : le bouton retour ne ferme pas le panneau.
      canPop: false,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.traffic, color: KinColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'État des routes autour de vous',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: sombre
                              ? KinColors.texteSombre
                              : KinColors.texteClair,
                        ),
                      ),
                    ),
                    _puceObligatoire(sombre),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  dernierEtat != null && dernierEtat!.isNotEmpty
                      ? 'Signalement actuel : $dernierEtat'
                      : "Comment circulez-vous actuellement ? Vos choix aident "
                            "les autres conducteurs en temps réel.",
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.4,
                    color: sombre
                        ? KinColors.texteSecondaireSombre
                        : KinColors.texteSecondaireClair,
                  ),
                ),
                if (carteGrade != null) ...[
                  const SizedBox(height: 14),
                  carteGrade!,
                ],
                const SizedBox(height: 16),
                _choixEtat(
                  context,
                  couleur: KinColors.fluide,
                  libelle: 'Fluide',
                  detail: 'Congestion légère uniquement',
                ),
                _choixEtat(
                  context,
                  couleur: KinColors.embouteillageLeger,
                  libelle: 'Embouteillages léger',
                  detail: 'Ralentissements ponctuels',
                ),
                _choixEtat(
                  context,
                  couleur: KinColors.grosEmbouteillages,
                  libelle: 'Gros embouteillages',
                  detail: 'Circulation très difficile',
                ),
                _choixEtat(
                  context,
                  couleur: KinColors.routeBloquee,
                  libelle: 'Route bloquée',
                  detail: 'Impossible de passer',
                ),
                const SizedBox(height: 4),
                Text(
                  rappelCompte ??
                      'Ton choix est envoyé depuis ton compte : il fait '
                          'progresser ton grade et met la carte à jour pour '
                          'les autres conducteurs.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: sombre
                        ? KinColors.texteSecondaireSombre
                        : KinColors.texteSecondaireClair,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _puceObligatoire(bool sombre) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: KinColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'OBLIGATOIRE',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
          color: KinColors.primary,
        ),
      ),
    );
  }

  Widget _choixEtat(
    BuildContext context, {
    required Color couleur,
    required String libelle,
    required String detail,
  }) {
    final sombre = Theme.of(context).brightness == Brightness.dark;
    final fond = sombre ? const Color(0xFF1E2622) : const Color(0xFFF1F5F2);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: fond,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            // Retour haptique : le choix doit se sentir, pas seulement se voir.
            HapticFeedback.mediumImpact();
            onChoix(libelle);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        libelle,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: sombre
                              ? KinColors.texteSombre
                              : KinColors.texteClair,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: sombre
                              ? KinColors.texteSecondaireSombre
                              : KinColors.texteSecondaireClair,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: couleur),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
