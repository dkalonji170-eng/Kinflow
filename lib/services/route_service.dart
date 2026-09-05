import 'dart:async';
import 'dart:convert';
import 'package:latlong2/latlong.dart';

import '../models/route_result.dart';
import 'data_usage_service.dart';
import 'diagnostics_service.dart';

class RouteService {
  static const List<String> _endpoints = [
    'https://router.project-osrm.org',
    'https://routing.openstreetmap.de/routed-car',
    'https://routing.fossgis.de/routed-car',
  ];

  static const String _userAgent = 'KinFlow-App/1.0';

  final Map<String, RouteResult> _cache = {};

  Future<RouteResult?> calculer(
    LatLng depart,
    LatLng arrivee, {
    List<LatLng> etapes = const [],
  }) async {
    final points = [depart, ...etapes, arrivee];
    final cle = _cleCache(points);
    final enCache = _cache[cle];
    if (enCache != null) {
      Journal.i('OSRM', 'Itinéraire servi depuis le cache');
      return enCache;
    }

    Journal.i('OSRM', 'Requête envoyée aux serveurs OSRM', {
      'serveurs': _endpoints.length,
    });

    // OSRM enchaîne nativement les points intermédiaires : le tracé passe
    // obligatoirement par chacune des étapes.
    final coord = points
        .map((p) => '${p.longitude},${p.latitude}')
        .join(';');

    // Toutes les requêtes partent en parallèle : on garde la première
    // réponse valide, sans attendre les autres endpoints.
    final resultat = await _premierSucces([
      for (final base in _endpoints) _essayer(base, coord),
    ]);

    if (resultat != null) {
      while (_cache.length > 20) {
        _cache.remove(_cache.keys.first);
      }
      _cache[cle] = resultat;
    } else {
      Journal.a('OSRM', 'Aucun des serveurs OSRM n\'a donné d\'itinéraire');
    }
    return resultat;
  }

  Future<RouteResult?> _essayer(String base, String coord) async {
    try {
      final url = Uri.parse(
        '$base/route/v1/driving/$coord'
        '?overview=full&geometries=polyline&steps=false&alternatives=false',
      );
      final response = await HttpMeter.get(
        CategorieData.itineraire,
        url.toString(),
        headers: {'User-Agent': _userAgent},
        timeout: const Duration(seconds: 8),
      );

      if (response.statusCode != 200) {
        Journal.a('OSRM', 'Un serveur a refusé la requête', {
          'serveur': Uri.parse(base).host,
          'code_http': response.statusCode,
        });
        return null;
      }

      final data = json.decode(response.body);
      if (data is! Map || data['code'] != 'Ok') {
        Journal.a('OSRM', 'Un serveur n\'a pas pu calculer', {
          'serveur': Uri.parse(base).host,
          'code': data is Map ? '${data['code']}' : 'réponse illisible',
        });
        return null;
      }

      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;

      final route = routes.first as Map;
      final geometry = route['geometry']?.toString() ?? '';
      final points = _decoderPolyline(geometry);
      if (points.length < 2) return null;

      return RouteResult(
        points: points,
        distanceMeters: (route['distance'] as num?)?.toDouble() ?? 0,
        durationSeconds: (route['duration'] as num?)?.toDouble() ?? 0,
      );
    } catch (e) {
      Journal.e('OSRM', 'Serveur injoignable', {
        'serveur': Uri.tryParse(base)?.host ?? base,
        'erreur': '$e',
      });
      return null;
    }
  }

  /// Attend la première réponse non vide, ou null si tous les endpoints
  /// échouent.
  Future<RouteResult?> _premierSucces(List<Future<RouteResult?>> requetes) {
    final completer = Completer<RouteResult?>();
    var restants = requetes.length;

    for (final requete in requetes) {
      requete.then((r) {
        if (r != null && !completer.isCompleted) {
          completer.complete(r);
        } else {
          restants--;
          if (restants <= 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }, onError: (_) {
        restants--;
        if (restants <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    return completer.future;
  }

  String _cleCache(List<LatLng> points) {
    String arr(double v) => v.toStringAsFixed(3);
    return points.map((p) => '${arr(p.latitude)},${arr(p.longitude)}').join('|');
  }

  List<LatLng> _decoderPolyline(String polyline) {
    var index = 0;
    var lat = 0;
    var lon = 0;
    final points = <LatLng>[];
    while (index < polyline.length) {
      final (latDelta, apres1) = _decoderValeur(polyline, index);
      index = apres1;
      final (lonDelta, apres2) = _decoderValeur(polyline, index);
      index = apres2;
      lat += latDelta;
      lon += lonDelta;
      final decodedLat = lat / 1e5;
      final decodedLon = lon / 1e5;
      if (decodedLat.abs() > 90 || decodedLon.abs() > 180) {
        return const [];
      }
      points.add(LatLng(decodedLat, decodedLon));
    }
    return points;
  }

  (int, int) _decoderValeur(String polyline, int debut) {
    var resultat = 0;
    var deplacement = 0;
    var index = debut;
    while (index < polyline.length) {
      final bits = polyline.codeUnitAt(index) - 63;
      resultat |= (bits & 0x1f) << deplacement;
      deplacement += 5;
      index++;
      if (bits < 0x20) break;
    }
    if (deplacement > 32) {
      return (0, index);
    }
    final valeur =
        (resultat & 1) != 0 ? ~(resultat >> 1) : (resultat >> 1);
    return (valeur, index);
  }
}
