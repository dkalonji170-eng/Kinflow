import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/itineraire_service.dart';
import 'package:latlong2/latlong.dart';

/// Une étape (drapeau) ne doit pas faire apparaître DEUX lignes superposées :
/// le tracé doit passer une seule fois par la chaussée de l'étape (comme pour
/// l'itinéraire simple), toujours en passant par le drapeau avant l'arrivée.
/// Vérifié sur des drapeaux posés sur le réseau filtré embarqué : deux points
/// du tracé à 40 indices d'écart ne doivent pas se retrouver à moins de 25 m.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  double dist(LatLng a, LatLng b) {
    final cosLat = b.latitude * 0.017453292519943295;
    final dLat = (a.latitude - b.latitude) * 111320;
    final dLon = (a.longitude - b.longitude) * 111320 * cosLat;
    return math.sqrt(dLat * dLat + dLon * dLon);
  }

  final casSurRoute = <({String nom, LatLng etape})>[
    (nom: '—4.31,15.32', etape: const LatLng(-4.31, 15.32)),
    (nom: '-4.32,15.34', etape: const LatLng(-4.32, 15.34)),
    (nom: 'Limete', etape: const LatLng(-4.33, 15.33)),
    (nom: '-4.33,15.34', etape: const LatLng(-4.33, 15.34)),
  ];

  for (final cas in casSurRoute) {
    test('étape ${cas.nom} : une seule ligne, passage par le drapeau',
        () async {
      const depart = LatLng(-4.3047, 15.3130);
      const arrivee = LatLng(-4.405, 15.437);
      final r = await ItineraireService().calculer(
        depart,
        arrivee,
        etapes: [cas.etape],
      );
      expect(r, isNotNull,
          reason: 'un tracé doit exister pour une étape sur le réseau');
      final pts = r!.first.points;

      // Le tracé passe par le drapeau (projection sur la chaussée, comme
      // OSRM/Yango) avant l'arrivée.
      var minDeltape = double.infinity;
      for (final p in pts) {
        minDeltape = dist(p, cas.etape) < minDeltape
            ? dist(p, cas.etape)
            : minDeltape;
      }
      expect(minDeltape, lessThan(100),
          reason: 'l\'itinéraire doit passer à moins de 100 m du drapeau');

      // Jamais de ligne qui se replie : deux points à >= 40 indices d'écart
      // ne doivent pas être à moins de 25 m (chaussée doublée).
      for (var i = 0; i + 40 < pts.length; i++) {
        for (var j = i + 40; j < pts.length; j++) {
          expect(dist(pts[i], pts[j]), greaterThanOrEqualTo(25),
              reason: 'tracé replié à l\'indice $i (${pts[i]}) vs $j');
        }
      }
    });
  }

  test('deux étapes successives sur le réseau : passage obligé par les deux',
      () async {
    const depart = LatLng(-4.3047, 15.3130);
    const arrivee = LatLng(-4.405, 15.437);
    const premiere = LatLng(-4.32, 15.34);
    const seconde = LatLng(-4.33, 15.33);
    final r = await ItineraireService().calculer(
      depart,
      arrivee,
      etapes: [premiere, seconde],
    );
    expect(r, isNotNull,
        reason: 'un tracé doit exister pour deux étapes sur le réseau');
    final pts = r!.first.points;

    double minDist(LatLng cible) {
      var md = double.infinity;
      for (final p in pts) {
        final d = dist(p, cible);
        if (d < md) md = d;
      }
      return md;
    }

    expect(minDist(premiere), lessThan(100),
        reason: 'l\'itinéraire doit passer à moins de 100 m de la 1ère étape');
    expect(minDist(seconde), lessThan(100),
        reason: 'l\'itinéraire doit passer à moins de 100 m de la 2ème étape');

    // Toujours une seule ligne au final, même à deux étapes.
    for (var i = 0; i + 40 < pts.length; i++) {
      for (var j = i + 40; j < pts.length; j++) {
        expect(dist(pts[i], pts[j]), greaterThanOrEqualTo(25),
            reason: 'tracé replié à l\'indice $i (${pts[i]}) vs $j');
      }
    }
  });
}