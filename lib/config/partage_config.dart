/// Liens publics utilisés pour partager un espace ou une image.
///
/// ⚠️ Le domaine doit être le tien. Tant que `kinflow.cd` n'est pas en ligne,
/// le lien sert de « code » : l'ami le colle dans KinFlow (onglet
/// Informateurs > Ouvrir un espace) pour arriver sur l'espace.
abstract final class PartageConfig {
  static const String baseLienEspace = 'https://kinflow.cd/e';

  static const String signature = 'KinFlow — la circulation de Kin en direct';

  static String lienEspace(String jeton) => '$baseLienEspace/$jeton';

  /// Extrait le jeton d'un lien complet ou d'un simple code collé.
  static String extraireJeton(String brut) {
    final propre = brut.trim();
    if (propre.isEmpty) return '';
    final sansParametres = propre.split('?').first.split('#').first;
    final morceaux = sansParametres
        .split('/')
        .where((m) => m.trim().isNotEmpty)
        .toList();
    return morceaux.isEmpty ? '' : morceaux.last.trim();
  }
}
