import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kinflow/services/search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test(
      'géocodage inverse : une rafale de points GPS distincts déclenche des '
      'requêtes réseau strictement séquentielles, espacées d\'au moins 1 s',
      () async {
    final horodatages = <DateTime>[];

    // Client simulé : renvoie une réponse Nominatim valide et horodate chaque
    // requête réseau RÉELLEMENT reçue par le serveur.
    final client = MockClient((requete) async {
      horodatages.add(DateTime.now());
      // Petite latence réseau, comme dans la réalité.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(
        json.encode({
          'lat': '-4.35',
          'lon': '15.25',
          'name': 'Test',
          'display_name': 'Test, Kinshasa',
          'type': 'road',
          'category': 'highway',
          'address': {'road': 'Avenue Test', 'suburb': 'Gombe'},
        }),
        200,
      );
    });

    final service = SearchService();

    // Rafale de 8 points GPS distincts presque simultanés (la cause exacte de
    // la surcharge observée dans le rapport de diagnostic).
    final resultats = await Future.wait([
      for (var i = 0; i < 8; i++)
        service.obtenirInfosLieu(
          -4.3516883 + i * 0.0001,
          15.2500817 + i * 0.0001,
          client: client,
        ),
    ]);

    // Tous les appels aboutissent et sont correctement parsés.
    expect(resultats.length, 8);
    for (final r in resultats) {
      expect(r, isNotNull);
      expect(r!.rue, 'Avenue Test');
    }

    // Chaque point distinct doit générer un appel réseau réel (aucune clé
    // identique, donc aucune fusion par cache/coalescence possible).
    expect(horodatages.length, 8, reason: 'Un appel par point distinct');

    // Surtout : les appels réseau sont STRICTEMENT séquentiels et espacés.
    // Aucune requête ne part avant la fin (+délai) de la précédente.
    for (var i = 1; i < horodatages.length; i++) {
      final ecart = horodatages[i].difference(horodatages[i - 1]);
      expect(ecart.inMilliseconds, greaterThanOrEqualTo(1000),
          reason: 'Requête $i trop rapprochée de la précédente ($ecart)');
    }
  });
}
