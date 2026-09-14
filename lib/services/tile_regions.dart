// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';

const String urlTuilesVoyager =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String urlTuilesSatellite =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const String urlTuilesLabels =
    'https://basemaps.cartocdn.com/rastertiles/dark_only_labels/{z}/{x}/{y}.png';

class TacheTuiles {
  final String nom;
  final LatLngBounds limites;
  final String urlTemplate;
  final int minZoom;
  final int maxZoom;
  const TacheTuiles({
    required this.nom,
    required this.limites,
    required this.urlTemplate,
    required this.minZoom,
    required this.maxZoom,
  });
}

final TacheTuiles tacheAfrique = TacheTuiles(
  nom: 'Afrique',
  limites: LatLngBounds(
    LatLng(-35.0, -18.0),
    LatLng(37.5, 52.0),
  ),
  urlTemplate: urlTuilesVoyager,
  minZoom: 2,
  maxZoom: 6,
);

final TacheTuiles tacheRdc = TacheTuiles(
  nom: 'RDC',
  limites: LatLngBounds(
    LatLng(-8.0, 12.0),
    LatLng(6.0, 32.0),
  ),
  urlTemplate: urlTuilesVoyager,
  minZoom: 7,
  maxZoom: 9,
);

final TacheTuiles tacheKinshasa = TacheTuiles(
  nom: 'Kinshasa',
  limites: LatLngBounds(
    LatLng(-4.45, 15.20),
    LatLng(-4.20, 15.45),
  ),
  urlTemplate: urlTuilesVoyager,
  minZoom: 10,
  maxZoom: 16,
);

final TacheTuiles tacheSatellite = TacheTuiles(
  nom: 'Satellite',
  limites: LatLngBounds(
    LatLng(-4.45, 15.20),
    LatLng(-4.20, 15.45),
  ),
  urlTemplate: urlTuilesSatellite,
  minZoom: 13,
  maxZoom: 16,
);

final TacheTuiles tacheEtiquettes = TacheTuiles(
  nom: 'Étiquettes',
  limites: LatLngBounds(
    LatLng(-4.45, 15.20),
    LatLng(-4.20, 15.45),
  ),
  urlTemplate: urlTuilesLabels,
  minZoom: 13,
  maxZoom: 16,
);

final List<TacheTuiles> listTachesKinflow = [
  tacheAfrique,
  tacheRdc,
  tacheKinshasa,
  tacheSatellite,
  tacheEtiquettes,
];

/// Les fonds de carte clairs uniquement (route OSM) : c'est la carte
/// « vraiment téléchargeable » embarquée dans l'archive, sans le satellite
/// ni les étiquettes.
final List<TacheTuiles> listTachesClair = [
  tacheAfrique,
  tacheRdc,
  tacheKinshasa,
];

/// Télécharge les régions données dans le magasin, en sautant les tuiles déjà
/// présentes. Retourne le nombre total de tuiles téléchargées.
Future<int> telechargerTachesKinflow({
  required FMTCStore store,
  int parallelThreads = 4,
  int? rateLimit = 20,
  List<TacheTuiles>? regions,
  void Function(String nom, int effectue, int total)? onProgression,
}) async {
  final taches = regions ?? listTachesKinflow;
  const buildInstanceId = 'kinflow_build_tiles';
  var total = 0;
  for (final tache in taches) {
    final region = RectangleRegion(tache.limites).toDownloadable(
      minZoom: tache.minZoom,
      maxZoom: tache.maxZoom,
      options: TileLayer(
        urlTemplate: tache.urlTemplate,
        userAgentPackageName: 'com.kinflow.kinflow',
      ),
    );
    final nombre = await store.download.countTiles(region);
    if (nombre <= 0) continue;

    print('tile_regions: ${tache.nom} : $nombre tuiles à traiter');

    final (:downloadProgress, :tileEvents) =
        store.download.startForeground(
      region: region,
      parallelThreads: parallelThreads,
      rateLimit: rateLimit,
      skipExistingTiles: true,
      skipSeaTiles: true,
      retryFailedRequestTiles: true,
      instanceId: buildInstanceId,
    );

    // FMTC peut ne jamais fermer les flux dans certains cas de ralentissement
    // du serveur de tuiles ; on ne s'appuie donc pas sur `.last` mais sur un
    // garde-fou : fin dès 100 % rapportés, sinon annulation après une période
    // sans aucune progression (téléchargements suivants réssumables car le
    // magasin persiste, et `skipExistingTiles` évite de refaire les tuiles).
    final fin = Completer<void>();
    var dernierEvenement = DateTime.now();
    downloadProgress.listen(
      (progression) {
        dernierEvenement = DateTime.now();
        onProgression?.call(
          tache.nom,
          progression.attemptedTilesCount,
          progression.maxTilesCount,
        );
        if (progression.percentageProgress >= 100 && !fin.isCompleted) {
          fin.complete();
        }
      },
      onDone: () {
        if (!fin.isCompleted) fin.complete();
      },
      onError: (_) {
        if (!fin.isCompleted) fin.complete();
      },
    );
    tileEvents.listen((_) {});

    const silenceMax = Duration(seconds: 45);
    final delaiMax = DateTime.now().add(const Duration(minutes: 30));
    while (!fin.isCompleted) {
      if (DateTime.now().isAfter(delaiMax)) break;
      if (DateTime.now().difference(dernierEvenement) > silenceMax) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (!fin.isCompleted) {
      await store.download.cancel(instanceId: buildInstanceId);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final traites = await store.download.countTiles(region);
    total += traites;
    print('tile_regions: ${tache.nom} terminé ($traites tuiles en magasin)');
  }
  return total;
}
