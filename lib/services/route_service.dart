import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_result.dart';
import 'data_usage_service.dart';
import 'diagnostics_service.dart';

class RouteService {
  /// Serveurs OSRM. Le serveur public principal applique vite des quotas
  /// (429) : le miroir openstreetmap.de prend le relais en parallèle. Un
  /// round de secours relance toutes les requêtes si aucun serveur n'a
  /// répondu, au cas où le 429 est tombé pendant qu'un créneau se libère.
  static const List<String> _endpoints = [
    'https://router.project-osrm.org',
    'https://routing.openstreetmap.de/routed-car',
  ];

  /// Le serveur OSRM public peut être lent depuis certaines régions : on lui
  /// laisse davantage de temps qu'aux petites requêtes de la carte. Le timeout
  /// est volontairement large pour absorber les connexions instables et les
  /// petits débits (la réponse d'itinéraire reste une petite charge JSON).
  static const _timeoutRequete = Duration(seconds: 30);

  /// Nombre de rounds de tentative : en cas d'échec total, on respire puis on
  /// relance, pour traverser un pic de quotas (429) passager comme une
  /// période de connexion instable. Les requêtes étant en parallèle, les
  /// rounds supplémentaires ne ralentissent jamais le cas réseau sain.
  static const _maxRounds = 3;
  static const _attenteEntreRounds = Duration(seconds: 3);

  static const String _userAgent = 'KinFlow-App/1.0';

  static const _cacheMaxMemoire = 20;

  /// Le cache OSRM est aussi persisté localement : un itinéraire déjà demandé
  /// revient instantanément, sans aucun appel réseau, même après un
  /// redémarrage de l'app.
  static const _prefPrefixe = 'kinflow_osrm_cache_v1_';
  static const _prefMax = 50;

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
      Journal.i('OSRM', 'Itinéraire servi depuis le cache mémoire');
      return enCache;
    }

    final persiste = await _trouverPersistant(cle);
    if (persiste != null) {
      _cache[cle] = persiste;
      Journal.i('OSRM', 'Itinéraire servi depuis le cache local');
      return persiste;
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
    // réponse valide, sans attendre les autres endpoints. Si aucun serveur
    // n'a répondu (quota épuisé, panne), on respire et on relance une fois.
    var resultat = await _premierSucces([
      for (final base in _endpoints) _essayer(base, coord),
    ]);
    for (var round = 1; resultat == null && round < _maxRounds; round++) {
      Journal.a('OSRM',
          'Aucun serveur disponible, nouveau round dans ${_attenteEntreRounds.inSeconds} s', {
        'round': round + 1,
      });
      await Future<void>.delayed(_attenteEntreRounds * round);
      resultat = await _premierSucces([
        for (final base in _endpoints) _essayer(base, coord),
      ]);
    }

    if (resultat != null) {
      while (_cache.length > _cacheMaxMemoire) {
        _cache.remove(_cache.keys.first);
      }
      _cache[cle] = resultat;
      unawaited(_ecrirePersistant(cle, resultat));
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
        timeout: _timeoutRequete,
      );

      if (response.statusCode != 200) {
        Journal.a('OSRM', 'Un serveur a refusé la requête', {
          'serveur': Uri.parse(base).host,
          'code_http': response.statusCode,
          'corps': _extrait(response.body),
        });
        return null;
      }

      dynamic data;
      try {
        data = json.decode(response.body);
      } on FormatException {
        // Corps non-JSON (page d'erreur, captive portal…) : le journaliser
        // explicitement, sinon l'échec reste totalement muet (c'était le cas
        // de tous les échecs OSRM du rapport de 08h17).
        Journal.a('OSRM', 'Réponse illisible (pas de JSON)', {
          'serveur': Uri.parse(base).host,
          'corps': _extrait(response.body),
        });
        return null;
      }
      if (data is! Map || data['code'] != 'Ok') {
        Journal.a('OSRM', 'Un serveur n\'a pas pu calculer', {
          'serveur': Uri.parse(base).host,
          'code': data is Map ? '${data['code']}' : 'réponse illisible',
          'corps': _extrait(response.body),
        });
        return null;
      }

      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        // Réponse « 200 Ok » mais sans route : l'échec OSRM le plus traître
        // (ni refus, ni erreur réseau, ni code != Ok), qui aurait pu passer
        // inaperçu si on ne l'avait pas rendu visible.
        Journal.a('OSRM', 'Réponse Ok sans itinéraire', {
          'serveur': Uri.parse(base).host,
          'corps': _extrait(response.body),
        });
        return null;
      }

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

  /// Échantillon compact d'un corps de réponse (espaces aplatris, tronqué à
  /// 200 caractères) : de quoi diagnostiquer un refus OSRM sans noyer le
  /// journal dans un gros payload.
  String _extrait(String corps, [int max = 200]) {
    final compact = corps.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length <= max ? compact : '${compact.substring(0, max)}…';
  }

  String _cleCache(List<LatLng> points) {
    String arr(double v) => v.toStringAsFixed(3);
    return points.map((p) => '${arr(p.latitude)},${arr(p.longitude)}').join('|');
  }

  Future<RouteResult?> _trouverPersistant(String cle) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final brut = prefs.getString(_prefPrefixe + cle);
      if (brut == null) return null;
      final resultat = _resultatDepuisJson(json.decode(brut));
      if (resultat == null) return null;
      return resultat;
    } catch (e) {
      debugPrint('[KinFlow] Lecture cache OSRM échouée: $e');
      return null;
    }
  }

  Future<void> _ecrirePersistant(String cle, RouteResult r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefPrefixe + cle,
        json.encode(_resultatVersJson(r)),
      );
      await _prunePersistant(prefs);
    } catch (e) {
      debugPrint('[KinFlow] Écriture cache OSRM échouée: $e');
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

  Map<String, dynamic> _resultatVersJson(RouteResult r) => {
        'points': [
          for (final p in r.points) {'lat': p.latitude, 'lon': p.longitude},
        ],
        'distanceMeters': r.distanceMeters,
        'durationSeconds': r.durationSeconds,
        'indexDebutRoute': r.indexDebutRoute,
        'indexFinRoute': r.indexFinRoute,
      };

  RouteResult? _resultatDepuisJson(dynamic brut) {
    final j = brut as Map<String, dynamic>;
    final pointsJson = (j['points'] as List? ?? const []);
    if (pointsJson.length < 2) return null;
    return RouteResult(
      points: [
        for (final p in pointsJson)
          LatLng(
            ((p as Map)['lat'] as num).toDouble(),
            (p['lon'] as num).toDouble(),
          ),
      ],
      distanceMeters: (j['distanceMeters'] as num?)?.toDouble() ?? 0,
      durationSeconds: (j['durationSeconds'] as num?)?.toDouble() ?? 0,
      indexDebutRoute: (j['indexDebutRoute'] as num?)?.toInt() ?? 0,
      indexFinRoute: (j['indexFinRoute'] as num?)?.toInt() ?? -1,
    );
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
