// ignore_for_file: avoid_print

// Chargement des POIs (points d'intérêt) depuis Overpass, indépendant de la
// carte. Extraite de `traffic_map.dart` pour isoler toute la logique réseau :
// bascule entre miroirs, disjoncteur, repli exponentiel et décodage.
import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random, min;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'diagnostics_service.dart';
import 'road_service.dart' show OverpassGate;

/// Point d'intérêt affiché sur la carte.
class Poi {
  final LatLng point;
  final String nom;
  final String type;
  const Poi(this.point, this.nom, this.type);
}

const double zoomMinPois = 14.0;
const double zoomNomPois = 16.5;
const int maxPois = 500;
const int maxPoisParType = 30;
const int maxPoisVisiblesParType = 10;

/// Miroirs Overpass pour les POIs de la carte : le serveur principal est
/// vite limité en débit (429/504) ; on bascule sur les suivants à chaque
/// échec, et l'index est mémorisé entre deux appels pour ne jamais reparler
/// systématiquement sur le même serveur.
const List<String> endpointsPoisOverpass = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
  'https://overpass.openstreetmap.ru/api/interpreter',
];

int _indexMiroirPois = 0;

/// Disjoncteur pour le chargement des POIs Overpass : après plusieurs
/// échecs consécutifs, on arrête de marteler le serveur et on attend.
class CircuitBreakerPois {
  static int _echecsConsecutifs = 0;
  static DateTime? _ouvertJusquau;
  static const _seuilEchecs = 4;
  static const _cooldownBase = Duration(seconds: 45);
  static var _cooldownMultiplier = 1;

  static bool get ouvert {
    if (_ouvertJusquau == null) return false;
    if (DateTime.now().isAfter(_ouvertJusquau!)) {
      _ouvertJusquau = null;
      return false;
    }
    return true;
  }

  static void enregistrerSucces() {
    _echecsConsecutifs = 0;
    _cooldownMultiplier = 1;
  }

  static void enregistrerEchec() {
    _echecsConsecutifs++;
    if (_echecsConsecutifs >= _seuilEchecs) {
      final cooldown = _cooldownBase * _cooldownMultiplier;
      _ouvertJusquau = DateTime.now().add(cooldown);
      _cooldownMultiplier = (_cooldownMultiplier * 2).clamp(1, 8);
    }
  }
}

Duration _jitterPois(Duration base) {
  final jitterMs = min(1000, Random().nextInt(1000));
  return base + Duration(milliseconds: jitterMs);
}

List<Poi> parserPois(dynamic json) {
  final resultats = <Poi>[];
  final elements =
      (json as Map<String, dynamic>)['elements'] as List? ?? const [];

  for (final e in elements) {
    final tags = (e['tags'] as Map<String, dynamic>?) ?? const {};

    double? lat = (e['lat'] as num?)?.toDouble();
    double? lon = (e['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      final centre = (e['center'] as Map?) ?? const {};
      lat = (centre['lat'] as num?)?.toDouble();
      lon = (centre['lon'] as num?)?.toDouble();
    }
    if (lat == null || lon == null) continue;

    final type = (tags['amenity'] ??
            tags['shop'] ??
            tags['tourism'] ??
            tags['leisure'] ??
            tags['office']
        ).toString();
    if (type.isEmpty) continue;

    final nom = (tags['name'] ?? '').toString();

    resultats.add(Poi(LatLng(lat, lon), nom, type));
  }

  final parType = <String, List<Poi>>{};
  for (final poi in resultats) {
    final liste = parType.putIfAbsent(poi.type, () => []);
    if (liste.length < maxPoisParType) liste.add(poi);
  }

  final limites = <Poi>[
    for (final liste in parType.values) ...liste,
  ];

  limites.sort((a, b) {
    final aNom = a.nom.isEmpty ? 1 : 0;
    final bNom = b.nom.isEmpty ? 1 : 0;
    if (aNom != bNom) return aNom - bNom;
    return prioritePoi(a.type).compareTo(prioritePoi(b.type));
  });

  return limites.take(maxPois).toList();
}

(IconData, Color) iconePoi(String type) {
  switch (type) {
    case 'restaurant':
    case 'cafe':
    case 'bar':
    case 'pub':
      return (Icons.restaurant, const Color(0xFFE65100));
    case 'school':
    case 'college':
    case 'university':
      return (Icons.school, const Color(0xFF6A1B9A));
    case 'hospital':
    case 'clinic':
      return (Icons.local_hospital, const Color(0xFFC62828));
    case 'pharmacy':
      return (Icons.local_pharmacy, const Color(0xFFE53935));
    case 'bank':
      return (Icons.account_balance, const Color(0xFF00695C));
    case 'marketplace':
    case 'market':
      return (Icons.storefront, const Color(0xFFEF6C00));
    case 'place_of_worship':
    case 'church':
    case 'mosque':
      return (Icons.church, const Color(0xFF6D4C41));
    case 'fuel':
      return (Icons.local_gas_station, const Color(0xFF37474F));
    case 'police':
      return (Icons.local_police, const Color(0xFF283593));
    case 'fire_station':
      return (Icons.local_fire_department, const Color(0xFFD32F2F));
    case 'post_office':
      return (Icons.local_post_office, const Color(0xFF1565C0));
    case 'library':
      return (Icons.local_library, const Color(0xFFF57F17));
    case 'cinema':
      return (Icons.movie, const Color(0xFF7B1FA2));
    case 'theatre':
      return (Icons.theater_comedy, const Color(0xFF8E24AA));
    case 'parking':
      return (Icons.local_parking, const Color(0xFF1565C0));
    case 'taxi':
      return (Icons.local_taxi, const Color(0xFFF9A825));
    case 'supermarket':
      return (Icons.shopping_cart, const Color(0xFF2E7D32));
    case 'mall':
      return (Icons.local_mall, const Color(0xFF388E3C));
    case 'convenience':
    case 'general':
    case 'bakery':
    case 'butcher':
      return (Icons.store, const Color(0xFF00897B));
    case 'hotel':
    case 'guest_house':
      return (Icons.hotel, const Color(0xFF1E88E5));
    case 'museum':
      return (Icons.museum, const Color(0xFF5D4037));
    case 'attraction':
      return (Icons.attractions, const Color(0xFFD81B60));
    case 'viewpoint':
      return (Icons.photo_camera, const Color(0xFF43A047));
    case 'park':
      return (Icons.park, const Color(0xFF2E7D32));
    case 'stadium':
    case 'sports_centre':
      return (Icons.stadium, const Color(0xFFEF6C00));
    case 'government':
    case 'embassy':
      return (Icons.account_balance, const Color(0xFF455A64));
    default:
      return (Icons.place, const Color(0xFF757575));
  }
}

int prioritePoi(String type) {
  switch (type) {
    case 'hospital':
    case 'clinic':
      return 0;
    case 'school':
    case 'college':
    case 'university':
      return 1;
    case 'marketplace':
    case 'market':
      return 2;
    case 'fuel':
      return 3;
    case 'police':
      return 4;
    case 'fire_station':
      return 5;
    case 'place_of_worship':
    case 'church':
    case 'mosque':
      return 6;
    case 'bank':
      return 7;
    case 'pharmacy':
      return 8;
    case 'post_office':
      return 9;
    case 'library':
      return 10;
    case 'parking':
      return 11;
    case 'park':
      return 12;
    case 'hotel':
    case 'guest_house':
      return 13;
    case 'supermarket':
    case 'mall':
      return 14;
    case 'museum':
      return 15;
    case 'cinema':
    case 'theatre':
      return 16;
    case 'stadium':
    case 'sports_centre':
      return 17;
    case 'taxi':
      return 18;
    case 'government':
    case 'embassy':
      return 19;
    case 'restaurant':
      return 20;
    case 'cafe':
      return 21;
    case 'bar':
    case 'pub':
      return 22;
    case 'convenience':
    case 'general':
    case 'bakery':
    case 'butcher':
      return 23;
    case 'attraction':
    case 'viewpoint':
      return 24;
    default:
      return 25;
  }
}

/// Service de téléchargement des POIs. Gère la bascule de miroir Overpass,
/// le disjoncteur global et le repli exponentiel entre tentatives.
class PoiService {
  /// Télécharge les POIs d'une zone. Lève une exception si tous les miroirs
  /// échouent ou si le disjoncteur est ouvert.
  Future<List<Poi>> telechargerPois(LatLngBounds bounds) async {
    // Requête limitée à la zone visible (plus petite marge) : Overpass
    // résout un petit bbox en une fraction de seconde avec un impact très
    // réduit sur ses quotas, contrairement à un balayage de toute la ville.
    final query = '''
[out:json][timeout:25];
(
  nwr["amenity"~"^(restaurant|cafe|bar|pub|school|college|university|hospital|clinic|pharmacy|bank|marketplace|market|place_of_worship|church|mosque|fuel|police|fire_station|post_office|library|cinema|theatre|parking|taxi)\$"](${bounds.south},${bounds.west},${bounds.north},${bounds.east});
  nwr["shop"~"^(supermarket|mall|convenience|general|bakery|butcher)\$"](${bounds.south},${bounds.west},${bounds.north},${bounds.east});
  nwr["tourism"~"^(hotel|guest_house|museum|attraction|viewpoint)\$"](${bounds.south},${bounds.west},${bounds.north},${bounds.east});
  nwr["leisure"~"^(park|stadium|sports_centre)\$"](${bounds.south},${bounds.west},${bounds.north},${bounds.east});
  nwr["office"~"^(government|embassy)\$"](${bounds.south},${bounds.west},${bounds.north},${bounds.east});
);
out center tags;
''';

    const maxTentatives = 3;
    const baseBackoff = Duration(seconds: 3);

    if (CircuitBreakerPois.ouvert) {
      throw Exception('Overpass POI: disjoncteur ouvert');
    }

    // Bascule sur un miroir Overpass différent à chaque tentative pour ne
    // pas marteler un serveur déjà limité en débit (429/504).
    for (var tentative = 0; tentative < maxTentatives; tentative++) {
      final endpoint = endpointsPoisOverpass[
          (_indexMiroirPois + tentative) % endpointsPoisOverpass.length];
      // File d'attente globale : les POIs partent en série avec les routes
      // et la recherche, jamais en rafale.
      await OverpassGate.attendreCreneau();
      if (CircuitBreakerPois.ouvert) {
        throw Exception('Overpass POI: disjoncteur ouvert pendant la boucle');
      }
      try {
        final reponse = await http
            .post(
              Uri.parse(endpoint),
              headers: {'User-Agent': 'KinFlow-App/1.0 (projet kinflow)'},
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 25));

        if (reponse.statusCode == 200) {
          _indexMiroirPois = (_indexMiroirPois + tentative + 1) %
              endpointsPoisOverpass.length;
          CircuitBreakerPois.enregistrerSucces();
          return compute(parserPois, json.decode(reponse.body));
        }

        final resoumettre =
            reponse.statusCode == 429 || reponse.statusCode == 504;
        if (!resoumettre) {
          throw Exception('Overpass POI: HTTP ${reponse.statusCode}');
        }

        CircuitBreakerPois.enregistrerEchec();
        final retryAfter =
            int.tryParse(reponse.headers['retry-after'] ?? '');
        final delai = retryAfter != null && retryAfter > 0
            ? Duration(seconds: retryAfter)
            : _jitterPois(baseBackoff * (1 << tentative));
        Journal.a('CARTE', 'Surcharge Overpass POI, nouvelle tentative dans ${delai.inSeconds} s', {
          'code_http': reponse.statusCode,
          'tentative': tentative + 1,
          'miroir': endpoint,
        });
        await Future<void>.delayed(delai);
      } on TimeoutException {
        CircuitBreakerPois.enregistrerEchec();
        if (tentative >= maxTentatives - 1) rethrow;
        final delai = _jitterPois(baseBackoff * (1 << tentative));
        Journal.a('CARTE', 'Délai dépassé Overpass POI, nouvelle tentative dans ${delai.inSeconds} s', {
          'tentative': tentative + 1,
          'miroir': endpoint,
        });
        await Future<void>.delayed(delai);
      } on http.ClientException {
        CircuitBreakerPois.enregistrerEchec();
        if (tentative >= maxTentatives - 1) rethrow;
        final delai = _jitterPois(baseBackoff * (1 << tentative));
        await Future<void>.delayed(delai);
      }
    }

    throw Exception('Overpass POI: échec après $maxTentatives tentatives');
  }
}