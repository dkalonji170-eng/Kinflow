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

  test("le point bleu reste ancré quand le zoom demandé est plafonné en haut",
      () {
    final pts = _routeKm(0.05);
    final vue = calculerVueItineraire(
      camera: _camera(pts),
      points: pts,
      debutRoute: 0,
      finRoute: pts.length - 1,
      zoomMax: 19,
    );
    expect(vue, isNotNull);
    expect(vue!.zoom, 19);
    final (sx, sy) = _decalageEcran(vue, pts.first);
    expect(sx.abs(), lessThan(1e-3));
    expect(sy, closeTo(800 * 2 / 3 - 400, 1e-3));
  });

  test('un long tracé descend sous zoomMin et reste dans la vue sans dérive',
      () {
    final pts = _routeKm(60);
    final vue = calculerVueItineraire(
      camera: _camera(pts),
      points: pts,
      debutRoute: 0,
      finRoute: pts.length - 1,
    );
    expect(vue, isNotNull);
    expect(vue!.zoom, lessThan(11));
    expect(vue.zoom, greaterThan(5));
    expect(vue.centre.latitude, closeTo(pts.first.latitude, 1.0));
    expect(vue.centre.longitude, closeTo(pts.first.longitude, 0.1));
    final (sx, sy) = _decalageEcran(vue, pts.first);
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

  test('un point parasite au milieu du tracé n\'envoie pas la vue sur l\'océan',
      () {
    final pts = <LatLng>[
      const LatLng(-4.304, 15.313),
      for (var i = 0; i <= 40; i++)
        LatLng(-4.304 - 0.05 * i / 40, 15.313 + 0.055 * i / 40),
      const LatLng(0, 0), // parasite loin du tracé (océan)
      const LatLng(-4.354, 15.368),
      for (var i = 0; i <= 20; i++)
        LatLng(-4.354 - 0.05 * i / 20, 15.368 + 0.062 * i / 20),
      const LatLng(-4.404, 15.43),
    ];
    final vue = calculerVueItineraire(
      camera: _camera(pts),
      points: pts,
      debutRoute: 1,
      finRoute: pts.length - 1,
    );
    expect(vue, isNotNull);
    expect(vue!.centre.longitude, greaterThan(15));
    expect(vue.centre.longitude, lessThan(16));
    expect(vue.centre.latitude, lessThan(-3));
    expect(vue.centre.latitude, greaterThan(-6));
    expect(vue.zoom, inInclusiveRange(11, 15));
  });
}