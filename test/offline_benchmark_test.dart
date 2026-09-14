import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/offline_graph_codec.dart';

void main() {
  // Mesure le coût du décodage de l'asset embarqué réel. Sans réseau ni
  // isolate : c'est le coût minimal que le runtime (plus rapide en release)
  // reproduira. Objectif : rester bien sous la centaine de ms pour que le
  // routage hors-ligne ne ralentisse jamais l'UI.
  test('benchmark : décoder l\'asset complet et extraire un corridor reste '
      'rapide (seuil de garde)', () {
    final fichier = File('assets/kinflow_routes.bin');
    expect(fichier.existsSync(), isTrue);
    final octets = fichier.readAsBytesSync();

    // Décodage unique (ce que fait `compute` au premier calcul).
    final t0 = DateTime.now();
    final brut = GrapheCodec.decoderHorsLigne(octets);
    final decodeMs = DateTime.now().difference(t0).inMilliseconds;
    expect(brut.nombreSegments, greaterThan(100));

    // Extraction d'un corridor urbain (ce que fait `compute` par itinéraire).
    const centre = LimitesGraphe(
      nord: -4.25,
      sud: -4.45,
      est: 15.40,
      ouest: 15.20,
    );
    final t1 = DateTime.now();
    final dans = brut.segmentsDans(centre);
    final extractMs = DateTime.now().difference(t1).inMilliseconds;

    // Garde-fou volontairement tolérant : quelques centaines de ms en debug
    // VM suffisent à attraper une régression grossière (décodage en boucle,
    // explosion mémoire) sans être fragile sur des machines lentes.
    expect(decodeMs + extractMs, lessThan(500),
        reason: 'décodage+extraction trop lents sur le graphe embarqué '
            '(decode=${decodeMs}ms extract=${extractMs}ms)');
    expect(dans.length, greaterThan(50));
  });
}
