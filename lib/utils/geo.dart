import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Petits utilitaires géométriques purs (projection équirectangulaire locale),
/// partagés entre l'écran principal et le widget de carte. Aucun état, aucune
/// dépendance à Flutter : testables et faciles à modifier.

/// Distance approximative entre deux points, en mètres, via la projection
/// équirectangulaire locale (précision suffisante à échelle urbaine).
double distanceMetres(LatLng a, LatLng b) {
  final cosLat = math.cos(b.latitude * math.pi / 180);
  final dLat = (a.latitude - b.latitude) * 111320;
  final dLon = (a.longitude - b.longitude) * 111320 * cosLat;
  return math.sqrt(dLat * dLat + dLon * dLon);
}

/// Distance haversine entre [a] et [b], précise à l'échelle de la sphère.
/// Sert aux mesures « exactes » (raccord d'étape, cône de vision), là où
/// l'équirectangulaire n'est qu'une approximation locale.
double distanceMetresHaversine(LatLng a, LatLng b) {
  const rayon = 6371000.0;
  final phi1 = a.latitude * math.pi / 180;
  final phi2 = b.latitude * math.pi / 180;
  final dPhi = (b.latitude - a.latitude) * math.pi / 180;
  final dLambda = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(phi1) *
          math.cos(phi2) *
          math.sin(dLambda / 2) *
          math.sin(dLambda / 2);
  return 2 * rayon * math.asin(math.sqrt(h));
}

/// Résultat de la projection orthogonale de [p] sur le segment le plus proche
/// d'une polyligne : [t] (0..1, position le long du segment), [d] (distance en
/// mètres au tracé) et le point projeté [proj].
class ProjSurAlignes {
  final int index;
  final double t;
  final double d;
  final LatLng proj;

  const ProjSurAlignes(this.index, this.t, this.d, this.proj);
}

/// Projette [p] sur la polyligne [points] et renvoie le segment le plus
/// proche (index, paramètre t, distance en mètres, point projeté). Null si la
/// polyligne n'a pas de segment.
ProjSurAlignes? projeterSurAlignes(LatLng p, List<LatLng> points) {
  ProjSurAlignes? meilleur;
  var minD = double.infinity;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    final cosLat = math.cos(b.latitude * math.pi / 180);
    final ax = (b.longitude - a.longitude) * cosLat;
    final ay = b.latitude - a.latitude;
    final bx = (p.longitude - a.longitude) * cosLat;
    final by = p.latitude - a.latitude;
    final len2 = ax * ax + ay * ay;
    if (len2 <= 0) continue;
    final t = ((bx * ax + by * ay) / len2).clamp(0.0, 1.0);
    final projLat = a.latitude + t * (b.latitude - a.latitude);
    final projLon = a.longitude + t * (b.longitude - a.longitude);
    final dLat = (p.latitude - projLat) * 111320;
    final dLon = (p.longitude - projLon) * 111320 * cosLat;
    final d = math.sqrt(dLat * dLat + dLon * dLon);
    if (d < minD) {
      minD = d;
      meilleur = ProjSurAlignes(
        i,
        t,
        d,
        LatLng(projLat, projLon),
      );
    }
  }
  return meilleur;
}

/// Distance minimale entre [p] et la polyligne [points], en mètres :
/// projection orthogonale sur chaque segment.
double distanceALignes(LatLng p, List<LatLng> points) =>
    projeterSurAlignes(p, points)?.d ?? double.infinity;

/// Cap en degrés (0 = nord) du vecteur [de] → [vers], convention
/// `atan2(dLon, dLat)` : identique à l'axe y-écran utilisé par la carte.
double capTrace(LatLng de, LatLng vers) {
  final dLat = vers.latitude - de.latitude;
  final dLon = vers.longitude - de.longitude;
  return math.atan2(dLon, dLat) * 180.0 / math.pi;
}

/// Rotation de la carte qui redresse le tracé [de] → [vers] à la verticale,
/// le point d'arrivée au-dessus du point de départ (même convention que le
/// suivi de navigation : direction du trajet vers le haut de l'écran).
double rotationTrace(LatLng de, LatLng vers) =>
    normaliserDegre(-capTrace(de, vers));

/// Ramène un angle en degrés dans [0, 360).
double normaliserDegre(double deg) {
  final r = deg % 360;
  return r < 0 ? r + 360 : r;
}

/// Écart orienté minimal en degrés pour passer de [de] à [vers], dans
/// ]−180, 180], en tournant toujours du côté le plus court.
double deltaRotation(double de, double vers) {
  var d = (vers - de) % 360;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}