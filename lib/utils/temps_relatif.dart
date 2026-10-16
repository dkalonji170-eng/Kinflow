/// Temps écoulé depuis [moment], écrit en français lisible.
///
/// Rend « à l'instant », « il y a 15 minutes », « il y a 1 heure »,
/// « il y a 2 jours », « il y a 3 mois », « il y a 1 an ». Sert notamment à
/// dater la dernière position connue d'un(e) ami(e) sur la carte, quand son
/// téléphone ne partage plus en direct.
///
/// [maintenant] permet de figer la référence (tests) ; par défaut l'instant
/// présent. Une date future est traitée comme « à l'instant ».
String tempsRelatif(DateTime moment, {DateTime? maintenant}) {
  final reference = maintenant ?? DateTime.now();
  final ecoule = reference.difference(moment);
  if (ecoule.inSeconds < 60) return "à l'instant";

  final minutes = ecoule.inMinutes;
  if (minutes < 60) {
    return 'il y a $minutes ${minutes == 1 ? 'minute' : 'minutes'}';
  }

  final heures = ecoule.inHours;
  if (heures < 24) {
    return 'il y a $heures ${heures == 1 ? 'heure' : 'heures'}';
  }

  final jours = ecoule.inDays;
  if (jours < 30) {
    return 'il y a $jours ${jours == 1 ? 'jour' : 'jours'}';
  }

  final annees = jours ~/ 365;
  if (annees >= 1) {
    return 'il y a $annees ${annees == 1 ? 'an' : 'ans'}';
  }

  final mois = (jours / 30.44).round().clamp(1, 11);
  return 'il y a $mois mois';
}
