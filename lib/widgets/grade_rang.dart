import 'package:flutter/material.dart';

/// Insigne d'un grade, affiché sous l'avatar (comme les chevrons d'un
/// uniforme) :
///
///  - niveaux 1 à 3 → 1, 2 puis 3 écus (acier, bronze, bronze clair) ;
///  - niveaux 4 et 5 → une puis deux médailles (argent, or) ;
///  - niveau 6 → un faucon de feu ;
///  - niveau 7 → un faucon de feu plus ardent ;
///  - niveau 8 (dernier rang) → un faucon auréolé d'or.
///
/// L'écu remplace l'étoile : un insigne se lit comme un grade, une étoile se
/// lit comme une note. La couleur monte avec le rang pour que la progression
/// se voie d'un coup d'œil, même en petit.
class GradeRang extends StatelessWidget {
  const GradeRang({super.key, required this.niveau, this.taille = 18});

  /// Niveau du rang : 1 = Débutant … 8 = Légende.
  final int niveau;

  /// Taille d'un symbole.
  final double taille;

  static const List<String> noms = [
    'Débutant',
    'Apprenti',
    'Contributeur',
    'Vigilant',
    'Sentinelle',
    'Gardien',
    'Expert',
    'Légende',
  ];

  /// Nombre de signalements à partir duquel chaque grade est atteint
  /// (identique aux seuils du serveur, voir `mon_rang_signalements`).
  ///
  /// Interne : ces valeurs ne sont JAMAIS affichées. L'utilisateur sait
  /// seulement que sa progression monte en utilisant KinFlow.
  static const List<int> seuils = [0, 1, 5, 10, 25, 50, 100, 250];

  /// Premier signalement du grade [niveau] (1..8).
  static int seuil(int niveau) => seuils[niveau.clamp(1, noms.length) - 1];

  /// Grade atteint avec [nbSignalements] signalements (1..8).
  static int niveauPour(int nbSignalements) {
    var n = 1;
    for (var i = 0; i < seuils.length; i++) {
      if (nbSignalements >= seuils[i]) n = i + 1;
    }
    return n;
  }

  /// Progression (0..1) à l'intérieur du grade actuel : 0 = on vient de
  /// l'atteindre, 1 = le grade suivant est acquis.
  static double progression(int niveau, int nbSignalements) {
    final n = niveau.clamp(1, noms.length);
    if (n >= noms.length) return 1;
    final debut = seuils[n - 1];
    final etendue = seuils[n] - debut;
    if (etendue <= 0) return 1;
    return ((nbSignalements - debut) / etendue).clamp(0.0, 1.0);
  }

  /// Couleur de l'insigne : elle monte avec le grade (acier → bronze →
  /// argent → or → cuivre ardent).
  static Color couleur(int niveau) {
    switch (niveau.clamp(1, noms.length)) {
      case 1:
        return const Color(0xFF90A4AE);
      case 2:
        return const Color(0xFFB07A45);
      case 3:
        return const Color(0xFFC9A227);
      case 4:
        return const Color(0xFFB6C2C9);
      case 5:
        return const Color(0xFFC48A00);
      case 6:
        return const Color(0xFFE2721E);
      case 7:
        return const Color(0xFFD84315);
      default:
        return const Color(0xFFFFB300);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = niveau.clamp(1, 8);
    final Widget contenu;
    if (n <= 3) {
      contenu = _rangee(Icons.shield_rounded, couleur(n), n);
    } else if (n <= 5) {
      contenu = _rangee(Icons.workspace_premium_rounded, couleur(n), n - 3);
    } else if (n == 6) {
      contenu = _fauconDeFeu(1);
    } else if (n == 7) {
      contenu = _fauconDeFeu(2);
    } else {
      // Dernier rang : le faucon. L'emoji est dessiné par la plateforme, ce qui
      // garantit un vrai rapace sur toutes les cibles (pas d'icône Material).
      contenu = _fauconDeFeu(0, aureole: true);
    }

    return Tooltip(
      message: 'Grade : ${noms[n - 1]}',
      child: Semantics(label: 'Grade : ${noms[n - 1]}', child: contenu),
    );
  }

  /// Le faucon, éventuellement précédé de flammes : 1 flamme = faucon de feu,
  /// 2 flammes = faucon ardent, 0 flamme = faucon légendaire (auréolé d'or).
  Widget _fauconDeFeu(int flammes, {bool aureole = false}) {
    final faucon = Text(
      '🦅',
      style: TextStyle(fontSize: taille * 1.15, height: 1),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < flammes; i++)
          Text('🔥', style: TextStyle(fontSize: taille * 0.85, height: 1)),
        if (aureole)
          Container(
            padding: EdgeInsets.all(taille * 0.12),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  couleur(8).withValues(alpha: 0.55),
                  couleur(8).withValues(alpha: 0.0),
                ],
              ),
            ),
            child: faucon,
          )
        else
          faucon,
      ],
    );
  }

  /// Une rangée de [nombre] symboles identiques, serrés et centrés.
  Widget _rangee(IconData icone, Color couleur, int nombre) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < nombre; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Icon(
              icone,
              size: taille,
              color: couleur,
              shadows: const [
                Shadow(
                  color: Colors.black26,
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
