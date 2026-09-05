import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';

class TilePrefetchService {
  TilePrefetchService({required String nomMagasin})
      : _magasin = FMTCStore(nomMagasin);

  static const String _urlVoyager =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  static const Duration _dureeMinEntre = Duration(seconds: 30);
  static const int _maxTuilesParZoom = 200;
  static const Object _instanceId = 'kinflow_prefetch';

  final FMTCStore _magasin;
  StreamSubscription<TileEvent>? _abonnementTuiles;
  _RequetePrefetch? _requete;
  Timer? _timer;
  bool _enCours = false;
  DateTime? _dernierLancement;
  int _consecutifsImmobile = 0;

  void demander({
    required LatLng position,
    double? vitesse,
    double? cap,
    required int zoom,
  }) {
    _requete = _RequetePrefetch(
      position: position,
      vitesse: vitesse,
      cap: cap,
      zoom: zoom,
    );
    _programmer();
  }

  void _programmer() {
    if (_enCours || _timer != null) return;
    final dernier = _dernierLancement;
    Duration delai = Duration.zero;
    if (dernier != null) {
      final ecart = DateTime.now().difference(dernier);
      if (ecart < _dureeMinEntre) delai = _dureeMinEntre - ecart;
    }
    _timer = Timer(delai, () {
      _timer = null;
      _lancerSiPossible();
    });
  }

  Future<void> _lancerSiPossible() async {
    if (_enCours) return;
    final requete = _requete;
    if (requete == null) return;
    _requete = null;
    _enCours = true;
    _dernierLancement = DateTime.now();
    try {
      await _executer(requete);
    } catch (e) {
      debugPrint('[KinFlow] Préchargement des tuiles échoué: $e');
    } finally {
      _enCours = false;
      if (_requete != null) _programmer();
    }
  }

  Future<void> _executer(_RequetePrefetch requete) async {
    final deplace = (requete.vitesse ?? 0) > 1.5 && requete.cap != null;
    _consecutifsImmobile = deplace ? 0 : _consecutifsImmobile + 1;
    final bounds =
        _calculerBounds(requete.position, requete.vitesse, requete.cap,
            requete.zoom, deplace);
    await _telecharger(bounds, requete.zoom);
  }

  LatLngBounds _calculerBounds(
    LatLng position,
    double? vitesse,
    double? cap,
    int zoom,
    bool deplace,
  ) {
    final latRad = position.latitude * math.pi / 180;
    final metresParTuile =
        156543.03392 * math.cos(latRad) / math.pow(2, zoom).toDouble() * 256;

    if (deplace) {
      final avance =
          (4.0 + (vitesse ?? 0) * 0.4).clamp(4.0, 12.0) * metresParTuile;
      final arriere = 1.5 * metresParTuile;
      final demiLargeur = 1.5 * metresParTuile;
      return _rectangleOriente(
          position, cap!, avance, arriere, demiLargeur);
    }

    final expansion = math.min(_consecutifsImmobile, 4);
    final rayon = (2.0 + expansion * 1.2) * metresParTuile;
    final dLat = rayon / 111320.0;
    final dLon = rayon / (111320.0 * math.cos(latRad));
    return LatLngBounds(
      LatLng(position.latitude - dLat, position.longitude - dLon),
      LatLng(position.latitude + dLat, position.longitude + dLon),
    );
  }

  LatLngBounds _rectangleOriente(
    LatLng centre,
    double capDeg,
    double avance,
    double arriere,
    double demiLargeur,
  ) {
    final latRad = centre.latitude * math.pi / 180;
    final dLatParM = 1 / 111320.0;
    final dLonParM = 1 / (111320.0 * math.cos(latRad));
    final capRad = capDeg * math.pi / 180;

    final avantLat = math.cos(capRad) * dLatParM;
    final avantLon = math.sin(capRad) * dLonParM;
    final gaucheLat = math.cos(capRad + math.pi / 2) * dLatParM;
    final gaucheLon = math.sin(capRad + math.pi / 2) * dLonParM;

    LatLng coin(double f, double l) => LatLng(
          centre.latitude + avantLat * f + gaucheLat * l,
          centre.longitude + avantLon * f + gaucheLon * l,
        );

    final coins = [
      coin(avance, demiLargeur),
      coin(avance, -demiLargeur),
      coin(-arriere, demiLargeur),
      coin(-arriere, -demiLargeur),
    ];

    var minLat = coins.first.latitude;
    var maxLat = coins.first.latitude;
    var minLon = coins.first.longitude;
    var maxLon = coins.first.longitude;
    for (final c in coins) {
      if (c.latitude < minLat) minLat = c.latitude;
      if (c.latitude > maxLat) maxLat = c.latitude;
      if (c.longitude < minLon) minLon = c.longitude;
      if (c.longitude > maxLon) maxLon = c.longitude;
    }
    return LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));
  }

  Future<void> _telecharger(LatLngBounds bounds, int zoom) async {
    for (final z in [zoom, zoom + 1]) {
      if (z < 1 || z > 19) continue;
      final region = RectangleRegion(bounds).toDownloadable(
        minZoom: z,
        maxZoom: z,
        options: TileLayer(
          urlTemplate: _urlVoyager,
          userAgentPackageName: 'com.kinflow.kinflow',
        ),
      );
      final nombre = await _magasin.download.countTiles(region);
      if (nombre <= 0 || nombre > _maxTuilesParZoom) continue;
      final (:downloadProgress, :tileEvents) =
          _magasin.download.startForeground(
        region: region,
        parallelThreads: 2,
        skipExistingTiles: true,
        skipSeaTiles: true,
        instanceId: _instanceId,
      );
      _abonnementTuiles?.cancel();
      _abonnementTuiles = tileEvents.listen((_) {}, onError: (_) {});
      await downloadProgress.last;
    }
  }

  void dispose() {
    _timer?.cancel();
    _requete = null;
    _abonnementTuiles?.cancel();
    unawaited(_magasin.download.cancel(instanceId: _instanceId));
  }
}

class _RequetePrefetch {
  final LatLng position;
  final double? vitesse;
  final double? cap;
  final int zoom;
  const _RequetePrefetch({
    required this.position,
    this.vitesse,
    this.cap,
    required this.zoom,
  });
}
