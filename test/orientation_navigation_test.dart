import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:kinflow/services/orientation_navigation.dart';

/// Position de référence utilisée par les tests : un déplacement de
/// [metres] vers le nord correspond à environ `metres / 111320` degré.
LatLng _pointAuNord(LatLng depart, double metres) =>
    LatLng(depart.latitude + metres / 111320.0, depart.longitude);

void main() {
  group('ControleurOrientation', () {
    const depart = LatLng(-4.32, 15.31);

    test('le premier cap aligne immédiatement la carte', () {
      final c = ControleurOrientation();
      final rotation = c.mettreAJour(
        capBrutDegres: 90,
        position: depart,
        precisionMetres: 5,
      );
      expect(rotation, isNotNull);
      expect(rotation, closeTo(270, 0.001));
    });

    test('un virage de 90° est appliqué en UNE rotation complète', () {
      final c = ControleurOrientation();
      c.mettreAJour(capBrutDegres: 0, position: depart, precisionMetres: 5);

      // Le cap tourne progressivement : 30°, 60°, puis se stabilise à 90°.
      // Pendant la rotation, aucune consigne ne doit être émise.
      final pendant = [
        c.mettreAJour(
          capBrutDegres: 30,
          position: _pointAuNord(depart, 3),
          precisionMetres: 5,
        ),
        c.mettreAJour(
          capBrutDegres: 60,
          position: _pointAuNord(depart, 6),
          precisionMetres: 5,
        ),
      ];
      expect(pendant, everyElement(isNull));

      // Cap stabilisé à 90° : la carte reçoit directement la rotation finale.
      final finalRotation = c.mettreAJour(
        capBrutDegres: 90,
        position: _pointAuNord(depart, 9),
        precisionMetres: 5,
      );
      expect(finalRotation, isNotNull);
      expect(finalRotation, closeTo(270, 0.001));
    });

    test('aucune nouvelle rotation une fois le virage terminé', () {
      final c = ControleurOrientation();
      c.mettreAJour(capBrutDegres: 0, position: depart, precisionMetres: 5);
      c.mettreAJour(
        capBrutDegres: 30,
        position: _pointAuNord(depart, 3),
        precisionMetres: 5,
      );
      c.mettreAJour(
        capBrutDegres: 90,
        position: _pointAuNord(depart, 6),
        precisionMetres: 5,
      );
      c.mettreAJour(
        capBrutDegres: 90,
        position: _pointAuNord(depart, 9),
        precisionMetres: 5,
      );

      // Cap constant : la carte reste parfaitement figée, même après 50 m.
      for (var i = 1; i <= 10; i++) {
        final r = c.mettreAJour(
          capBrutDegres: 90,
          position: _pointAuNord(depart, 9 + i * 5.0),
          precisionMetres: 5,
        );
        expect(r, isNull, reason: 'rotation parasite au mètre ${i * 5}');
      }
    });

    test('le bruit de cap en ligne droite ne fait pas tourner la carte', () {
      final c = ControleurOrientation();
      c.mettreAJour(capBrutDegres: 0, position: depart, precisionMetres: 5);
      // Oscillations de ±10° : sous le seuil de 15°, aucune rotation.
      for (var i = 1; i <= 20; i++) {
        final r = c.mettreAJour(
          capBrutDegres: i.isEven ? 10 : 350,
          position: _pointAuNord(depart, i * 4.0),
          precisionMetres: 5,
        );
        expect(r, isNull);
      }
    });

    test('un cap invalide (-1) est ignoré', () {
      final c = ControleurOrientation();
      final r = c.mettreAJour(
        capBrutDegres: -1,
        position: depart,
        precisionMetres: 5,
      );
      expect(r, isNull);
    });

    test('la rotation reste figée à l\'arrêt', () {
      final c = ControleurOrientation();
      c.mettreAJour(capBrutDegres: 0, position: depart, precisionMetres: 5);
      // Aucun déplacement : même avec un cap très différent, rien ne bouge.
      for (var i = 0; i < 10; i++) {
        final r = c.mettreAJour(
          capBrutDegres: 180,
          position: depart,
          precisionMetres: 5,
        );
        expect(r, isNull);
      }
    });

    test('une précision dégradée majore la distance requise sans bloquer', () {
      final c = ControleurOrientation();
      c.mettreAJour(capBrutDegres: 0, position: depart, precisionMetres: 30);

      // 5 m parcourus mais GPS annoncé à ±30 m : la distance exigée est
      // majorée (2 m pour un virage franc + jusqu'à 12,5 m de majoration),
      // donc ce déplacement peut encore être du bruit — on attend.
      final tropTot = c.mettreAJour(
        capBrutDegres: 90,
        position: _pointAuNord(depart, 5),
        precisionMetres: 30,
      );
      expect(tropTot, isNull);

      // 20 m parcourus : le déplacement est avéré ; le cap est stabilisé, la
      // rotation complète est appliquée — là où un test de distance purement
      // désactivé aurait laissé la carte désalignée.
      final ensuite = c.mettreAJour(
        capBrutDegres: 90,
        position: _pointAuNord(depart, 20),
        precisionMetres: 30,
      );
      expect(ensuite, isNotNull);
      expect(ensuite, closeTo(270, 0.001));
    });

    test('une rotation initiale fournie évite le réalignement d\'entrée', () {
      final c = ControleurOrientation();
      c.reinitialiser(rotationInitialeDegres: 20);
      final r = c.mettreAJour(
        capBrutDegres: 0,
        position: depart,
        precisionMetres: 5,
      );
      expect(r, isNull);
    });
  });

  group('differenceAngulaireDegres', () {
    test('franchit le nord sans saut de 360°', () {
      expect(differenceAngulaireDegres(359, 1), closeTo(2, 1e-9));
      expect(differenceAngulaireDegres(1, 359), closeTo(-2, 1e-9));
    });
  });
}
