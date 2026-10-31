import 'package:flutter/material.dart';

import '../theme/kinflow_theme.dart';
import 'grade_rang.dart';

/// Carte de grade : l'insigne, le nom du rang, la progression et la série de
/// jours d'activité.
///
/// Volontairement muette sur les chiffres : aucun compteur, aucun « il te
/// reste N … ». Le grade monte en utilisant l'application, et c'est tout ce
/// que la carte raconte. Une jauge suffit à donner envie de revenir, sans
/// dévoiler la mécanique.
class CarteGrade extends StatelessWidget {
  const CarteGrade({
    super.key,
    required this.niveau,
    required this.nbSignalements,
    this.estMax = false,
    this.serie = 0,
    this.afficherSerie = true,
    this.piedDePage,
    this.dense = false,
  });

  /// Grade actuel, 1..8.
  final int niveau;

  /// Total de signalements du compte — sert UNIQUEMENT à remplir la jauge.
  /// Ce nombre n'est jamais affiché.
  final int nbSignalements;

  /// Vrai quand le dernier grade est atteint.
  final bool estMax;

  /// Série de jours d'activité.
  final int serie;

  final bool afficherSerie;

  /// Texte libre affiché sous la jauge (ex. rappel du lien au compte).
  final String? piedDePage;

  /// Version resserrée pour les panneaux qui manquent de hauteur.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final sombre = Theme.of(context).brightness == Brightness.dark;
    final couleur = GradeRang.couleur(niveau);
    final n = niveau.clamp(1, GradeRang.noms.length);
    final max = estMax || n >= GradeRang.noms.length;
    final avancement = GradeRang.progression(n, nbSignalements);

    final texte = sombre ? KinColors.texteSombre : KinColors.texteClair;
    final secondaire = sombre
        ? KinColors.texteSecondaireSombre
        : KinColors.texteSecondaireClair;
    final fond = sombre ? const Color(0xFF1E2622) : const Color(0xFFF1F5F2);

    return Container(
      padding: EdgeInsets.all(dense ? 12 : 16),
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: couleur.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: dense ? 34 : 40,
                height: dense ? 34 : 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: couleur.withValues(alpha: 0.14),
                ),
                child: GradeRang(niveau: n, taille: dense ? 16 : 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      GradeRang.noms[n - 1].toUpperCase(),
                      style: TextStyle(
                        fontSize: dense ? 14 : 15.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: couleur,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'Grade $n sur ${GradeRang.noms.length}',
                      style: TextStyle(fontSize: 11.5, color: secondaire),
                    ),
                  ],
                ),
              ),
              Icon(
                max ? Icons.verified_rounded : Icons.trending_up_rounded,
                size: dense ? 20 : 24,
                color: couleur.withValues(alpha: 0.85),
              ),
            ],
          ),
          SizedBox(height: dense ? 10 : 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: avancement),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, valeur, _) => LinearProgressIndicator(
                value: valeur,
                minHeight: dense ? 7 : 9,
                backgroundColor: couleur.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(couleur),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            max
                ? 'Dernier grade atteint — ta progression continue.'
                : 'Ta progression avance en utilisant KinFlow.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: max ? couleur : texte,
            ),
          ),
          if (afficherSerie && serie > 0) ...[
            SizedBox(height: dense ? 8 : 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _puce(
                  icone: Icons.local_fire_department_rounded,
                  couleur: KinColors.accentTranche,
                  texte: '$serie jour${serie > 1 ? 's' : ''} d\'activité',
                  sombre: sombre,
                ),
              ],
            ),
          ],
          if (piedDePage != null && piedDePage!.isNotEmpty) ...[
            SizedBox(height: dense ? 8 : 10),
            Text(
              piedDePage!,
              style: TextStyle(fontSize: 11.5, height: 1.35, color: secondaire),
            ),
          ],
        ],
      ),
    );
  }

  Widget _puce({
    required IconData icone,
    required Color couleur,
    required String texte,
    required bool sombre,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icone, size: 14, color: couleur),
          const SizedBox(width: 4),
          Text(
            texte,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: couleur,
            ),
          ),
        ],
      ),
    );
  }
}
