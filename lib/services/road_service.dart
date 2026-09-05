import 'dart:async';
import 'dart:convert';
import 'dart:math' show max, min;
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/road_segment.dart';
import 'diagnostics_service.dart';

class _EntreeCache {
  final List<RoadSegment> segments;
  final DateTime fetchedAt;
  final LatLngBounds bounds;
  final bool detailsComplets;

  const _EntreeCache(
    this.segments,
    this.fetchedAt,
    this.bounds,
    this.detailsComplets,
  );
}

class RoadService {
  /// Plusieurs miroirs Overpass : le serveur principal est vite limité en
  /// débit (429/504) ; on bascule sur les suivants à chaque échec pour
  /// répartir la charge et rester disponible pendant les pics.
  static const List<String> _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
  ];

  static int _indexMiroir = 0;

  /// Boîte englobant la ville-province de Kinshasa : aucune route hors de
  /// cette zone n'est utile (Brazzaville est juste de l'autre côté du
  /// fleuve, une vue qui déborde ne doit jamais la colorer).
  static const double _kinLatMin = -5.20;
  static const double _kinLatMax = -3.90;
  static const double _kinLonMin = 15.00;
  static const double _kinLonMax = 16.45;

  static const _classesMajeures =
      'motorway|motorway_link|trunk|trunk_link|primary|primary_link'
      '|secondary|secondary_link|tertiary|tertiary_link';
  static const _classesSecondaires =
      'unclassified|residential|living_street|service|road';

  static const _cacheMax = 40;
  static const _dureeFraicheur = Duration(minutes: 30);

  /// v3 : la requête est désormais filtrée sur l'aire administrative de
  /// Kinshasa — les entrées v2 contiennent des routes de Brazzaville.
  static const _prefPrefixe = 'kinflow_road_cache_v3_';
  static const _prefMax = 20;

  /// Instance partagée : la carte et le calcul d'itinéraire utilisent le
  /// même cache, donc une zone déjà téléchargée n'est jamais retéléchargée.
  static final RoadService instance = RoadService._();

  RoadService._();

  factory RoadService() => instance;

  final Map<String, _EntreeCache> _cache = {};

  Future<List<RoadSegment>> obtenirRoutes(
    LatLngBounds bounds, {
    bool detailsComplets = false,
  }) async {
    // La demande est confinée à Kinshasa : une vue qui déborde sur
    // Brazzaville ou au-delà ne déclenche aucun téléchargement inutile.
    final borne = LatLngBounds(
      LatLng(
        max(bounds.south, _kinLatMin).clamp(_kinLatMin, _kinLatMax),
        max(bounds.west, _kinLonMin).clamp(_kinLonMin, _kinLonMax),
      ),
      LatLng(
        min(bounds.north, _kinLatMax).clamp(_kinLatMin, _kinLatMax),
        min(bounds.east, _kinLonMax).clamp(_kinLonMin, _kinLonMax),
      ),
    );
    if (borne.south >= borne.north || borne.west >= borne.east) {
      return const [];
    }

    final rond = _arrondir(borne);

    final enMemoire = _trouverEnMemoire(rond, detailsComplets);
    if (enMemoire != null) return enMemoire.segments;

    final persiste = await _trouverPersistant(rond, detailsComplets);
    if (persiste != null) {
      _mettreEnCache(persiste);
      Journal.i('ROUTES', 'Routes servies depuis le cache local', {
        'segments': persiste.segments.length,
      });
      return persiste.segments;
    }

    final regex = detailsComplets
        ? '^($_classesMajeures|$_classesSecondaires)\$'
        : '^$_classesMajeures\$';

    // Marge pour inclure les routes qui traversent le bord de la vue : la
    // priorité va à la zone visible, pas à toute la ville.
    const marge = 0.02;
    final etendu = LatLngBounds(
      LatLng(rond.south - marge, rond.west - marge),
      LatLng(rond.north + marge, rond.east + marge),
    );

    final segments = await _telecharger(regex, etendu);
    Journal.i(
        detailsComplets ? 'ROUTES' : 'CARTE',
        'Réseau routier téléchargé depuis Overpass', {
      'segments': segments.length,
      'details_complets': detailsComplets,
    });
    final entree =
        _EntreeCache(segments, DateTime.now(), etendu, detailsComplets);
    _mettreEnCache(entree);
    unawaited(_ecrirePersistant(entree));
    return segments;
  }

  static const _maxTentatives = 3;
  static const _baseBackoff = Duration(seconds: 2);

  Future<List<RoadSegment>> _telecharger(String regex, LatLngBounds bounds) async {
    final query = '''
[out:json][timeout:25];
area["boundary"="administrative"]["admin_level"="4"]["name"="Kinshasa"]->.kin;
(
  way["highway"~"$regex"](${bounds.south},${bounds.west},${bounds.north},${bounds.east})(area.kin);
);
out geom;
''';

    for (var tentative = 0; tentative < _maxTentatives; tentative++) {
      // Bascule vers le miroir suivant à chaque tentative : après un 429/504
      // ou un timeout, on n'écrase pas le même serveur surchargé.
      final endpoint = _endpoints[(_indexMiroir + tentative) % _endpoints.length];
      try {
        final reponse = await http
            .post(
              Uri.parse(endpoint),
              headers: {'User-Agent': 'KinFlow-App/1.0 (projet kinflow)'},
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 30));

        if (reponse.statusCode == 200) {
          _indexMiroir = (_indexMiroir + tentative + 1) % _endpoints.length;
          return compute(_parser, json.decode(reponse.body));
        }

        final resoumettre = reponse.statusCode == 429 ||
            reponse.statusCode == 504;
        if (!resoumettre) {
          throw Exception('Overpass: HTTP ${reponse.statusCode}');
        }

        final retryAfter = int.tryParse(
          reponse.headers['retry-after'] ?? '',
        );
        final delai = retryAfter != null && retryAfter > 0
            ? Duration(seconds: retryAfter)
            : _baseBackoff * (1 << tentative);
        Journal.a('CARTE', 'Surcharge Overpass, nouvelle tentative dans ${delai.inSeconds} s', {
          'code_http': reponse.statusCode,
          'tentative': tentative + 1,
          'miroir': endpoint,
        });
        await Future<void>.delayed(delai);
      } on TimeoutException {
        if (tentative >= _maxTentatives - 1) rethrow;
        final delai = _baseBackoff * (1 << tentative);
        Journal.a('CARTE', 'Délai dépassé Overpass, nouvelle tentative dans ${delai.inSeconds} s', {
          'tentative': tentative + 1,
          'miroir': endpoint,
        });
        await Future<void>.delayed(delai);
      } on http.ClientException {
        if (tentative >= _maxTentatives - 1) {
          _indexMiroir = (_indexMiroir + 1) % _endpoints.length;
          rethrow;
        }
        final delai = _baseBackoff * (1 << tentative);
        await Future<void>.delayed(delai);
      }
    }

    throw Exception('Overpass: échec après $_maxTentatives tentatives');
  }

  _EntreeCache? _trouverEnMemoire(LatLngBounds rond, bool detailsComplets) {
    for (final entree in _cache.values) {
      if (entree.detailsComplets || !detailsComplets) {
        if (_estFraiche(entree.fetchedAt) && _contient(entree.bounds, rond)) {
          return entree;
        }
      }
    }
    return null;
  }

  Future<_EntreeCache?> _trouverPersistant(
    LatLngBounds rond,
    bool detailsComplets,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cles =
          prefs.getKeys().where((k) => k.startsWith(_prefPrefixe)).toList();
      for (final cle in cles) {
        final brut = prefs.getString(cle);
        if (brut == null) continue;
        final entree = _entreeDepuisJson(json.decode(brut));
        if (entree == null) continue;
        if (entree.detailsComplets || !detailsComplets) {
          if (_estFraiche(entree.fetchedAt) && _contient(entree.bounds, rond)) {
            return entree;
          }
        }
      }
    } catch (e) {
      debugPrint('[KinFlow] Lecture cache routes échouée: $e');
      Journal.a('ROUTES', 'Cache routier local illisible', {'erreur': '$e'});
    }
    return null;
  }

  bool _estFraiche(DateTime date) =>
      DateTime.now().difference(date) < _dureeFraicheur;

  bool _contient(LatLngBounds conteneur, LatLngBounds contenu) =>
      conteneur.north >= contenu.north &&
      conteneur.south <= contenu.south &&
      conteneur.east >= contenu.east &&
      conteneur.west <= contenu.west;

  void _mettreEnCache(_EntreeCache entree) {
    final cle = _clePour(entree.bounds, entree.detailsComplets);
    if (_cache.length >= _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
    _cache[cle] = entree;
  }

  String _clePour(LatLngBounds b, bool detailsComplets) {
    final regex = detailsComplets ? 'd' : 'm';
    return '${b.north},${b.east},${b.south},${b.west}|$regex';
  }

  Future<void> _ecrirePersistant(_EntreeCache entree) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cle = _clePour(entree.bounds, entree.detailsComplets);
      final j = json.encode({
        'segments': [
          for (final s in entree.segments) _segmentVersJson(s),
        ],
        'fetchedAt': entree.fetchedAt.toIso8601String(),
        'bounds': {
          'north': entree.bounds.north,
          'east': entree.bounds.east,
          'south': entree.bounds.south,
          'west': entree.bounds.west,
        },
        'detailsComplets': entree.detailsComplets,
      });
      await prefs.setString(_prefPrefixe + cle, j);
      await _prunePersistant(prefs);
    } catch (e) {
      debugPrint('[KinFlow] Écriture cache routes échouée: $e');
    }
  }

  Future<void> _prunePersistant(SharedPreferences prefs) async {
    final cles =
        prefs.getKeys().where((k) => k.startsWith(_prefPrefixe)).toList();
    if (cles.length <= _prefMax) return;
    cles.sort();
    for (final k in cles.take(cles.length - _prefMax)) {
      await prefs.remove(k);
    }
  }

  _EntreeCache? _entreeDepuisJson(dynamic brut) {
    final j = brut as Map<String, dynamic>;
    final b = j['bounds'];
    if (b is! Map) return null;
    return _EntreeCache(
      [
        for (final e in (j['segments'] as List? ?? const []))
          _segmentDepuisJson(e as Map<String, dynamic>),
      ],
      DateTime.parse(j['fetchedAt'] as String),
      LatLngBounds(
        LatLng((b['south'] as num).toDouble(), (b['west'] as num).toDouble()),
        LatLng((b['north'] as num).toDouble(), (b['east'] as num).toDouble()),
      ),
      j['detailsComplets'] as bool? ?? false,
    );
  }

  Map<String, dynamic> _segmentVersJson(RoadSegment s) => {
        'id': s.id,
        'nom': s.nom,
        'classe': s.classe,
        'points': [
          for (final p in s.points) {'lat': p.latitude, 'lon': p.longitude},
        ],
      };

  RoadSegment _segmentDepuisJson(Map<String, dynamic> j) => RoadSegment(
        id: (j['id'] as num).toInt(),
        nom: j['nom'] as String? ?? '',
        classe: j['classe'] as String? ?? '',
        points: [
          for (final p in (j['points'] as List? ?? const []))
            LatLng(
              ((p as Map)['lat'] as num).toDouble(),
              (p['lon'] as num).toDouble(),
            ),
        ],
      );

  static List<RoadSegment> _parser(dynamic json) {
    final resultats = <RoadSegment>[];
    final elements =
        (json as Map<String, dynamic>)['elements'] as List? ?? const [];

    for (final e in elements) {
      if (e['type'] != 'way') continue;

      final tags = (e['tags'] as Map<String, dynamic>?) ?? const {};
      final geometry = (e['geometry'] as List?) ?? const [];
      if (geometry.length < 2) continue;

      final points = <LatLng>[];
      for (final g in geometry) {
        points.add(LatLng(
          (g['lat'] as num).toDouble(),
          (g['lon'] as num).toDouble(),
        ));
      }

      resultats.add(RoadSegment(
        id: (e['id'] as num).toInt(),
        nom: tags['name'] as String? ?? '',
        classe: tags['highway'] as String? ?? '',
        points: points,
      ));
    }

    return resultats;
  }

  LatLngBounds _arrondir(LatLngBounds b) {
    const f = 100.0;
    return LatLngBounds(
      LatLng(
        (b.south * f).floorToDouble() / f,
        (b.west * f).floorToDouble() / f,
      ),
      LatLng(
        (b.north * f).ceilToDouble() / f,
        (b.east * f).ceilToDouble() / f,
      ),
    );
  }
}
