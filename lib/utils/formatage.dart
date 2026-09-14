// Formatage des valeurs affichées dans l'interface (bannières de trajet,
// détails de lieu) : distance, durée, heure. Fonctions pures, testables.

String formaterDistance(double metres) {
  if (metres >= 1000) {
    return '${(metres / 1000).toStringAsFixed(1)} km';
  }
  return '${metres.round()} m';
}

String formaterDuree(double secondes) {
  final minutes = (secondes / 60).round();
  if (minutes < 60) return '$minutes min';
  final heures = minutes ~/ 60;
  final restantes = minutes % 60;
  return restantes == 0 ? '$heures h' : '$heures h $restantes';
}

String formaterHeure(DateTime d) {
  final h = d.hour.toString().padLeft(2, '0');
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m';
}