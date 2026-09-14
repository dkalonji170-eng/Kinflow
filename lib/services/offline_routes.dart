import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';

import '../models/road_segment.dart';
import 'offline_graph_codec.dart';

/// Chargeur du graphe routier embarqué (`assets/kinflow_routes.bin`).
///
/// Le fichier n'est lu qu'au premier calcul d'itinéraire et décodé dans un
/// isolat (`compute`) : le démarrage de l'app n'est jamais ralenti, le
/// résultat est conservé en mémoire pour toute la session. Les segments d'une
/// zone sont extraits dans un isolat puis mis en cache par zone arrondie :
/// les calculs répétés dans un même quartier sont instantanés.
class OfflineRoutes {
  static const String asset = 'assets/kinflow_routes.bin';

  static GrapheHorsLigneBrut? _graphe;
  static Future<GrapheHorsLigneBrut?>? _chargement;

  /// Une fois que le graphe a été tenté (succès OU échec), on ne relit plus
  /// jamais l'asset : sur un réseau faible, re-décoder en boucle gèlerait
  /// l'UI, contredisant l'objectif de rapidité.
  static bool _tente = false;

  /// Segments par zone arrondie : le corridor d'un itinéraire varie à chaque
  /// calcul, on regroupe donc les boîtes voisines pour réutiliser l'extraction.
  static final Map<String, List<RoadSegment>> _cacheSegments = {};
  static const int _maxEntreesCache = 24;

  /// Remet l'état à zéro (tests) : re-permet une tentative de chargement.
  @visibleForTesting
  static void resetPourTest() {
    _graphe = null;
    _chargement = null;
    _tente = false;
    _cacheSegments.clear();
  }

  /// Graphe déjà décodé : permet de savoir si le repli réseau s'impose sans
  /// déclencher un chargement.
  static bool get pret => _graphe != null;

  /// Vrai si l'asset a déjà été tenté sans succès : l'itinéraire sait qu'il
  /// ne doit PAS insister sur le hors-ligne et bascule direct vers le réseau
  /// (Overpass), au lieu de relancer un décode inutile.
  static bool get indisponible => _tente && _graphe == null;

  /// Charge le graphe embarqué (une seule fois) et le garde en mémoire.
  /// Les appels concurrents partagent le même chargement en cours.
  static Future<GrapheHorsLigneBrut?> charger() {
    final enCours = _chargement;
    if (enCours != null) return enCours;
    if (_tente) return Future.value(_graphe);
    final chargement = _charger();
    _chargement = chargement;
    return chargement;
  }

  static Future<GrapheHorsLigneBrut?> _charger() async {
    try {
      final data = await rootBundle.load(asset);
      if (data.lengthInBytes <= 6) {
        debugPrint('[KinFlow] Asset $asset absent ou vide — repli réseau.');
        return null;
      }
      final octets =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final graphe = await compute(GrapheCodec.decoderHorsLigne, octets);
      _graphe = graphe;
      debugPrint('[KinFlow] Graphe hors-ligne prêt : '
          '${graphe.nombreSegments} segments.');
      return graphe;
    } catch (e) {
      debugPrint('[KinFlow] Chargement du graphe hors-ligne échoué : $e');
      return null;
    } finally {
      _tente = true;
      _chargement = null;
    }
  }

  /// Segments embarqués couvrant [zone], ou `null` si l'asset est absent ou
  /// s'il ne couvre pas entièrement la zone : l'appelant doit alors basculer
  /// sur le réseau (Overpass) pour ne jamais servir un réseau troué au
  /// Dijkstra. Efficace même en rafale : pas de relecture d'asset ni de
  /// re-décodage inutiles.
  static Future<List<RoadSegment>?> segmentsPour(LatLngBounds zone) async {
    // Court-circuit rapide : asset déjà déclaré indisponible → repli réseau
    // sans attendre.
    if (indisponible) return null;

    final cle = _cleZone(zone);
    final enCache = _cacheSegments[cle];
    if (enCache != null) return enCache;

    final graphe = await charger();
    final limites = LimitesGraphe(
      nord: zone.north,
      sud: zone.south,
      est: zone.east,
      ouest: zone.west,
    );
    if (graphe == null || !graphe.couvre(limites)) return null;

    final segments = await compute(
      _decoderSegments,
      (graphe, limites),
    );
    _cacheSegments[cle] = segments;
    if (_cacheSegments.length > _maxEntreesCache) {
      _cacheSegments.remove(_cacheSegments.keys.first);
    }
    return segments;
  }

  /// Clé de cache par zone arrondie (~11 m) : deux corridors voisins partagent
  /// la même extraction.
  static String _cleZone(LatLngBounds b) {
    const precision = 6;
    int arrondi(double v) => (v * precision).round();
    return '${arrondi(b.south)}_${arrondi(b.north)}'
        '_${arrondi(b.west)}_${arrondi(b.east)}';
  }
}

List<RoadSegment> _decoderSegments((GrapheHorsLigneBrut, LimitesGraphe) args) {
  return args.$1.segmentsDans(args.$2);
}
