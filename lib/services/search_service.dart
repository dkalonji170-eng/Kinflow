import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../models/search_result.dart';
import '../models/place_info.dart';
import 'data_usage_service.dart';
import 'diagnostics_service.dart';

class _TypePoi {
  final List<String> patterns;
  final String libelle;
  final List<String> lignes;
  const _TypePoi({
    required this.patterns,
    required this.libelle,
    required this.lignes,
  });
}

const List<_TypePoi> _typesPoi = [
  _TypePoi(
    patterns: ['station-service', 'station service', 'essence', 'carburant', 'pétrole', 'petrole'],
    libelle: 'Station-service',
    lignes: [
      'nwr["amenity"="fuel"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['hôpital', 'hopital', 'hospital', 'hpital', 'clinique', 'clin'],
    libelle: 'Hôpital',
    lignes: [
      'nwr["amenity"~"hospital|clinic"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['université', 'universite', 'univ'],
    libelle: 'Université',
    lignes: [
      'nwr["amenity"~"university|college"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['école', 'ecole', 'scolaire', 'lycée', 'lycee', 'collège', 'college', 'primaire', 'secondaire'],
    libelle: 'École',
    lignes: [
      'nwr["amenity"~"school|kindergarten"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['marché', 'marche', 'marchés', 'marches', 'supermarché', 'supermache', 'magasin', 'boutique'],
    libelle: 'Marché',
    lignes: [
      'nwr["amenity"="marketplace"](area.kin);',
      'nwr["shop"~"supermarket|general|convenience|mall"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['pharmacie', 'pharma', 'médicament', 'medicament'],
    libelle: 'Pharmacie',
    lignes: [
      'nwr["amenity"="pharmacy"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['banque', 'banques', 'cash', 'argent', 'gab'],
    libelle: 'Banque',
    lignes: [
      'nwr["amenity"~"bank|atm"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['police', 'commissariat', 'gendarm', 'secours'],
    libelle: 'Police',
    lignes: [
      'nwr["amenity"~"police|fire_station"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['restaurant', 'bouffe', 'manger', 'bar'],
    libelle: 'Restaurant',
    lignes: [
      'nwr["amenity"~"restaurant|fast_food|bar|pub|cafe"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['hôtel', 'hotel', 'hôtels', 'hotels', 'auberge', 'guest house'],
    libelle: 'Hôtel',
    lignes: [
      'nwr["tourism"~"hotel|guest_house|hostel"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['église', 'eglise', 'cathédrale', 'cathedrale', 'mosquée', 'mosquee', 'temple', 'culte', 'chapelle'],
    libelle: 'Lieu de culte',
    lignes: [
      'nwr["amenity"="place_of_worship"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['stade', 'stadium', 'terrain de sport', 'sport'],
    libelle: 'Stade',
    lignes: [
      'nwr["leisure"~"stadium|sports_centre|pitch"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['taxi', 'taxis', 'gare', 'arrêt', 'arret', 'bus', 'transport'],
    libelle: 'Transport',
    lignes: [
      'nwr["amenity"~"bus_station|taxi"](area.kin);',
      'nwr["public_transport"="station"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['parc', 'jardin', 'espace vert', 'aire de jeux'],
    libelle: 'Parc',
    lignes: [
      'nwr["leisure"~"park|garden|playground"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['bibliothèque', 'bibliotheque', 'musée', 'musee', 'cinéma', 'cinema', 'théâtre', 'theatre'],
    libelle: 'Culture',
    lignes: [
      'nwr["amenity"~"library|theatre|cinema"](area.kin);',
      'nwr["tourism"="museum"](area.kin);',
    ],
  ),
  _TypePoi(
    patterns: ['parking', 'stationnement'],
    libelle: 'Parking',
    lignes: [
      'nwr["amenity"="parking"](area.kin);',
    ],
  ),
];

class SearchService {
  final Map<String, PlaceInfo?> _cacheReverse = {};

  /// Géocodage inverse : Nominatim interdit plus d'une requête par seconde.
  /// Sans régulation, le flux GPS (un fix par mètre) déclenche des dizaines
  /// de requêtes simultanées qui se font bloquer (429 / « Failed to fetch »)
  /// ou expirer en timeout. On impose donc :
  ///   • un délai minimum de [_delaiMinGeocodage] entre deux requêtes réelles
  ///     (les demandes trop rapprochées utilisent le cache, sinon attendent) ;
  ///   • le partage d'une même requête EN VOL entre appels concurrents :
  ///     deux fixes GPS rapprochés ne déclenchent qu'un seul appel réseau.
  static const Duration _delaiMinGeocodage = Duration(seconds: 1);

  /// Requête en cours (lat,lon clé) -> le Future partagé par tous les
  /// appelants concurrents ; permet de ne jamais doubler un appel réseau
  /// pour le MÊME point.
  final Map<String, Future<PlaceInfo?>> _geoEnVol = {};

  /// Bout de chaîne de la file des appels réseau réels. Chaque nouvelle
  /// requête s'accroche à la précédente : les appels Nominatim sont STRICTEMENT
  /// séquentiels (jamais deux en même temps), ce qui respecte la limite de
  /// débit même quand une rafale de points GPS différents arrive d'un coup.
  Future<void> _fileGeocodage = Future.value();

  /// Prépare l'appel réseau réel sans le démarrer : il attend son tour dans
  /// [_fileGeocodage], puis son créneau de [_delaiMinGeocodage]. Garantit au
  /// plus un appel Nominatim par fenêtre de temps, quel que soit le volume
  /// de demandes concurrentes.
  Future<T> _serialiser<T>(Future<T> Function() tache) async {
    final precedent = _fileGeocodage;
    final completer = Completer<T>();
    _fileGeocodage = completer.future.then<void>((_) {}).catchError((_) {});
    await precedent.catchError((_) {});
    try {
      final valeur = await tache();
      completer.complete(valeur);
      return valeur;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    }
  }

  /// Cache des recherches déjà faites (terme normalisé -> résultats) :
  /// une recherche répétée est instantanée.
  final Map<String, List<SearchResult>> _cacheRecherches = {};

  /// Boîte englobant toute la ville-province de Kinshasa (communes ouest
  /// jusqu'aux zones rurales de Maluku et N'sele à l'est), au format
  /// Nominatim viewbox « lon1,lat1,lon2,lat2 ». Aucune recherche ne peut
  /// sortir de cette zone.
  static const String _zoneKinshasa = '15.00,-3.90,16.45,-5.20';

  /// Même boîte au format bbox Overpass « lat1,lon1,lat2,lon2 » : une
  /// contrainte bbox est résolue bien plus vite qu'un area administratif.
  static const String _bboxOverpass = '(-4.60,15.05,-4.10,15.60)';

  static const int _limiteResultats = 30;
  static const int _tailleMaxCacheRecherches = 40;
  static const String _userAgent = 'KinFlow-App/1.0';

  /// Recherche un lieu en fusionnant TROIS services EN LIGNE : Photon
  /// (~100-300 ms, fournit les premières suggestions pendant la frappe),
  /// Nominatim borné à la boîte ci-dessus et Overpass sur la vraie
  /// frontière de Kinshasa. Aucun repli mondial : un lieu hors de
  /// Kinshasa n'est jamais proposé.
  ///
  /// Les résultats arrivent EN PROGRESSIF : dès qu'une source répond, la
  /// liste partielle est émise. Le flux se ferme quand les trois ont
  /// répondu.
  Stream<List<SearchResult>> rechercherLieu(String recherche) {
    final terme = recherche.trim();
    late final StreamController<List<SearchResult>> controller;
    controller = StreamController<List<SearchResult>>(onListen: () {
      if (terme.isEmpty) {
        controller.close();
        return;
      }

      final cle = _normaliser(terme);
      final enCache = _cacheRecherches[cle];
      if (enCache != null) {
        Journal.i('RECHERCHE', 'Résultats servis depuis le cache', {
          'terme': terme,
          'resultats': enCache.length,
        });
        controller.add(enCache);
        controller.close();
        return;
      }

      Journal.i('RECHERCHE', 'Recherche lancée sur 3 sources en ligne', {
        'terme': terme,
        'sources': 'Photon + Nominatim + Overpass',
      });

      final accumules = <SearchResult>[];
      final vus = <String>{};

      void fusionner(List<SearchResult> ajouts) {
        for (final r in ajouts) {
          if (r.nom.trim().isEmpty) continue;
          final clePoint =
              '${r.latitude.toStringAsFixed(4)},${r.longitude.toStringAsFixed(4)}';
          if (!vus.add(clePoint)) continue;
          accumules.add(r);
        }
      }

      var sourcesEnAttente = 3;
      void sourceTerminee(String source, List<SearchResult> ajouts) {
        if (controller.isClosed) return;
        Journal.i('RECHERCHE', 'Source $source terminée', {
          'resultats': ajouts.length,
        });
        fusionner(ajouts);
        sourcesEnAttente--;
        final liste = accumules.take(_limiteResultats).toList();
        controller.add(liste);
        if (sourcesEnAttente == 0) {
          _cacheRecherches[cle] = liste;
          while (_cacheRecherches.length > _tailleMaxCacheRecherches) {
            _cacheRecherches.remove(_cacheRecherches.keys.first);
          }
          if (liste.isEmpty) {
            Journal.a('RECHERCHE',
                'Aucun résultat : le lieu est peut-être hors de Kinshasa');
          } else {
            Journal.s('RECHERCHE', 'Recherche terminée', {
              'resultats_fusionnes': liste.length,
            });
          }
          controller.close();
        }
      }

      unawaited(_protegerSource(
          'Photon', () => _rechercherPhoton(terme)).then(
        (r) => sourceTerminee('Photon', r),
      ));
      unawaited(_protegerSource(
          'Nominatim', () => _rechercherNominatim(terme)).then(
        (r) => sourceTerminee('Nominatim', r),
      ));
      unawaited(_protegerSource(
          'Overpass', () => _rechercherOverpass(terme)).then(
        (r) => sourceTerminee('Overpass', r),
      ));
    });
    return controller.stream;
  }

  /// Isole chaque source de recherche : une exception est consignée dans le
  /// journal au lieu d'être avalée en silence, puis la source renvoie vide
  /// pour ne pas bloquer la fusion.
  Future<List<SearchResult>> _protegerSource(
    String nom,
    Future<List<SearchResult>> Function() tache,
  ) async {
    try {
      return await tache();
    } catch (e) {
      Journal.e('RECHERCHE', 'Source $nom en échec', {'erreur': '$e'});
      return const [];
    }
  }

  /// Photon (komoot) : géocodeur OSM très rapide, sans clé. C'est lui qui
  /// donne l'effet « clavier intelligent » : les premières suggestions
  /// arrivent pendant que le doigt tape encore. La bbox limite la réponse
  /// à Kinshasa et un filtre dur écarte tout débordement en bordure.
  Future<List<SearchResult>> _rechercherPhoton(String terme) async {
    final params = <String, String>{
      'q': terme,
      'bbox': '15.05,-4.60,15.60,-4.10',
      'limit': '$_limiteResultats',
      'lang': 'fr',
    };

    final url = Uri.parse(
      'https://photon.komoot.io/api/'
      '?${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}',
    );

    final resultats = <SearchResult>[];
    try {
      final response = await HttpMeter.get(
        CategorieData.recherche,
        url.toString(),
        headers: {'User-Agent': _userAgent},
        timeout: const Duration(seconds: 5),
      );

      if (response.statusCode != 200) {
        Journal.a('RECHERCHE', 'Photon a répondu avec un code anormal', {
          'code_http': response.statusCode,
        });
        return resultats;
      }
      final data = json.decode(response.body);
      if (data is! Map) return resultats;
      final features = data['features'] as List? ?? const [];

      for (final f in features) {
        if (f is! Map) continue;
        final geometry = f['geometry'] as Map?;
        final coords = geometry?['coordinates'] as List?;
        if (coords == null || coords.length < 2) continue;
        final lon = (coords[0] as num?)?.toDouble();
        final lat = (coords[1] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        // Filtre dur : rien hors de Kinshasa n'est accepté.
        if (!_dansZoneKinshasa(lat, lon)) continue;

        final props = (f['properties'] as Map?) ?? const {};
        final nom = (props['name'] ??
                props['street'] ??
                props['district'] ??
                props['city'] ??
                '')
            .toString()
            .trim();
        if (nom.isEmpty) continue;

        final morceaux = <String>[
          props['street']?.toString() ?? '',
          props['district']?.toString() ?? '',
          props['city']?.toString() ?? '',
          props['state']?.toString() ?? '',
        ].where((s) => s.isNotEmpty && s != nom).toSet().toList();

        resultats.add(
          SearchResult(
            nom: nom,
            sousTitre: morceaux.join(', '),
            latitude: lat,
            longitude: lon,
          ),
        );
      }
    } catch (e) {
      Journal.e('RECHERCHE', 'Photon injoignable (délai ou réseau)', {
        'erreur': '$e',
      });
      return const [];
    }
    return resultats;
  }

  Future<List<SearchResult>> _rechercherNominatim(String terme) async {
    final params = <String, String>{
      'q': terme,
      'format': 'json',
      'limit': '$_limiteResultats',
      'accept-language': 'fr',
      'dedupe': '1',
      'countrycodes': 'cd',
      'viewbox': _zoneKinshasa,
      'bounded': '1',
    };

    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search'
      '?${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}',
    );

    final resultats = <SearchResult>[];
    try {
      final response = await HttpMeter.get(
        CategorieData.recherche,
        url.toString(),
        headers: {'User-Agent': _userAgent},
        timeout: const Duration(seconds: 8),
      );

      if (response.statusCode != 200) {
        Journal.a('RECHERCHE', 'Nominatim a répondu avec un code anormal', {
          'code_http': response.statusCode,
        });
        return resultats;
      }
      final donnees = json.decode(response.body);
      if (donnees is! List) return resultats;

      for (final lieu in donnees) {
        if (lieu is! Map) continue;
        final lat = double.tryParse(lieu['lat']?.toString() ?? '');
        final lon = double.tryParse(lieu['lon']?.toString() ?? '');
        if (lat == null || lon == null) continue;
        // Filtre dur : même borné, Nominatim peut renvoyer une commune
        // voisine en bordure — rien hors de Kinshasa n'est accepté.
        if (!_dansZoneKinshasa(lat, lon)) continue;

        final displayName = lieu['display_name']?.toString() ?? '';
        final parties = displayName.split(',').map((p) => p.trim()).toList();
        final nom = parties.isNotEmpty ? parties.first : '';
        final sousTitre = parties.length > 1
            ? parties.sublist(1).join(', ').trim()
            : '';

        resultats.add(
          SearchResult(
            nom: nom.isNotEmpty ? nom : displayName,
            sousTitre: sousTitre,
            latitude: lat,
            longitude: lon,
          ),
        );
      }
    } catch (e) {
      Journal.e('RECHERCHE', 'Nominatim injoignable (délai ou réseau)', {
        'erreur': '$e',
      });
      return const [];
    }
    return resultats;
  }

  Future<List<SearchResult>> _rechercherOverpass(String terme) async {
    final type = _typePour(terme);
    final query = type != null
        ? _requeteTypes(type.lignes)
        : _requeteNom(_regexInsensibleAccents(terme));

    try {
      final response = await HttpMeter.post(
        CategorieData.recherche,
        'https://overpass-api.de/api/interpreter',
        headers: {'User-Agent': _userAgent},
        body: {'data': query},
        encode: true,
        timeout: const Duration(seconds: 10),
      );

      if (response.statusCode != 200) {
        Journal.a('RECHERCHE', 'Overpass a répondu avec un code anormal', {
          'code_http': response.statusCode,
        });
        return const [];
      }
      final data = json.decode(response.body);
      if (data is! Map) return const [];
      final elements = data['elements'] as List? ?? const [];

      final resultats = <SearchResult>[];
      final vus = <String>{};
      for (final e in elements) {
        if (e is! Map) continue;
        final tags = (e['tags'] as Map?) ?? const {};

        double? lat = (e['lat'] as num?)?.toDouble();
        double? lon = (e['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) {
          final centre = (e['center'] as Map?) ?? const {};
          lat = (centre['lat'] as num?)?.toDouble();
          lon = (centre['lon'] as num?)?.toDouble();
        }
        if (lat == null || lon == null) continue;
        if (!_dansZoneKinshasa(lat, lon)) continue;

        final nom = (tags['name'] ?? '').toString().trim();
        final typeReel = _traduireType(
          tags['amenity'] ??
              tags['shop'] ??
              tags['tourism'] ??
              tags['leisure'] ??
              '',
        );

        final cle = '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';
        if (!vus.add(cle)) continue;

        resultats.add(
          SearchResult(
            nom: nom.isNotEmpty ? nom : (type?.libelle ?? 'Lieu'),
            sousTitre: type?.libelle ?? (typeReel.isNotEmpty ? typeReel : 'Lieu à Kinshasa'),
            latitude: lat,
            longitude: lon,
          ),
        );
      }
      return resultats;
    } catch (e) {
      Journal.e('RECHERCHE', 'Overpass injoignable (délai ou réseau)', {
        'erreur': '$e',
      });
      return const [];
    }
  }

  /// Suggestions de catégories dont un mot-clé commence par la saisie.
  /// Utilisé pour l'autocomplétion locale (sans réseau) pendant la frappe.
  List<String> suggestionsCategories(String saisie) {
    final base = _normaliser(saisie).trim();
    if (base.isEmpty) return const [];

    final suggestions = <String>{};
    for (final type in _typesPoi) {
      final libelleNorm = _normaliser(type.libelle);
      if (suggestions.contains(type.libelle)) continue;
      for (final pattern in type.patterns) {
        final p = _normaliser(pattern);
        if (p.startsWith(base) ||
            libelleNorm.startsWith(base) ||
            base.startsWith(p)) {
          suggestions.add(type.libelle);
          break;
        }
      }
    }
    return suggestions.toList();
  }

  String _normaliser(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[àâä]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[îï]'), 'i')
      .replaceAll(RegExp('[ôö]'), 'o')
      .replaceAll(RegExp('[ùûü]'), 'u')
      .replaceAll(RegExp('[ç]'), 'c')
      .replaceAll(RegExp('[ñ]'), 'n');

  bool _dansZoneKinshasa(double lat, double lon) =>
      lat >= -4.60 && lat <= -4.10 && lon >= 15.05 && lon <= 15.60;

  _TypePoi? _typePour(String terme) {
    final bas = terme.toLowerCase();
    for (final type in _typesPoi) {
      for (final pattern in type.patterns) {
        if (bas.contains(pattern)) return type;
      }
    }
    return null;
  }

  /// Transforme le terme en regex insensible aux accents, pour retrouver
  /// « hopital » quand OSM contient « Hôpital » et inversement.
  String _regexInsensibleAccents(String terme) {
    final b = StringBuffer();
    for (final ch in terme.toLowerCase().split('')) {
      switch (ch) {
        case 'a':
          b.write('[aàâä]');
        case 'e':
          b.write('[eéèêë]');
        case 'i':
          b.write('[iîï]');
        case 'o':
          b.write('[oôö]');
        case 'u':
          b.write('[uùûü]');
        case 'c':
          b.write('[cç]');
        case 'y':
          b.write('[yÿ]');
        case 'n':
          b.write('[nñ]');
        default:
          b.write(RegExp.escape(ch));
      }
    }
    return b.toString();
  }

  String _requeteTypes(List<String> lignes) => '''
[out:json][timeout:10];
(
  ${lignes.map((l) => l.replaceAll('(area.kin)', _bboxOverpass)).join('\n  ')}
);
out center tags 50;
''';

  String _requeteNom(String regex) => '''
[out:json][timeout:10];
(
  nwr["name"~"$regex",i]$_bboxOverpass;
);
out center tags 40;
''';

  String _traduireType(Object? type) {
    const traductions = {
      'school': 'École',
      'kindergarten': 'École maternelle',
      'college': 'Collège',
      'university': 'Université',
      'hospital': 'Hôpital',
      'clinic': 'Clinique',
      'pharmacy': 'Pharmacie',
      'bank': 'Banque',
      'atm': 'Distributeur',
      'marketplace': 'Marché',
      'supermarket': 'Supermarché',
      'restaurant': 'Restaurant',
      'fast_food': 'Fast-food',
      'cafe': 'Café',
      'bar': 'Bar',
      'pub': 'Pub',
      'hotel': 'Hôtel',
      'guest_house': 'Maison d\'hôtes',
      'hostel': 'Auberge',
      'place_of_worship': 'Lieu de culte',
      'church': 'Église',
      'mosque': 'Mosquée',
      'fuel': 'Station-service',
      'taxi': 'Taxi',
      'bus_station': 'Gare routière',
      'police': 'Police',
      'fire_station': 'Caserne de pompiers',
      'stadium': 'Stade',
      'sports_centre': 'Centre sportif',
      'park': 'Parc',
      'garden': 'Jardin',
      'playground': 'Aire de jeux',
      'library': 'Bibliothèque',
      'museum': 'Musée',
      'cinema': 'Cinéma',
      'theatre': 'Théâtre',
      'parking': 'Parking',
      'general': 'Magasin',
      'convenience': 'Magasin',
      'mall': 'Centre commercial',
    };
    return traductions[type?.toString()] ?? '';
  }

  Future<PlaceInfo?> obtenirInfosLieu(
    double lat,
    double lon, {
    http.Client? client,
  }) async {
    final cle = "${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}";

    // 1) Réponse immédiate si déjà en cache.
    if (_cacheReverse.containsKey(cle)) {
      return _cacheReverse[cle];
    }

    // 2) Coalescence : si une requête est déjà en vol pour ce point, on la
    //    partage au lieu d'en déclencher une deuxième. Deux fixes GPS
    //    rapprochés ne provoquent donc qu'un seul appel réseau.
    final enVol = _geoEnVol[cle];
    if (enVol != null) {
      return enVol;
    }

    Journal.i('RECHERCHE', 'Géocodage inverse demandé (adresse du lieu)', {
      'lat': lat,
      'lon': lon,
    });

    final future = _effectuerGeocodage(cle, lat, lon, client);
    _geoEnVol[cle] = future;
    try {
      return await future;
    } finally {
      _geoEnVol.remove(cle);
    }
  }

  Future<PlaceInfo?> _effectuerGeocodage(
    String cle,
    double lat,
    double lon,
    http.Client? client,
  ) {
    // L'appel réseau réel est sérialisé dans la file : les requêtes
    // Nominatim sont strictement séquentielles et espacées d'au moins
    // [_delaiMinGeocodage], même lors d'une rafale de points GPS distincts.
    return _serialiser(() => _envoyerGeocodage(cle, lat, lon, client));
  }

  Future<PlaceInfo?> _envoyerGeocodage(
    String cle,
    double lat,
    double lon,
    http.Client? client,
  ) async {
    // Délai de respiration avant l'envoi : comme la file est strictement
    // séquentielle, cet appel part après le précédent ; on attend donc
    // toujours [_delaiMinGeocodage] pour respecter la limite de Nominatim.
    await Future<void>.delayed(_delaiMinGeocodage);

    // La position a pu être résolue pendant l'attente : inutile de gaspiller
    // un appel réseau pour un point déjà connu.
    if (_cacheReverse.containsKey(cle)) {
      return _cacheReverse[cle];
    }

    PlaceInfo? info;
    try {
      final url = Uri.parse(
        "https://nominatim.openstreetmap.org/reverse"
        "?lat=$lat&lon=$lon"
        "&format=json"
        "&zoom=18"
        "&accept-language=fr",
      );

      final requete = http.Request('GET', url)
        ..headers["User-Agent"] = _userAgent;
      final clientLocal = client;
      final finalClient = clientLocal ?? http.Client();
      try {
        final response = await finalClient
            .send(requete)
            .timeout(const Duration(seconds: 10))
            .then(http.Response.fromStream);

        DataUsageService.instance.enregistrer(
          CategorieData.recherche,
          octetsRecus: response.bodyBytes.length,
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['error'] == null) {
            final adresseJSON = (data['address'] as Map<String, dynamic>?) ?? {};
            info = PlaceInfo(
              nom: data['name'] ?? data['display_name']?.toString().split(',').first ?? '',
              type: data['type'] ?? '',
              categorie: data['category'] ?? '',
              adresse: data['display_name'] ?? '',
              quartier: (adresseJSON['suburb'] ??
                      adresseJSON['quarter'] ??
                      adresseJSON['neighbourhood'] ??
                      adresseJSON['city_district'] ??
                      adresseJSON['village'] ??
                      adresseJSON['town'] ??
                      '')
                  .toString(),
              rue: (adresseJSON['road'] ??
                      adresseJSON['pedestrian'] ??
                      adresseJSON['footway'] ??
                      adresseJSON['path'] ??
                      adresseJSON['service'] ??
                      adresseJSON['name'] ??
                      '')
                  .toString(),
              latitude: double.parse(data['lat'].toString()),
              longitude: double.parse(data['lon'].toString()),
            );
          }
        } else {
          Journal.a('RECHERCHE', 'Géocodage inverse : code anormal', {
            'code_http': response.statusCode,
          });
        }
      } finally {
        // On ne ferme QUE le client créé localement : un client injecté par
        // l'appelant reste sous sa responsabilité.
        if (clientLocal == null) finalClient.close();
      }
    } catch (e) {
      Journal.e('RECHERCHE', 'Géocodage inverse impossible', {'erreur': '$e'});
      info = null;
    }

    _cacheReverse[cle] = info;
    if (_cacheReverse.length > 300) {
      _cacheReverse.remove(_cacheReverse.keys.first);
    }
    return info;
  }

  final Map<String, ({String rue, String avenue})> _cacheVoies = {};

  /// Renvoie la rue et l'avenue les plus proches du point bleu (position
  /// utilisateur), chacune dans son propre champ, ou des chaînes vides si
  /// aucune voie de ce type n'existe autour. Une voie est classée « avenue »
  /// si son nom commence par « Av », sinon « rue ».
  Future<({String rue, String avenue})> voiesRueAvenueProches(
    double lat,
    double lon,
  ) async {
    final cle = "${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}";
    final enCache = _cacheVoies[cle];
    if (enCache != null) return enCache;
    try {
      final resultat = await _telechargerVoiesProches(lat, lon);
      _cacheVoies[cle] = resultat;
      if (_cacheVoies.length > 300) {
        _cacheVoies.remove(_cacheVoies.keys.first);
      }
      return resultat;
    } catch (_) {
      return const (rue: '', avenue: '');
    }
  }

  static const int _rayonVoiesProches = 300;

  Future<({String rue, String avenue})> _telechargerVoiesProches(
    double lat,
    double lon,
  ) async {
    final query = '''
[out:json][timeout:20];
way["highway"]["name"](around:$_rayonVoiesProches,$lat,$lon);
out tags geom;
''';
    try {
      final response = await HttpMeter.post(
        CategorieData.recherche,
        'https://overpass-api.de/api/interpreter',
        headers: {'User-Agent': _userAgent},
        body: {'data': query},
        encode: true,
        timeout: const Duration(seconds: 15),
      );

      if (response.statusCode != 200) {
        return const (rue: '', avenue: '');
      }
      final data = json.decode(response.body);
      if (data is! Map) return const (rue: '', avenue: '');
      final elements = data['elements'] as List? ?? const [];
      return _voiesLesPlusProches(elements, lat, lon);
    } catch (e) {
      Journal.e('RECHERCHE', 'Voies proches indisponibles (Overpass)', {
        'erreur': '$e',
      });
      return const (rue: '', avenue: '');
    }
  }

  ({String rue, String avenue}) _voiesLesPlusProches(
    List<dynamic> elements,
    double lat,
    double lon,
  ) {
    var rue = '';
    var avenue = '';
    var distRue = double.infinity;
    var distAvenue = double.infinity;

    for (final e in elements) {
      if (e is! Map) continue;
      final tags = (e['tags'] as Map?) ?? const {};
      final nom = (tags['name'] ?? '').toString().trim();
      if (nom.isEmpty) continue;
      final geometry = (e['geometry'] as List?) ?? const [];
      if (geometry.length < 2) continue;

      final distance = _distanceAuTrace(geometry, lat, lon);
      final estAvenue = nom.toLowerCase().startsWith('av');
      if (estAvenue) {
        if (distance < distAvenue) {
          distAvenue = distance;
          avenue = nom;
        }
      } else if (distance < distRue) {
        distRue = distance;
        rue = nom;
      }
    }
    return (rue: rue, avenue: avenue);
  }

  /// Distance minimale entre le point (lat, lon) et la géométrie de la voie,
  /// par projection orthogonale sur chaque segment (mètres approximatifs).
  double _distanceAuTrace(List<dynamic> geometry, double lat, double lon) {
    var minD = double.infinity;
    final cosLat = math.cos(lat * math.pi / 180);
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i] as Map;
      final b = geometry[i + 1] as Map;
      final ax =
          ((b['lon'] as num).toDouble() - (a['lon'] as num).toDouble()) *
              cosLat;
      final ay = (b['lat'] as num).toDouble() - (a['lat'] as num).toDouble();
      final bx =
          (lon - (a['lon'] as num).toDouble()) * cosLat;
      final by = lat - (a['lat'] as num).toDouble();
      final len2 = ax * ax + ay * ay;
      if (len2 <= 0) continue;
      final t = ((bx * ax + by * ay) / len2).clamp(0.0, 1.0);
      final projLat = (a['lat'] as num).toDouble() + t * ay;
      final projLon = (a['lon'] as num).toDouble() + t * ax / cosLat;
      final dLat = (lat - projLat) * 111320;
      final dLon = (lon - projLon) * 111320 * cosLat;
      final d = math.sqrt(dLat * dLat + dLon * dLon);
      if (d < minD) minD = d;
    }
    return minD;
  }

}
