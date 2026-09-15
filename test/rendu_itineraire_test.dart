import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:kinflow/services/rendu_itineraire.dart';
import 'package:kinflow/services/traffic_simulator.dart';
import 'package:latlong2/latlong.dart';

List<Polyline> _rendre(List<LatLng> points, LatLng? departAncre) =>
    decouperItineraireParEtat(
      points: points,
      debutRoute: 2,
      finRoute: points.length - 1,
      debutVisuel: 0,
      fondSombre: false,
      severites: null,
      simulateur: TrafficSimulator(),
      zonePourPoint: (_) => null,
      departAncre: departAncre,
    );

void main() {
  final points = <LatLng>[
    const LatLng(-4.3250, 15.3100), // départ hors chaussée
    const LatLng(-4.3260, 15.3110),
    const LatLng(-4.3270, 15.3120), // début de la portion routée
    const LatLng(-4.3280, 15.3125),
    const LatLng(-4.3290, 15.3130),
  ];

  test('les pointillés de départ partent de la position bleue vivante', () {
    final ancre = const LatLng(-4.3200, 15.3050);
    final polylignes = _rendre(points, ancre);
    final raccord = polylignes.first;
    expect(raccord.pattern, StrokePattern.dotted());
    expect(raccord.points, [ancre, points[2]]);
  });

  test('sans position vivante, le raccord reste sur le tracé calculé', () {
    final polylignes = _rendre(points, null);
    expect(polylignes.first.points, points.sublist(0, 3));
  });
}