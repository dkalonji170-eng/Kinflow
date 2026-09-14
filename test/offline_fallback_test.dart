import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:kinflow/services/offline_routes.dart';
import 'package:latlong2/latlong.dart';

/// Le chargeur hors-ligne doit basculer proprement sur le réseau (Overpass)
/// — retourne null — quand la demande est hors de la zone couverte, sans
/// jamais geler l'UI ni relire l'asset en boucle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(OfflineRoutes.resetPourTest);

  test('zone dans Kinshasa : l\'asset embarqué sert les segments', () async {
    final centre = LatLngBounds(
      LatLng(-4.45, 15.20),
      LatLng(-4.25, 15.40),
    );
    final resultat = await OfflineRoutes.segmentsPour(centre);
    expect(resultat, isNotNull);
    expect(resultat!.length, greaterThan(50));
  });

  test('zone hors zone couverte : segmentsPour retourne null (repli Overpass)',
      () async {
    // Bien au nord de la bbox de l'asset (hors du réseau Kinshasa) → le
    // Dijkstra doit retomber sur Overpass, jamais sur un réseau troué.
    final dehors = LatLngBounds(
      LatLng(-4.10, 15.20),
      LatLng(-4.00, 15.35),
    );
    final resultat = await OfflineRoutes.segmentsPour(dehors);
    expect(resultat, isNull);
  });

  test('les appels répétés servent le cache sans recharger l\'asset',
      () async {
    final centre = LatLngBounds(
      LatLng(-4.45, 15.20),
      LatLng(-4.25, 15.40),
    );
    await OfflineRoutes.segmentsPour(centre);
    expect(OfflineRoutes.pret, isTrue);

    // Second appel avec un corridor très proche : cache + graphe en mémoire,
    // sans nouvelle lecture d'asset.
    final voisin = LatLngBounds(
      LatLng(-4.44, 15.21),
      LatLng(-4.26, 15.39),
    );
    final resultat = await OfflineRoutes.segmentsPour(voisin);
    expect(resultat, isNotNull);
  });
}