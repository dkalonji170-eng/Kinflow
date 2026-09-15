import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:kinflow/services/vue_itineraire.dart';
import 'package:latlong2/latlong.dart';

MapCamera _camera(List<LatLng> pts) =>
    MapCamera(
      crs: const Epsg3857(),
      center: LatLng(
        (pts.first.latitude + pts.last.latitude) / 2,
        (pts.first.longitude + pts.last.longitude) / 2,
      ),
      zoom: 15,
      rotation: 0,
      nonRotatedSize: const math.Point<double>(400, 800),
    );

List<LatLng> _routeKm(double km) {
  final n = 60;
  return [
    for (var i = 0; i <= n; i++)
      LatLng(-4.33 + km / 111.0 * i / n, 15.32),
  ];
}

/// Décalage écran (non roté) du point bleu par rapport au centre de la vue,
/// dans le repère redressé de la carte.
(double, double) _decalageEcran(VueItineraireResultat vue, LatLng depart) {
  final cam = _camera(_routeKm(2));
  final d = cam.project(depart, vue.zoom) - cam.project(vue.centre, vue.zoom);
  final t = vue.rotation * math.pi / 180;
  final sx = d.x * math.cos(t) - d.y * math.sin(t);
  final sy = d.x * math.sin(t) + d.y * math.cos(t);
  return (sx, sy);
}

void main() {
  test('centre, zoom et rotation restent sur le parcours (pas de dérive)', () {
    final pts = _routeKm(7);
    final vue = calculerVueItineraire(
      camera: _camera(pts),
      points: pts,
      debutRoute: 0,
      finRoute: pts.length - 1,
    );
    expect(vue, isNotNull);
    expect(vue!.centre.latitude, closeTo(pts.first.latitude, 0.1));
    expect(vue.centre.longitude, closeTo(pts.first.longitude, 0.1));
    expect(vue.zoom, inInclusiveRange(11, 15));
  });

  test("le point bleu est ancré au centre horizontal, à 2/3 de la hauteur", () {
    final pts = _routeKm(2);
    final vue = calculerVueItineraire(
      camera: _camera(pts),
      points: pts,
      debutRoute: 0,
      finRoute: pts.length - 1,
    );
    final (sx, sy) = _decalageEcran(vue!, pts.first);
    expect(sx.abs(), lessThan(1e-3));
    expect(sy, closeTo(800 * 2 / 3 - 400, 1e-3));
  });

  test('le zoom grandit pour un trajet court au lieu de dézoomer', () {
    final pts = _routeKm(1);
    final vue = calculerVueItineraire(
      camera: _camera(pts),
      points: pts,
      debutRoute: 0,
      finRoute: pts.length - 1,
    );
    expect(vue!.zoom, greaterThan(15));
  });

  test('rotation verticalise un tracé est-ouest (vert en haut)', () {
    final pts = <LatLng>[
      LatLng(-4.33, 15.30),
      LatLng(-4.33, 15.36),
    ];
    final vue = calculerVueItineraire(
      camera: _camera(pts),
      points: pts,
      debutRoute: 0,
      finRoute: pts.length - 1,
    );
    final r = vue!.rotation % 360;
    expect(r, anyOf(closeTo(90.0, 0.5), closeTo(270.0, 0.5)));
  });
}