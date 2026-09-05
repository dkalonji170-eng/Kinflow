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

/// Télécharge toutes les régions de KinFlow dans le magasin, en sautant les
/// tuiles déjà présentes. Retourne le nombre total de tuiles téléchargées.
Future<int> telechargerTachesKinflow({
  required FMTCStore store,
  int parallelThreads = 4,
  void Function(String nom, int effectue, int total)? onProgression,
}) async {
  var total = 0;
  for (final tache in listTachesKinflow) {
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

    final (:downloadProgress, :tileEvents) =
        store.download.startForeground(
      region: region,
      parallelThreads: parallelThreads,
      skipExistingTiles: true,
      skipSeaTiles: true,
      retryFailedRequestTiles: true,
    );

    downloadProgress.listen(
      (progression) {
        onProgression?.call(
          tache.nom,
          progression.attemptedTilesCount,
          progression.maxTilesCount,
        );
      },
    );
    tileEvents.listen((_) {});

    await downloadProgress.last;
    total += nombre;
  }
  return total;
}
