import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/utils/temps_relatif.dart';

void main() {
  final reference = DateTime(2026, 10, 14, 12, 0, 0);

  String depuis(Duration ecart) =>
      tempsRelatif(reference.subtract(ecart), maintenant: reference);

  group('tempsRelatif', () {
    test('moins d\'une minute : « à l\'instant »', () {
      expect(depuis(const Duration(seconds: 0)), "à l'instant");
      expect(depuis(const Duration(seconds: 59)), "à l'instant");
    });

    test('minutes (singulier et pluriel)', () {
      expect(depuis(const Duration(minutes: 1)), 'il y a 1 minute');
      expect(depuis(const Duration(minutes: 15)), 'il y a 15 minutes');
      expect(depuis(const Duration(minutes: 59)), 'il y a 59 minutes');
    });

    test('heures (singulier et pluriel)', () {
      expect(depuis(const Duration(hours: 1)), 'il y a 1 heure');
      expect(depuis(const Duration(hours: 5)), 'il y a 5 heures');
      expect(depuis(const Duration(hours: 23)), 'il y a 23 heures');
    });

    test('jours (singulier et pluriel)', () {
      expect(depuis(const Duration(days: 1)), 'il y a 1 jour');
      expect(depuis(const Duration(days: 2)), 'il y a 2 jours');
      expect(depuis(const Duration(days: 29)), 'il y a 29 jours');
    });

    test('mois puis années', () {
      expect(depuis(const Duration(days: 60)), 'il y a 2 mois');
      expect(depuis(const Duration(days: 200)), 'il y a 7 mois');
      expect(depuis(const Duration(days: 365)), 'il y a 1 an');
      expect(depuis(const Duration(days: 365 * 3)), 'il y a 3 ans');
    });

    test('une date future est traitée comme « à l\'instant »', () {
      expect(
        tempsRelatif(reference.add(const Duration(hours: 2)),
            maintenant: reference),
        "à l'instant",
      );
    });
  });
}
