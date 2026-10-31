import 'dart:math' as math;

/// Nombre de barres dessinées dans la bulle d'un vocal. Assez pour lire la
/// forme de la voix, assez peu pour tenir dans une bulle de discussion (c'est
/// l'ordre de grandeur utilisé par WhatsApp).
const int barresFormeOnde = 40;

/// Niveau (dBFS) au-dessous duquel l'enregistrement est considéré comme
/// silencieux : aucune forme d'onde exploitable, on préférera un dessin de
/// secours côté affichage plutôt qu'une barre plate pleine hauteur.
const double seuilSilenceDb = -45.0;

/// Transforme des mesures d'amplitude micro en forme d'onde.
///
/// [mesuresDb] : niveaux en dBFS (négatifs, 0 = saturation) relevés pendant
/// l'enregistrement. Retourne [barres] valeurs entières 0..100, une par barre,
/// ou une liste vide si l'enregistrement est silencieux.
///
/// On garde le PIC de chaque tranche (la voix se lit mieux au pic qu'à la
/// moyenne), puis on convertit les dBFS en amplitude linéaire et on normalise
/// sur le pic du message : chaque vocal remplit ainsi toute la hauteur
/// disponible, quel que soit le niveau d'enregistrement.
List<int> formeOndeDepuisDb(
  List<double> mesuresDb, {
  int barres = barresFormeOnde,
}) {
  if (mesuresDb.isEmpty || barres <= 0) return const [];
  final pics = List<double>.filled(barres, -160.0);
  for (var i = 0; i < barres; i++) {
    final debut = (i * mesuresDb.length / barres).floor();
    final fin = ((i + 1) * mesuresDb.length / barres).ceil().clamp(
      debut + 1,
      mesuresDb.length,
    );
    var pic = -160.0;
    for (var j = debut; j < fin; j++) {
      if (mesuresDb[j] > pic) pic = mesuresDb[j];
    }
    pics[i] = pic;
  }
  final maxiDb = pics.reduce(math.max);
  if (!maxiDb.isFinite || maxiDb < seuilSilenceDb) return const [];
  final lineaires = [for (final db in pics) math.pow(10, db / 20.0).toDouble()];
  final maxi = lineaires.reduce(math.max);
  if (maxi <= 0) return const [];
  return [
    for (final v in lineaires)
      // Racine carrée : rend les passages calmes visibles sans écraser les
      // pics. Plancher à 6 % pour qu'une barre ne disparaisse jamais.
      (math.sqrt((v / maxi).clamp(0.0, 1.0)) * 100).round().clamp(6, 100),
  ];
}
