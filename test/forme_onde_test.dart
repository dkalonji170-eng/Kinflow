import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/utils/forme_onde.dart';

void main() {
  group('formeOndeDepuisDb', () {
    test('aucune mesure : aucune barre', () {
      expect(formeOndeDepuisDb(const []), isEmpty);
    });

    test('un enregistrement silencieux ne fabrique pas de barre pleine', () {
      // Des niveaux tous très bas : mieux vaut laisser l'affichage dessiner une
      // forme de secours que prétendre à une voix pleine hauteur.
      final mesures = List<double>.filled(50, -60.0);
      expect(formeOndeDepuisDb(mesures), isEmpty);
    });

    test('le nombre de barres demandé est respecté', () {
      final mesures = [for (var i = 0; i < 500; i++) -30.0 + (i % 10)];
      expect(formeOndeDepuisDb(mesures).length, barresFormeOnde);
      expect(formeOndeDepuisDb(mesures, barres: 12).length, 12);
    });

    test('les valeurs restent bornées (6..100)', () {
      final mesures = [for (var i = 0; i < 200; i++) -45.0 + (i % 40)];
      for (final v in formeOndeDepuisDb(mesures)) {
        expect(v, inInclusiveRange(6, 100));
      }
    });

    test('une voix qui monte produit des barres croissantes', () {
      // Amplitude croissante de -40 dB à -6 dB : la forme d'onde doit croître.
      final mesures = [
        for (var i = 0; i < 400; i++) -40.0 + (34.0 * i / 399.0),
      ];
      final barres = formeOndeDepuisDb(mesures);
      expect(barres.length, barresFormeOnde);
      expect(barres.last, greaterThan(barres.first));
      // Croissance régulière : pas de retour en arrière, à 2 unités près.
      for (var i = 1; i < barres.length; i++) {
        expect(barres[i], greaterThanOrEqualTo(barres[i - 1] - 2));
      }
    });

    test('le pic du message est normalisé à 100 quelle que soit sa force', () {
      final faible = formeOndeDepuisDb([
        for (var i = 0; i < 120; i++) -30.0 + (i % 5),
      ]);
      final fort = formeOndeDepuisDb([
        for (var i = 0; i < 120; i++) -6.0 + (i % 5),
      ]);
      expect(faible.reduce((a, b) => a > b ? a : b), 100);
      expect(fort.reduce((a, b) => a > b ? a : b), 100);
    });
  });
}
