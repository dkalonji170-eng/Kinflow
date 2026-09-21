import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/voix_guidage.dart';
import 'package:latlong2/latlong.dart';

// Pas de construction de polyligne : ~33 m par point, pour que la fenêtre
// d'échantillonnage des caps (22 m) soit franchie en un point.
const double _pas = 0.0003;

List<LatLng> _versNord(int n) =>
    [for (var i = 0; i < n; i++) LatLng(-4.30 + _pas * i, 15.30)];

List<LatLng> _depuis(LatLng p, double dLat, double dLon, int n) => [
      for (var i = 1; i <= n; i++)
        LatLng(p.latitude + dLat * i, p.longitude + dLon * i),
    ];

void main() {
  group('calculerManoeuvres', () {
    test('ligne droite : aucune manoeuvre', () {
      expect(calculerManoeuvres(_versNord(20)), isEmpty);
    });

    test('virage à droite (nord puis est)', () {
      final nord = _versNord(15);
      final points = [...nord, ..._depuis(nord.last, 0, _pas, 15)];
      final manoeuvres = calculerManoeuvres(points);
      expect(manoeuvres, hasLength(1));
      expect(manoeuvres.single.type, TypeVirage.droite);
    });

    test('virage à gauche (nord puis ouest)', () {
      final nord = _versNord(15);
      final points = [...nord, ..._depuis(nord.last, 0, -_pas, 15)];
      final manoeuvres = calculerManoeuvres(points);
      expect(manoeuvres, hasLength(1));
      expect(manoeuvres.single.type, TypeVirage.gauche);
    });

    test('demi-tour (nord puis sud)', () {
      final nord = _versNord(15);
      final points = [...nord, ..._depuis(nord.last, -_pas, 0, 15)];
      final manoeuvres = calculerManoeuvres(points);
      expect(manoeuvres, hasLength(1));
      expect(manoeuvres.single.type, TypeVirage.demiTour);
    });

    test('deux virages éloignés : deux manoeuvres', () {
      final nord = _versNord(15);
      final est = _depuis(nord.last, 0, _pas, 15);
      final nord2 = _depuis(est.last, _pas, 0, 15);
      final points = [...nord, ...est, ...nord2];
      expect(calculerManoeuvres(points), hasLength(2));
    });

    test('tracé trop court : aucune manoeuvre', () {
      expect(calculerManoeuvres(_versNord(3)), isEmpty);
    });
  });

  group('instructionPour', () {
    test('rien au-delà de 300 m', () {
      expect(VoixGuidage.instructionPour(400, TypeVirage.gauche, -1), isNull);
    });

    test('300 m : première annonce', () {
      final r = VoixGuidage.instructionPour(300, TypeVirage.gauche, -1);
      expect(r, isNotNull);
      expect(r!.$1, 'Dans 300 mètres, tournez à gauche.');
      expect(r.$2, 0);
    });

    test('100 m : deuxième annonce', () {
      final r = VoixGuidage.instructionPour(100, TypeVirage.droite, 0);
      expect(r!.$1, 'Dans 100 mètres, tournez à droite.');
      expect(r.$2, 1);
    });

    test('50 m : annonce imminente', () {
      final r = VoixGuidage.instructionPour(40, TypeVirage.gauche, 1);
      expect(r!.$1, 'Tournez à gauche.');
      expect(r.$2, 2);
    });

    test('pas de répétition quand le niveau est déjà atteint', () {
      expect(VoixGuidage.instructionPour(90, TypeVirage.gauche, 1), isNull);
      expect(VoixGuidage.instructionPour(250, TypeVirage.gauche, 0), isNull);
      expect(VoixGuidage.instructionPour(20, TypeVirage.gauche, 2), isNull);
    });

    test('demi-tour', () {
      final r = VoixGuidage.instructionPour(100, TypeVirage.demiTour, 0);
      expect(r!.$1, 'Dans 100 mètres, faites demi-tour.');
    });
  });
}