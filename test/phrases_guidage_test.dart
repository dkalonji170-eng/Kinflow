import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/phrases_guidage.dart';
import 'package:kinflow/services/voix_guidage.dart' show TypeVirage;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PhrasesGuidage', () {
    test('sans personnalisation : les phrases par défaut', () async {
      SharedPreferences.setMockInitialValues({});
      final phrases = await PhrasesGuidage.charger();
      expect(phrases, PhrasesGuidage.parDefaut());
      expect(
        PhrasesGuidage.defautDepart(),
        'Itinéraire tracé avec succès.',
      );
      expect(
        PhrasesGuidage.defautArrivee(),
        'Vous êtes arrivé à destination. Merci de nous avoir accordé votre '
        'attention. À bientôt pour d\'autres aventures.',
      );
    });

    test('la phrase de départ est personnalisable', () async {
      SharedPreferences.setMockInitialValues({});
      await PhrasesGuidage.sauvegarder({
        'depart': 'C\'est parti, suivez la route indiquée.',
      });
      final phrases = await PhrasesGuidage.charger();
      expect(
        phrases['depart'],
        'C\'est parti, suivez la route indiquée.',
      );
    });

    test('sauvegarde puis rechargement d\'une phrase personnalisée', () async {
      SharedPreferences.setMockInitialValues({});
      await PhrasesGuidage.sauvegarder({
        'gauche_0': 'Dans 300 mètres, garez-vous à gauche.',
      });
      final phrases = await PhrasesGuidage.charger();
      expect(
        phrases['gauche_0'],
        'Dans 300 mètres, garez-vous à gauche.',
      );
      // Les autres phrases restent par défaut.
      expect(phrases['droite_0'], PhrasesGuidage.defautPour(TypeVirage.droite, 0));
    });

    test('les phrases par défaut ne sont pas écrasées en mémoire', () async {
      SharedPreferences.setMockInitialValues({});
      await PhrasesGuidage.sauvegarder({'arrivee': 'Bienvenue au bout.'});
      final phrases = await PhrasesGuidage.charger();
      expect(phrases['arrivee'], 'Bienvenue au bout.');
      expect(
        PhrasesGuidage.parDefaut()['arrivee'],
        'Vous êtes arrivé à destination. Merci de nous avoir accordé votre '
        'attention. À bientôt pour d\'autres aventures.',
      );
    });

    test('rétablir les défauts efface les personnalisations', () async {
      SharedPreferences.setMockInitialValues({});
      await PhrasesGuidage.sauvegarder({'gauche_2': 'Prenez à gauche maintenant.'});
      await PhrasesGuidage.reinitialiser();
      final phrases = await PhrasesGuidage.charger();
      expect(phrases, PhrasesGuidage.parDefaut());
    });

    test('une phrase personnalisée vide est ignorée (repli défaut)', () async {
      SharedPreferences.setMockInitialValues({
        'phrases_guidage_droite_1': '   ',
      });
      final phrases = await PhrasesGuidage.charger();
      expect(
        phrases['droite_1'],
        PhrasesGuidage.defautPour(TypeVirage.droite, 1),
      );
    });

    test('clé de stockage stables pour les 14 phrases éditables', () {
      expect(PhrasesGuidage.editables, hasLength(14));
      for (final p in PhrasesGuidage.editables) {
        expect(PhrasesGuidage.cleStockage(p.cle), startsWith('phrases_guidage_'));
      }
    });
  });
}