import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/offline_graph_codec.dart';

/// Vérifie que l'asset embarqué réel (généré par
/// `tool/fabrique_graphe.dart --overpass <osm.json>`) décode proprement et
/// couvre bien Kinshasa : garantit que la chaîne outil → codec → chargeur est
/// cohérente.
void main() {
  test('l\'asset assets/kinflow_routes.bin est lisible et couvre Kinshasa', () {
    final fichier = File('assets/kinflow_routes.bin');
    expect(fichier.existsSync(), isTrue,
        reason: 'Lancer dart run tool/fabrique_graphe.dart --overpass '
            '<osm.json> -o assets/kinflow_routes.bin avant ce test.');

    final brut = GrapheCodec.decoderHorsLigne(fichier.readAsBytesSync());
    expect(brut.nombreSegments, greaterThan(100));

    // Province de Kinshasa : centre urbain.
    const centre = LimitesGraphe(
      nord: -4.25,
      sud: -4.45,
      est: 15.40,
      ouest: 15.20,
    );
    expect(brut.couvre(centre), isTrue);

    final dans = brut.segmentsDans(centre);
    expect(dans.length, greaterThan(50));
    expect(dans.every((s) => s.points.length >= 2), isTrue);
  });
}
