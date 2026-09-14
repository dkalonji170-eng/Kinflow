import 'package:flutter/material.dart';

import '../models/traffic_state.dart';

/// Sévérité du trafic (0 = fluide .. 3 = bloquée) : les tranches ci-dessous
/// sont la SEULE source de vérité, utilisée à la fois par le moteur local
/// (classement des candidats, distribution des couleurs) et par l'affichage
/// (coloration tronçon par tronçon). Modifier les bornes ici change partout
/// les règles vert / orange / rouge.
enum ClasseSeverite { fluide, orangeClair, orangeFonce, rouge, bloquee }

const double borneOrangeClair = 1.0;
const double borneOrangeFonce = 1.5;
const double borneRouge = 2.0;
const double borneBloquee = 2.5;

/// Tranche de sévérité d'une valeur de trafic.
ClasseSeverite classeSeverite(double severite) {
  if (severite < borneOrangeClair) return ClasseSeverite.fluide;
  if (severite < borneOrangeFonce) return ClasseSeverite.orangeClair;
  if (severite < borneRouge) return ClasseSeverite.orangeFonce;
  if (severite < borneBloquee) return ClasseSeverite.rouge;
  return ClasseSeverite.bloquee;
}

/// Couleur continue suivie par les rues et la ligne d'itinéraire : elle
/// interpole entre les 4 états (fluide, léger, gros, bloquée) selon la
/// sévérité, sans jamais sortir de la plage 0..3.
Color couleurSeverite(double severite) {
  final x = severite.clamp(0.0, 3.0);
  final lo = x.floor();
  final hi = lo >= 3 ? 3 : lo + 1;
  return Color.lerp(
    EtatTrafic.values[lo].couleur,
    EtatTrafic.values[hi].couleur,
    x - lo,
  )!;
}

/// Cumuls de longueur (mètres) par classe de sévérité, dans l'ordre de
/// [ClasseSeverite]. Une itération unique remplace les compteurs manuels de
/// chaque tranche (règles de classement + journal de distribution).
List<double> cumulLongueursParClasse(
  Iterable<(double severite, double longueur)> troncons,
) {
  final cumuls = List<double>.filled(ClasseSeverite.values.length, 0);
  for (final t in troncons) {
    cumuls[classeSeverite(t.$1).index] += t.$2;
  }
  return cumuls;
}