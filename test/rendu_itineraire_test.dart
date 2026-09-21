import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/rendu_itineraire.dart';
import 'package:kinflow/services/traffic_simulator.dart';
import 'package:latlong2/latlong.dart';

const _points = <LatLng>[
  LatLng(-4.3250, 15.3100), // départ hors chaussée
  LatLng(-4.3260, 15.3110),
  LatLng(-4.3270, 15.3120), // début de la portion routée
  LatLng(-4.3280, 15.3125),
  LatLng(-4.3290, 15.3130),
];

void main() {
  test('les pointillés de départ partent de la position bleue vivante', () {
    const ancre = LatLng(-4.3200, 15.3050); // ~1,2 km du début routé
    final polylignes = construireRaccordDepart(
      points: _points,
      debutRoute: 2,
      debutVisuel: 0,
      fondSombre: false,
      departAncre: ancre,
    );
    expect(polylignes, hasLength(1));
    expect(polylignes.first.pattern, StrokePattern.dotted());
    expect(polylignes.first.points, [ancre, _points[2]]);
  });

  test('sans position vivante, le raccord reste sur le tracé calculé', () {
    final polylignes = construireRaccordDepart(
      points: _points,
      debutRoute: 2,
      debutVisuel: 0,
      fondSombre: false,
      departAncre: null,
    );
    expect(polylignes, hasLength(1));
    expect(polylignes.first.points, _points.sublist(0, 3));
  });

  test('quand la position bleue est à ≤ 18 m de la route, pas de pointillés', () {
    const ancre = LatLng(-4.3269, 15.3119); // ~15 m de points[2] (début routé)
    final polylignes = construireRaccordDepart(
      points: _points,
      debutRoute: 2,
      debutVisuel: 0,
      fondSombre: false,
      departAncre: ancre,
    );
    expect(polylignes, isEmpty);
  });

  test('après un parcours déjà commencé, plus aucun pointillé de départ', () {
    const ancre = LatLng(-4.3200, 15.3050);
    final polylignes = construireRaccordDepart(
      points: _points,
      debutRoute: 2,
      debutVisuel: 1,
      fondSombre: false,
      departAncre: ancre,
    );
    expect(polylignes, isEmpty);
  });

  group('pointillés d\'arrivée — limite de distance', () {
    final simulateur = TrafficSimulator();

    test('pas de pointillés si la destination est trop éloignée (> 500 m)',
        () {
      final points = [
        const LatLng(-4.330, 15.310),
        const LatLng(-4.335, 15.315),
        const LatLng(-4.340, 15.320), // ~780 m du dernier point routé
      ];
      final polylignes = decouperItineraireParEtat(
        points: points,
        debutRoute: 0,
        finRoute: 1,
        debutVisuel: 0,
        fondSombre: false,
        severites: null,
        simulateur: simulateur,
        zonePourPoint: (_) => null,
      );
      expect(polylignes, hasLength(1));
      expect(polylignes.first.pattern, const StrokePattern.solid());
    });

    test('pointillés dessinés quand la destination est proche (≤ 500 m)', () {
      final points = [
        const LatLng(-4.330, 15.310),
        const LatLng(-4.335, 15.315),
        const LatLng(-4.3355, 15.3155), // ~78 m du dernier point routé
      ];
      final polylignes = decouperItineraireParEtat(
        points: points,
        debutRoute: 0,
        finRoute: 1,
        debutVisuel: 0,
        fondSombre: false,
        severites: null,
        simulateur: simulateur,
        zonePourPoint: (_) => null,
      );
      expect(polylignes, hasLength(2));
      expect(polylignes.last.pattern, StrokePattern.dotted());
      expect(polylignes.last.points.last, points.last);
    });
  });
}
