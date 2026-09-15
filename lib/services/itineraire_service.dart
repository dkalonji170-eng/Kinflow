import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show compute, debugPrint, kIsWeb;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/road_segment.dart';
import '../models/route_result.dart';
import 'diagnostics_service.dart';
import 'offline_routes.dart';
import 'road_service.dart';
import 'traffic_simulator.dart';
import 'traffic_stats_service.dart';

/// Cône de vision sérialisable pour le calcul dans un isolat.
class _ConeRoute {
  final double lat;
  final double lon;
  final double rayon;
  final double? cap;

  const _ConeRoute({
    required this.lat,
    required this.lon,
    required this.rayon,
    this.cap,
  });
}

/// Zone de trafic sérialisable pour le calcul dans un isolat.
class _ZoneRoute {
  final int etatIndex;
  final double fiabilite;
  final List<_ConeRoute> cones;

  const _ZoneRoute({
    required this.etatIndex,
    required this.fiabilite,
    required this.cones,
  });
}

/// Point de parcours sérialisable pour le calcul dans un isolat.
class _PointRoute {
  final double lat;
  final double lon;

  const _PointRoute(this.lat, this.lon);
}

class _ArgumentsItineraire {
  final List<RoadSegment> segments;

  /// Points du parcours dans l'ordre : départ, étapes intermédiaires
  /// éventuelles, arrivée. Le chemin final passe obligatoirement par
  /// chacun d'eux.
  final List<_PointRoute> points;
  final List<_ZoneRoute> zones;

  /// Port de sortie vers l'isolat principal : le moteur y envoie un message
  /// chaque fois qu'il doit chercher au-delà du premier palier de routes
  /// (première fournée de lignes jugée non valable). L'interface affiche
  /// alors « réflexion profonde » pendant le calcul. Null sans abonné.
  final SendPort? porteEvenements;

  /// Identifiants OSM des rues à NE PAS emprunter (itinéraire alternatif) :
  /// les rues déjà prises par l'itinéraire affiché sont retirées du réseau
  /// avant le calcul, le tracé suivant est donc forcément différent.
  final Set<int> segmentsInterdits;

  const _ArgumentsItineraire({
    required this.segments,
    required this.points,
    required this.zones,
    this.porteEvenements,
    this.segmentsInterdits = const {},
  });
}

class _Noeud {
  final LatLng point;
  _Noeud(this.point);
}

class _Arete {
  final int vers;
  final List<LatLng> points;
  final double longueurMetres;
  final double cout;
  final double severite;

  /// Index du tronçon (chaussée découpée aux carrefours) dont vient l'arête.
  /// -1 pour les arêtes virtuelles (raccord du départ/de l'arrivée) : elles
  /// n'appartiennent à aucune chaussée et échappent donc aux pénalités de
  /// changement de chaussée.
  final int idTroncon;

  const _Arete({
    required this.vers,
    required this.points,
    required this.longueurMetres,
    required this.cout,
    required this.severite,
    this.idTroncon = -1,
  });
}

class _Tas {
  final List<(double, int)> _items = [];

  bool get estVide => _items.isEmpty;

  void ajouter(double priorite, int noeud) {
    _items.add((priorite, noeud));
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_items[parent].$1 <= _items[i].$1) break;
      final tmp = _items[parent];
      _items[parent] = _items[i];
      _items[i] = tmp;
      i = parent;
    }
  }

  (double, int) retirer() {
    final racine = _items.first;
    final dernier = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = dernier;
      var i = 0;
      while (true) {
        final g = 2 * i + 1;
        final d = 2 * i + 2;
        var min = i;
        if (g < _items.length && _items[g].$1 < _items[min].$1) min = g;
        if (d < _items.length && _items[d].$1 < _items[min].$1) min = d;
        if (min == i) break;
        final tmp = _items[i];
        _items[i] = _items[min];
        _items[min] = tmp;
        i = min;
      }
    }
    return racine;
  }
}

/// Un chemin trouvé par Dijkstra dans le graphe : sa suite de nœuds (le
/// premier est le départ, le dernier l'arrivée) et les arêtes empruntées
/// dans l'ordre. [cout] est le coût de la phase 1 (distance + pénalités
/// géométriques, SANS facteur de trafic).
class _Chemin {
  final List<int> noeuds;
  final List<_Arete> aretes;
  final double cout;

  const _Chemin(this.noeuds, this.aretes, this.cout);
}

/// Candidat au classement final : les arêtes de chaque jambe du parcours
/// (départ → étape éventuelle → arrivée) et les tronçons de chaussée utilisés
/// (pour ne jamais réemprunter une rue déjà prise par une autre jambe).
class _Candidat {
  final List<List<_Arete>> jambes;
  final Set<int> troncons;

  const _Candidat(this.jambes, this.troncons);
}

/// Graphe des rues : chaque segment devient une arête entre ses deux bouts,
/// pondérée par la distance parcourue et l'état de circulation de la route.
class _GrapheRoutes {
  // 12 m : assez tolérant pour rattraper les imprécisions de cartographie
  // (extrémités de ways qui devraient se toucher), assez strict pour ne PAS
  // fusionner les nœuds des deux chaussées d'un boulevard séparé (souvent
  // 15 à 30 m d'écart) : fusionnées, le tracé zigzaguait gratuitement
  // entre les deux lignes de l'artère et la ligne se dédoublait.
  static const double _tailleCellule = 0.00025;
  static const double _toleranceMetres = 12;

  final Map<int, _Noeud> noeuds = {};
  final Map<int, List<_Arete>> adjacence = {};
  final Map<int, List<int>> _grille = {};

  /// Tronçons incident à chaque nœud : permet de savoir, à un carrefour,
  /// si la chaussée jumelle de celle qu'on quitte est également raccordée
  /// (signe d'un changement de chaussée via une rue transversale).
  final Map<int, Set<int>> tronconsParNoeud = {};

  int _cle(int r, int c) => r * 1000003 + c;

  /// Renvoie le nœud existant à moins de [_toleranceMetres], sinon en crée un.
  int noeudPour(LatLng p) {
    final r = (p.latitude / _tailleCellule).floor();
    final c = (p.longitude / _tailleCellule).floor();
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final ids = _grille[_cle(r + dr, c + dc)];
        if (ids == null) continue;
        for (final id in ids) {
          if (_distanceMetres(p, noeuds[id]!.point) <= _toleranceMetres) {
            return id;
          }
        }
      }
    }
    final id = noeuds.length;
    noeuds[id] = _Noeud(p);
    _grille.putIfAbsent(_cle(r, c), () => []).add(id);
    return id;
  }

  int nouveauNoeud(LatLng p) {
    final id = noeuds.length;
    noeuds[id] = _Noeud(p);
    return id;
  }

  /// Ajoute l'arête dans les deux sens (routes considérées bidirectionnelles)
  /// et l'indexe par tronçon aux deux nœuds qu'elle touche.
  void ajouterArete(
    int a,
    int b,
    List<LatLng> points,
    double longueur,
    double cout,
    double severite, {
    int idTroncon = -1,
  }) {
    adjacence.putIfAbsent(a, () => []).add(
          _Arete(
            vers: b,
            points: points,
            longueurMetres: longueur,
            cout: cout,
            severite: severite,
            idTroncon: idTroncon,
          ),
        );
    adjacence.putIfAbsent(b, () => []).add(
          _Arete(
            vers: a,
            points: points.reversed.toList(),
            longueurMetres: longueur,
            cout: cout,
            severite: severite,
            idTroncon: idTroncon,
          ),
        );
    if (idTroncon >= 0) {
      tronconsParNoeud.putIfAbsent(a, () => {}).add(idTroncon);
      tronconsParNoeud.putIfAbsent(b, () => {}).add(idTroncon);
    }
  }
}

/// Recherche le meilleur itinéraire : le coût de chaque rue est sa longueur
/// en mètres multipliée par un facteur qui dépend de l'état de circulation
/// (fluide ×1, embouteillage léger ×1,8, gros embouteillages ×3,2, route
/// bloquée ×6). Dijkstra minimise donc la distance ET évite le trafic.
/// Un léger surcoût par virage (0 à 80 m équivalents selon l'angle) évite
/// les zigzags tout en autorisant les raccourcis par les petites rues.
class ItineraireService {
  ItineraireService({RoadService? roads}) : _roads = roads ?? RoadService();

  final RoadService _roads;

  Future<RouteResult?> calculer(
    LatLng depart,
    LatLng arrivee, {
    List<ZoneTrafic> zones = const [],
    List<LatLng> etapes = const [],
    Set<int>? segmentsInterdits,
    void Function()? onRechercheElargie,
  }) async {
    // On ne charge que le couloir entre les points du parcours (avec marge),
    // pas toute la ville : l'itinéraire apparaît vite.
    final parcours = [depart, ...etapes, arrivee];
    final couloir = _boundsEntre(parcours);
    // Destination lointaine : le couloir couvre une grande partie de la
    // ville. Charger toutes les classes de rues (résidentielles comprises)
    // saturerait Overpass (429/timeout) et l'isolat ; on ne prend que les
    // grands axes, qui suffisent à relier deux points éloignés.
    final lointain = (couloir.north - couloir.south) > 0.08 ||
        (couloir.east - couloir.west) > 0.08;

    // L'itinéraire se calcule sur le VRAI réseau routier, servi par Overpass
    // (détail au point de départ, grands axes si la destination est loin).
    // Le graphe embarqué (vraies routes OSM de Kinshasa, ~670 Ko, décodé une
    // seule fois puis gardé en mémoire) est préparé EN MÊME TEMPS : sur une
    // connexion faible, où Overpass répond lentement ou jamais (timeouts,
    // 429, réseau public africain saturé), on affiche en quelques secondes un
    // itinéraire correct au lieu d'attendre la fin de la chaîne de tentatives
    // (parfois plusieurs minutes). Sur une connexion saine, Overpass gagne
    // normalement la course.
    final secours = _segmentsSecours(couloir);
    final reseau = _roads.obtenirRoutes(couloir, detailsComplets: !lointain);
    // Si on répond d'abord avec le secours, le futur réseau est abandonné :
    // on avale son éventuelle erreur, sinon elle serait « non traitée ».
    reseau.then((_) {}, onError: (_) {});

    List<RoadSegment> segments;
    try {
      segments = await reseau.timeout(_budgetSecours(lointain));
    } on TimeoutException {
      // Connexion faible : Overpass n'a pas répondu dans le budget. On sert
      // immédiatement l'itinéraire calculé sur le graphe embarqué.
      Journal.a('MOTEUR LOCAL', 'Connexion faible : itinéraire sur le graphe '
          'embarqué', {
        'budget_s': _budgetSecours(lointain).inSeconds,
      });
      segments = await _secoursOuReseau(secours, reseau);
    } on Exception catch (e) {
      // Réseau Overpass indisponible : on essaie d'abord le graphe embarqué.
      Journal.e('MOTEUR LOCAL', 'Chargement des routes impossible', {
        'erreur': '$e',
        'mode': lointain ? 'grands axes' : 'détail complet',
      });
      debugPrint('[KinFlow] Échec chargement routes itinéraire: $e');
      segments = await _secoursOuReseau(secours, reseau);
    }
    return _calculerLocal(
        segments, lointain, zones, etapes, depart, arrivee,
        segmentsInterdits: segmentsInterdits,
        onRechercheElargie: onRechercheElargie);
  }

  /// Budget de patience avant de servir le graphe embarqué : une connexion
  /// trop lente ne rattrape pas son retard à force de tentatives ; autant
  /// afficher vite un bon itinéraire local qu'attendre un réseau défaillant.
  static Duration _budgetSecours(bool lointain) =>
      Duration(seconds: lointain ? 10 : 6);

  /// Segments du graphe embarqué couvrant [couloir] : zéro connexion, zéro
  /// méga-octet téléchargé.
  Future<List<RoadSegment>> _segmentsSecours(LatLngBounds couloir) async =>
      await OfflineRoutes.segmentsPour(couloir) ?? const [];

  /// Repli : les segments locaux s'ils sont utilisables, sinon on laisse le
  /// réseau finir (mêmes délais qu'avant la course) ; `[]` signale l'échec
  /// total (l'appelant retombera sur OSRM ou affichera l'erreur).
  Future<List<RoadSegment>> _secoursOuReseau(
      Future<List<RoadSegment>> secours,
      Future<List<RoadSegment>> reseau) async {
    final locaux = await secours;
    if (locaux.isNotEmpty) return locaux;
    try {
      final s = await reseau;
      if (s.isNotEmpty) return s;
    } on Exception {
      // Échec réseau déjà journalisé par l'appelant.
    }
    return const [];
  }

  /// Lance le calcul Dijkstra en isolat sur [segments] déjà chargés.
  Future<RouteResult?> _calculerLocal(
    List<RoadSegment> segments,
    bool lointain,
    List<ZoneTrafic> zones,
    List<LatLng> etapes,
    LatLng depart,
    LatLng arrivee, {
    Set<int>? segmentsInterdits,
    void Function()? onRechercheElargie,
  }) async {
    if (segments.length < 2) {
      Journal.a('MOTEUR LOCAL', 'Réseau routier trop pauvre pour calculer', {
        'segments_recus': segments.length,
      });
      return null;
    }

    final parcours = [depart, ...etapes, arrivee];
    Journal.i('MOTEUR LOCAL', 'Calcul Dijkstra lancé en isolat', {
      'segments': segments.length,
      'zones_trafic': zones.length,
      'etapes': etapes.length,
      'mode': lointain ? 'grands axes' : 'détail complet',
    });
    // Port de retour de l'isolat : chaque élargissement de la recherche
    // (première fournée ne convenant pas) y est rapporté à l'interface.
    // En Web, dart:isolate n'existe pas : compute replie sur le fil
    // principal et l'événement d'élargissement n'est simplement pas émis.
    ReceivePort? porte;
    StreamSubscription<dynamic>? ecoute;
    if (!kIsWeb && onRechercheElargie != null) {
      porte = ReceivePort();
      ecoute = porte.listen((_) => onRechercheElargie());
    }
    try {
      final resultat = await compute(
        _calculerChemin,
        _ArgumentsItineraire(
          segments: segments,
          points: [
            for (final p in parcours) _PointRoute(p.latitude, p.longitude),
          ],
          zones: [
            for (final z in zones) _zoneRoutePour(z),
          ],
          porteEvenements: porte?.sendPort,
          segmentsInterdits: segmentsInterdits ?? const {},
        ),
      );
      if (resultat == null) {
        Journal.a('MOTEUR LOCAL',
            'Aucun chemin trouvé sur le réseau local (points hors route ?)');
      }
      return resultat;
    } catch (e) {
      Journal.e('MOTEUR LOCAL', 'Le calcul du chemin a planté', {
        'erreur': '$e',
      });
      debugPrint('[KinFlow] Échec calcul chemin local: $e');
      return null;
    } finally {
      ecoute?.cancel();
      porte?.close();
    }
  }

  /// Bounding box autour de tous les points du parcours, élargie pour garder
  /// le réseau de rues connecté jusqu'au chemin.
  static LatLngBounds _boundsEntre(List<LatLng> points) {
    const marge = 0.03;
    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    var minLon = double.infinity;
    var maxLon = double.negativeInfinity;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return LatLngBounds(
      LatLng(minLat - marge, minLon - marge),
      LatLng(maxLat + marge, maxLon + marge),
    );
  }

  static _ZoneRoute _zoneRoutePour(ZoneTrafic z) => _ZoneRoute(
        etatIndex: z.etat.index,
        fiabilite: z.fiabilite,
        cones: [
          for (final c in z.cones)
            _ConeRoute(
              lat: c.origine.latitude,
              lon: c.origine.longitude,
              rayon: c.rayon,
              cap: c.cap,
            ),
        ],
      );
}

RouteResult? _calculerChemin(_ArgumentsItineraire args) {
  final simulateur = TrafficSimulator();
  final maintenant = DateTime.now();

  final segments = args.segments
      .where((s) => s.points.length >= 2)
      .where((s) => !args.segmentsInterdits.contains(s.id))
      .toList(growable: false);
  if (segments.length < 2) return null;

  final parcours = [
    for (final p in args.points) LatLng(p.lat, p.lon),
  ];
  if (parcours.length < 2) return null;

  // Snap de chaque point du parcours sur le réseau de rues.
  final snaps = <_Snap>[];
  final raccords = <List<_Snap>>[];
  for (final p in parcours) {
    final snap = _segmentLePlusProche(p, segments);
    if (snap == null) return null;
    snaps.add(snap);
    // En plus de la rue la plus proche, on relie aussi les rues voisines :
    // si le point tombe dans une impasse isolée du graphe (garage, allée),
    // Dijkstra rejoint quand même la chaussée principale au lieu d'échouer.
    raccords.add(_raccordsElargis(p, snap, segments));
  }

  // Découpe chaque rue en tronçons entre carrefours : un grand boulevard
  // qui traverse plusieurs intersections devient une chaîne d'arêtes et on
  // peut donc y tourner à chaque carrefour.
  final troncons = _decouperAuxCarrefours(segments);

  // Les grands boulevards à chaussées séparées existent en deux (ou plus)
  // ways parallèles du même nom : on les repère ici pour interdire au
  // chemin de sauter de l'une à l'autre (la ligne affichée se serait
  // dédoublée sur toute la longueur de l'artère).
  final jumeaux = _jumeauxParmi(troncons);

  final graphe = _GrapheRoutes();
  for (var ti = 0; ti < troncons.length; ti++) {
    final t = troncons[ti];
    final longueur = _longueur(t.points);
    if (longueur <= 0) continue;
    final sev = _severitePour(args, simulateur, t.segment, maintenant);
    // Phase 1 : le classement des 10 candidats se fait SANS trafic (coût =
    // distance uniquement). La sévérité reste stockée sur l'arête pour la
    // phase 2 (classement par distance + trafic) et la coloration du tracé.
    final cout = longueur;
    final a = graphe.noeudPour(t.points.first);
    final b = graphe.noeudPour(t.points.last);
    graphe.ajouterArete(a, b, t.points, longueur, cout, sev, idTroncon: ti);
  }

  // Nœud virtuel par point du parcours, chacun relié à ses rues de
  // raccrochage : les jambes Dijkstra passent obligatoirement par eux.
  // Une étape (point intermédiaire) devient un passage OBLIGÉ SUR la
  // chaussée, au point projeté : comme OSRM/Yango, on route jusqu'à la
  // projection plutôt qu'à un drapeau hors route, pour éviter un
  // aller-retour qui dessinerait deux lignes superposées sur la même rue.
  final idsVirtuels = <int>[];
  for (var i = 0; i < parcours.length; i++) {
    final estEtape = 0 < i && i < parcours.length - 1;
    final id = graphe.nouveauNoeud(estEtape ? snaps[i].projete : parcours[i]);
    idsVirtuels.add(id);
    if (estEtape) {
      _relierSnap(
          graphe, args, simulateur, maintenant, id, snaps[i].projete, snaps[i]);
      continue;
    }
    for (final snap in raccords[i]) {
      _relierSnap(
          graphe, args, simulateur, maintenant, id, parcours[i], snap);
    }
  }

  // Départ et arrivée d'une même rue : raccourci direct sans détour par
  // les nœuds des extrémités de la chaussée. (Une étape n'entre pas dans
  // ce raccourci : son nœud est déjà sur la chaussée.)
  for (var i = 0; i + 1 < parcours.length; i++) {
    final aEtape = 0 < i && i < parcours.length - 1;
    final bEtape = 0 < i + 1 && i + 1 < parcours.length - 1;
    if (aEtape || bEtape) continue;
    if (snaps[i].segment.id != snaps[i + 1].segment.id) continue;
    final a = parcours[i];
    final b = parcours[i + 1];
    final projA = snaps[i].projete;
    final projB = snaps[i + 1].projete;
    final d = _distanceMetres(a, projA) +
        _distanceMetres(projA, projB) +
        _distanceMetres(projB, b);
    final sev = _severitePour(args, simulateur, snaps[i].segment, maintenant);
    graphe.ajouterArete(
      idsVirtuels[i],
      idsVirtuels[i + 1],
      [a, projA, projB, b],
      d,
      d,
      sev,
    );
  }

  // ----- Phase 1 : les chemins les plus rapides, SANS trafic -----
  // Le coût des arêtes est la distance pure (plus les pénalités géométriques
  // anti-zigzag) : Yen génère des chemins distincts, les plus courts. On
  // regarde les couleurs après chaque palier de [_kCheminsMax] : si la
  // meilleure ligne est propre (≥ 50 % de vert, 0 % de rouge, 0 % de noir,
  // < 30 % d'orange foncé), on s'arrête ; sinon on cherche 5 nouvelles lignes
  // (jamais un recalcul des chemins déjà produits), jusqu'au plafond de
  // [_kCheminsPlafond]. Au-delà, on garde la meilleure quelle que soit sa
  // couleur. Même logique quand une étape est ajoutée : chaque nouvelle ligne
  // de la première jambe est étendue aux étapes suivantes, par paliers de 5.
  // Chaque étape reste un passage obligé ; une jambe ne réutilise jamais les
  // rues déjà prises par une autre jambe du même candidat.
  final candidats = <_Candidat>[];

  // Étend une jambe d'étape : les variantes « sans superposition » (aucune rue
  // déjà empruntée n'est réutilisée, une seule ligne garantie) et « naturelle »
  // (le plus court, réutilisation permise, conservée seulement si elle ne
  // replie aucune chaussée déjà dessinée).
  List<_Candidat> etendre(List<_Candidat> enCours, int i) {
    final suivants = <_Candidat>[];
    for (final candidat in enCours) {
      // Variante « sans superposition » : aucune rue déjà empruntée n'est
      // réutilisée. Elle garantit une seule ligne à l'écran, mais peut
      // imposer un détour important quand l'étape est au milieu d'une rue
      // (le prolongement naturel est interdit).
      var jambe = _dijkstra(
        graphe,
        idsVirtuels[i],
        idsVirtuels[i + 1],
        jumeaux,
        interditTroncons: candidat.troncons,
      );
      if (jambe == null && candidat.troncons.isNotEmpty) {
        // Impossible de joindre l'étape sans repasser par une rue déjà
        // utilisée (étape sur une rue unique, impasse, réseau filtré) : on
        // autorise la réutilisation MAIS à fort surcoût. Dijkstra préférera
        // ainsi tout détour raisonnable plutôt qu'une ligne qui se replie,
        // et ne double qu'en tout dernier ressort. Les chaussées jumelles
        // sont pénalisées aussi : sans cela la jambe repartirait sur
        // l'autoroute parallèle à 4 m, redessinant la même rue.
        Journal.a(
          'ITINERAIRE',
          'Rues disjointes impossibles, surcoût de réutilisation sur la '
              'jambe $i',
        );
        final penalises = <int>{...candidat.troncons};
        for (final ti in candidat.troncons) {
          penalises.addAll(jumeaux[ti] ?? const {});
          final pts = troncons[ti].points;
          for (var u = 0; u < troncons.length; u++) {
            if (penalises.contains(u)) continue;
            if (_distanceMinEchantillonnee(pts, troncons[u].points) > 40) {
              continue;
            }
            if (!_directionsAlignees(pts, troncons[u].points)) continue;
            penalises.add(u);
          }
        }
        jambe = _dijkstra(
          graphe,
          idsVirtuels[i],
          idsVirtuels[i + 1],
          jumeaux,
          tronconsPenalises: penalises,
        );
      }
      if (jambe != null) {
        suivants.add(_Candidat(
          [...candidat.jambes, jambe.aretes],
          {...candidat.troncons, ..._tronconsDe(jambe)},
        ));
      }

      // Variante « naturelle » : le plus court, réutilisation des rues
      // permise. Elle ne contredit jamais la règle de l'itinéraire simple
      // (une seule ligne) : elle n'est conservée que si elle ne replie
      // aucune chaussée déjà dessinée. C'est elle qui évite le détour quand
      // l'étape est au milieu d'une rue, où le prolongement naturel est plus
      // court que le contournement exigé par l'interdiction ci-dessus.
      final naturel = _dijkstra(
        graphe,
        idsVirtuels[i],
        idsVirtuels[i + 1],
        jumeaux,
      );
      if (naturel != null) {
        final candidatNaturel = _Candidat(
          [...candidat.jambes, naturel.aretes],
          {...candidat.troncons, ..._tronconsDe(naturel)},
        );
        if (_nbReplis(_pointsDe(candidatNaturel)) == 0) {
          suivants.add(candidatNaturel);
        }
      }
    }
    // L'ensemble des candidats croît de deux variantes par étape : au-delà
    // du plafond, on ne garde que les tracés les plus courts (les autres ne
    // peuvent plus gagner le classement final que de façon négligeable).
    if (suivants.length > _maxCandidatsEtapes) {
      suivants.sort(
          (a, b) => _longueurTotale(a).compareTo(_longueurTotale(b)));
      suivants.removeRange(_maxCandidatsEtapes, suivants.length);
    }
    return suivants;
  }

  // Une nouvelle ligne de la première jambe devient une ou plusieurs lignes
  // complètes : une seule sans étape, sinon étendue aux étapes suivantes.
  void ajouterChemin(_Chemin chemin) {
    if (parcours.length == 2) {
      candidats.add(_Candidat([chemin.aretes], _tronconsDe(chemin)));
      return;
    }
    var enCours = <_Candidat>[_Candidat([chemin.aretes], _tronconsDe(chemin))];
    for (var i = 1; i + 1 < parcours.length && enCours.isNotEmpty; i++) {
      enCours = etendre(enCours, i);
    }
    candidats.addAll(enCours);
  }

  final generateur = _GenerateurChemins(
      graphe, idsVirtuels[0], idsVirtuels[1], jumeaux);
  var trouves = 0;
  while (trouves < _kCheminsPlafond) {
    var dansPalier = 0;
    while (dansPalier < _kCheminsMax && trouves < _kCheminsPlafond) {
      final chemin = generateur.suivant();
      if (chemin == null) break;
      ajouterChemin(chemin);
      trouves++;
      dansPalier++;
    }
    if (candidats.isNotEmpty &&
        _couleursPropres(_meilleurCandidat(candidats))) {
      Journal.i('MOTEUR LOCAL',
          'Meilleure ligne propre dès le palier de ${candidats.length} '
          'chemins');
      break;
    }
    if (dansPalier < _kCheminsMax) break; // plus aucune ligne disponible
    if (trouves >= _kCheminsPlafond) break; // plafond atteint : la
    // meilleure sera gardée quelle que soit sa couleur.
    Journal.i('MOTEUR LOCAL', 'Meilleure ligne non propre, recherche '
        'élargie de $_kCheminsMax lignes', {
      'candidats': candidats.length,
    });
    args.porteEvenements?.send(null);
  }

  // Aucun tracé possible sur le réseau : repli OSRM (l'appelant renvoie null).
  if (candidats.isEmpty) {
    Journal.a('MOTEUR LOCAL',
        'Aucun chemin trouvé sur le réseau local (points hors route ?)');
    return null;
  }

  // ----- Phase 2 : classement « distance + trafic » -----
  // Pour chaque candidat, on ajoute à son temps de base (vitesse libre) une
  // majoration selon le trafic réel rencontré (méthode additive). Le meilleur
  // score est la seule route retenue ; les autres restent masquées.
  final meilleur = _meilleurCandidat(candidats);
  final meilleurScore = _scoreCandidat(meilleur);
  Journal.i('MOTEUR LOCAL',
      'Itinéraire retenu parmi ${candidats.length} chemins les plus rapides',
      {'couleurs': _distributionCouleurs(meilleur)});
  if (candidats.length > 1) {
    Journal.i('MOTEUR LOCAL', 'Classement distance + trafic effectué', {
      'candidats': candidats.length,
      'meilleur_score_s': meilleurScore.round(),
    });
  }

  // ----- Assemblage de la géométrie du tracé retenu -----
  var distanceTotale = 0.0;
  final points = <LatLng>[];
  final severites = <double>[];
  final tronconsUtilises = <int>{};
  for (final jambe in meilleur.jambes) {
    for (final arete in jambe) {
      if (arete.idTroncon >= 0) tronconsUtilises.add(arete.idTroncon);
      distanceTotale += arete.longueurMetres;
      for (final p in arete.points) {
        if (points.isNotEmpty && _distanceMetres(points.last, p) < 3.0) {
          continue;
        }
        points.add(p);
        severites.add(arete.severite);
      }
    }
  }
  if (points.length < 2) return null;
  final (pointsAlleger, severitesAlleger) = _alleger(points, severites);

  // Départ/arrivée tombant dans une parcelle (bâtiment, cour…) : la portion
  // hors route reste dans le tracé mais est bornée pour être dessinée en
  // pointillés noirs ; la couleur ne commence qu'une fois la route atteinte.
  // En deçà du seuil, l'imprécision GPS fait que l'utilisateur est réputé
  // sur la route : pas de pointillés.
  var debutRoute = 0;
  var finRoute = pointsAlleger.length - 1;
  if (_distanceMetres(parcours.first, snaps.first.projete) >
      _seuilHorsRouteMetres) {
    debutRoute = _indexLePlusProche(
        pointsAlleger, snaps.first.projete, depuisLaFin: false);
  }
  if (_distanceMetres(parcours.last, snaps.last.projete) >
      _seuilHorsRouteMetres) {
    finRoute = _indexLePlusProche(
        pointsAlleger, snaps.last.projete, depuisLaFin: true);
  }
  if (finRoute - debutRoute < 1) {
    // Tracé minuscule entièrement hors route : tout garder coloré plutôt
    // que de ne rien afficher.
    debutRoute = 0;
    finRoute = pointsAlleger.length - 1;
  }

  // Les segments réellement empruntés (id OSM) : la carte affichera
  // l'itinéraire en montrant EXACTEMENT ces polylignes de circulation déjà
  // chargées et en masquant toutes les autres — rien n'est re-tracé.
  final segmentsIds = <int>{
    for (final ti in tronconsUtilises) troncons[ti].segment.id,
  }.toList();

  return RouteResult(
    points: pointsAlleger,
    distanceMeters: distanceTotale,
    durationSeconds: meilleurScore,
    severites: severitesAlleger,
    indexDebutRoute: debutRoute,
    indexFinRoute: finRoute,
    segmentsIds: segmentsIds,
  );
}

/// Au-delà de cette distance au réseau routier, le départ ou l'arrivée est
/// jugé « hors route » (bâtiment, parcelle) : son raccord à la chaussée est
/// dessiné en pointillés noirs, comme chez Yango.
const double _seuilHorsRouteMetres = 25;

/// Index du point de [pts] le plus proche de [cible], cherché parmi les
/// premiers points (ou les derniers si [depuisLaFin]) : c'est là que la
/// portion colorée commence/se termine quand un raccord hors-route existe.
/// La fenêtre suffit largement : seuls le point réel, sa projection et un
/// point de chaussée peuvent occuper ce voisinage après allègement.
int _indexLePlusProche(
  List<LatLng> pts,
  LatLng cible, {
  required bool depuisLaFin,
}) {
  const fenetre = 6;
  final n = pts.length;
  final premier = depuisLaFin ? math.max(0, n - fenetre) : 0;
  final dernier = depuisLaFin ? n - 1 : math.min(n - 1, fenetre);
  var meilleur = depuisLaFin ? n - 1 : 0;
  var minD = double.infinity;
  for (var i = premier; i <= dernier; i++) {
    final d = _distanceMetres(pts[i], cible);
    if (d < minD) {
      minD = d;
      meilleur = i;
    }
  }
  return meilleur;
}

class _Snap {
  final RoadSegment segment;
  final LatLng projete;
  final int index;

  const _Snap(this.segment, this.projete, this.index);
}

/// Repère les tronçons « jumeaux » : deux chaussées parallèles du même
/// boulevard séparé, cartographiées en deux ways distinctes qui portent le
/// même nom. Critères : même nom non vide, profils à moins de 35 m l'un de
/// l'autre et directions globalement alignées (même sens ou sens inverse).
/// Les suites directes (way A qui continue en way B au même endroit) sont
/// exclues : leurs extrémités se touchent, ce n'est pas un doublon.
Map<int, Set<int>> _jumeauxParmi(List<_Troncon> troncons) {
  final groupes = <String, List<int>>{};
  for (var i = 0; i < troncons.length; i++) {
    final nom = troncons[i].segment.nom.trim().toLowerCase();
    if (nom.isEmpty) continue;
    groupes.putIfAbsent(nom, () => []).add(i);
  }

  const distanceJumelle = 35.0;
  const contactExtremite = 15.0;

  bool seTouchent(List<LatLng> a, List<LatLng> b) {
    for (final p in [a.first, a.last]) {
      for (final q in [b.first, b.last]) {
        if (_distanceMetres(p, q) <= contactExtremite) return true;
      }
    }
    return false;
  }

  final jumeaux = <int, Set<int>>{};
  for (final ids in groupes.values) {
    if (ids.length < 2) continue;
    for (var x = 0; x < ids.length; x++) {
      for (var y = x + 1; y < ids.length; y++) {
        final ptsA = troncons[ids[x]].points;
        final ptsB = troncons[ids[y]].points;
        if (_distanceMinEchantillonnee(ptsA, ptsB) > distanceJumelle) continue;
        if (seTouchent(ptsA, ptsB)) continue;
        if (!_directionsAlignees(ptsA, ptsB)) continue;
        jumeaux.putIfAbsent(ids[x], () => {}).add(ids[y]);
        jumeaux.putIfAbsent(ids[y], () => {}).add(ids[x]);
      }
    }
  }
  return jumeaux;
}

List<LatLng> _echantillon(List<LatLng> pts, int max) {
  if (pts.length <= max) return pts;
  final pas = pts.length / max;
  return [for (var i = 0; i < max; i++) pts[(i * pas).floor()]];
}

double _distanceMinEchantillonnee(List<LatLng> a, List<LatLng> b) {
  final ea = _echantillon(a, 12);
  final eb = _echantillon(b, 12);
  var min = double.infinity;
  for (final p in ea) {
    for (final q in eb) {
      final d = _distanceMetres(p, q);
      if (d < min) min = d;
    }
  }
  return min;
}

/// Vrai si les directions globales des deux polylignes sont à peu près
/// parallèles (produit scalaire des vecteurs first→last, |cos| >= 0.55).
bool _directionsAlignees(List<LatLng> a, List<LatLng> b) {
  (double, double) direction(List<LatLng> pts) {
    final cosLat =
        math.cos((pts.first.latitude + pts.last.latitude) * 0.5 * math.pi / 180);
    final dx = (pts.last.longitude - pts.first.longitude) * cosLat;
    final dy = pts.last.latitude - pts.first.latitude;
    final norme = math.sqrt(dx * dx + dy * dy);
    if (norme <= 0) return (0.0, 0.0);
    return (dx / norme, dy / norme);
  }

  final (ax, ay) = direction(a);
  final (bx, by) = direction(b);
  return (ax * bx + ay * by).abs() >= 0.55;
}

class _Troncon {
  final RoadSegment segment;
  final List<LatLng> points;

  const _Troncon(this.segment, this.points);
}

/// Découpe les rues aux carrefours : un point est un carrefour s'il est à
/// moins de 8 m d'un point d'une AUTRE rue. Chaque tronçon relie alors deux
/// carrefours et le graphe permet de tourner à toutes les intersections.
List<_Troncon> _decouperAuxCarrefours(List<RoadSegment> segments) {
  const tailleCellule = 0.0001;
  const tolerance = 8.0;

  int cle(int r, int c) => r * 131071 + c;

  final grille = <int, List<(int, int)>>{};
  for (var si = 0; si < segments.length; si++) {
    final pts = segments[si].points;
    for (var pi = 0; pi < pts.length; pi++) {
      final p = pts[pi];
      final r = (p.latitude / tailleCellule).floor();
      final c = (p.longitude / tailleCellule).floor();
      grille.putIfAbsent(cle(r, c), () => []).add((si, pi));
    }
  }

  final troncons = <_Troncon>[];
  for (var si = 0; si < segments.length; si++) {
    final segment = segments[si];
    final pts = segment.points;
    var debut = 0;
    for (var pi = 1; pi < pts.length - 1; pi++) {
      final p = pts[pi];
      final r = (p.latitude / tailleCellule).floor();
      final c = (p.longitude / tailleCellule).floor();
      var carrefour = false;
      boucle:
      for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
          final entrees = grille[cle(r + dr, c + dc)];
          if (entrees == null) continue;
          for (final (sj, pj) in entrees) {
            if (sj == si) continue;
            if (_distanceMetres(p, segments[sj].points[pj]) <= tolerance) {
              carrefour = true;
              break boucle;
            }
          }
        }
      }
      if (carrefour) {
        troncons.add(_Troncon(segment, pts.sublist(debut, pi + 1)));
        debut = pi;
      }
    }
    troncons.add(_Troncon(segment, pts.sublist(debut)));
  }
  return troncons;
}

_Snap? _segmentLePlusProche(LatLng p, List<RoadSegment> segments) {
  RoadSegment? meilleur;
  LatLng? projete;
  var index = 0;
  var minD = double.infinity;
  for (final s in segments) {
    final (proj, d, i) = _projeter(p, s.points);
    if (d < minD) {
      minD = d;
      meilleur = s;
      projete = proj;
      index = i;
    }
  }
  if (meilleur == null || projete == null) return null;
  return _Snap(meilleur, projete, index);
}

/// Rues à raccorder au nœud virtuel du point [p] : la rue la plus proche
/// [proche], puis jusqu'à [maxCandidats] autres rues dont la projection se
/// trouve dans [_rayonRaccordMetres]. Toutes ces arêtes virtuelles sont des
/// secours : si la rue la plus proche est un cul-de-sac déconnecté du graphe,
/// un voisin peut quand même porter l'itinéraire. Le coût réel du raccord
/// (distance hors route + chemin le long de la chaussée) fait que Dijkstra
/// choisit naturellement la rue la plus commode.
const double _rayonRaccordMetres = 60;
const int _maxRaccords = 5;

List<_Snap> _raccordsElargis(
  LatLng p,
  _Snap proche,
  List<RoadSegment> segments,
) {
  final trouve = <_Snap>[proche];
  final vus = <int>{proche.segment.id};
  final restants = <(double, _Snap)>[];
  for (final s in segments) {
    if (vus.contains(s.id)) continue;
    final (proj, d, i) = _projeter(p, s.points);
    if (d > _rayonRaccordMetres) continue;
    vus.add(s.id);
    restants.add((d, _Snap(s, proj, i)));
  }
  restants.sort((a, b) => a.$1.compareTo(b.$1));
  for (final entree in restants) {
    if (trouve.length >= _maxRaccords) break;
    trouve.add(entree.$2);
  }
  return trouve;
}

/// Relie le nœud virtuel [id] (départ ou arrivée) aux deux bouts de la rue
/// sur laquelle il est projeté, avec la géométrie et le coût exacts.
void _relierSnap(
  _GrapheRoutes graphe,
  _ArgumentsItineraire args,
  TrafficSimulator simulateur,
  DateTime maintenant,
  int id,
  LatLng point,
  _Snap snap,
) {
  final points = snap.segment.points;
  final proj = snap.projete;
  final i = snap.index;
  final sev = _severitePour(args, simulateur, snap.segment, maintenant);

  // Géométrie depuis le point virtuel jusqu'au début de la rue.
  final geoDebut = <LatLng>[
    point,
    proj,
    ...points.sublist(0, i + 1).reversed,
  ];
  final dDebut = _distanceMetres(point, proj) + _distanceMetres(proj, points.first);
  graphe.ajouterArete(
    id,
    graphe.noeudPour(points.first),
    geoDebut,
    dDebut,
    dDebut,
    sev,
  );

  // Géométrie depuis le point virtuel jusqu'à la fin de la rue.
  final geoFin = <LatLng>[
    point,
    proj,
    ...points.sublist(i + 1),
  ];
  final dFin = _distanceMetres(point, proj) + _distanceMetres(proj, points.last);
  graphe.ajouterArete(
    id,
    graphe.noeudPour(points.last),
    geoFin,
    dFin,
    dFin,
    sev,
  );
}

/// Degré d'embouteillage d'une rue, de 0 (fluide) à 3 (bloquée), en
/// mélangeant l'état simulé et, le cas échéant, la zone signalée la plus
/// proche (fiabilité 0..1) : c'est l'état réellement affiché sur la carte.
double _severitePour(
  _ArgumentsItineraire args,
  TrafficSimulator simulateur,
  RoadSegment segment,
  DateTime maintenant,
) {
  final milieu = segment.points[segment.points.length ~/ 2];
  final sevSim = simulateur.estimer(segment, moment: maintenant).index.toDouble();
  var sev = sevSim;
  for (final z in args.zones) {
    if (!_zoneCouvre(z, milieu)) continue;
    sev = sevSim + (z.etatIndex - sevSim) * z.fiabilite.clamp(0.0, 1.0);
    break;
  }
  return sev;
}

double _facteur(double severite) {
  const facteurs = [1.0, 1.8, 3.2, 6.0];
  final x = severite.clamp(0.0, 3.0);
  final i = x.floor();
  final t = x - i;
  final a = facteurs[i];
  final b = facteurs[math.min(i + 1, 3)];
  return a + (b - a) * t;
}

bool _zoneCouvre(_ZoneRoute z, LatLng p) {
  for (final c in z.cones) {
    final d = _distanceMetres(LatLng(c.lat, c.lon), p);
    if (d > c.rayon) continue;
    final cap = c.cap;
    if (cap == null) return true;
    final angle = _angleVers(c.lat, c.lon, p.latitude, p.longitude);
    var diff = (angle - cap) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    if (diff.abs() <= 45) return true;
  }
  return false;
}

double _angleVers(double latO, double lonO, double latP, double lonP) {
  final lat1 = latO * math.pi / 180;
  final lat2 = latP * math.pi / 180;
  final dLon = (lonP - lonO) * math.pi / 180;
  final y = math.sin(dLon) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _distanceMetres(LatLng a, LatLng b) {
  const rayon = 111320.0;
  final cosLat = math.cos(b.latitude * math.pi / 180);
  final dLat = (a.latitude - b.latitude) * rayon;
  final dLon = (a.longitude - b.longitude) * rayon * cosLat;
  return math.sqrt(dLat * dLat + dLon * dLon);
}

double _longueur(List<LatLng> points) {
  var total = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    total += _distanceMetres(points[i], points[i + 1]);
  }
  return total;
}

/// Projection orthogonale de [p] sur la polyligne [points].
/// Renvoie (point projeté, distance en mètres, index de l'arête).
(LatLng, double, int) _projeter(LatLng p, List<LatLng> points) {
  var minD = double.infinity;
  var minIndex = 0;
  LatLng? minProj;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    final cosLat = math.cos(b.latitude * math.pi / 180);
    final ax = (b.longitude - a.longitude) * cosLat;
    final ay = b.latitude - a.latitude;
    final bx = (p.longitude - a.longitude) * cosLat;
    final by = p.latitude - a.latitude;
    final len2 = ax * ax + ay * ay;
    if (len2 <= 0) continue;
    final t = ((bx * ax + by * ay) / len2).clamp(0.0, 1.0);
    final px = a.longitude + t * (b.longitude - a.longitude);
    final py = a.latitude + t * (b.latitude - a.latitude);
    final proj = LatLng(py, px);
    final d = _distanceMetres(p, proj);
    if (d < minD) {
      minD = d;
      minIndex = i;
      minProj = proj;
    }
  }
  return (minProj ?? p, minD, minIndex);
}

/// Pénalité de manœuvre (en équivalent mètres, l'unité de coût du graphe)
/// pour enchaîner [arrivee] puis [sortie] à un carrefour : tout droit est
/// gratuit, un virage coûte quelques secondes, un demi-tour encore plus.
/// Les grands boulevards à chaussées séparées sont cartographiés en plusieurs
/// ways parallèles reliés aux carrefours : sans garde-fou, le chemin saute
/// d'une chaussée à l'autre à chaque intersection et la ligne affichée se
/// dédouble. Un saut se reconnaît à son cap identique MAIS à son décalage
/// latéral (largeur du terre-plein) : il est fortement pénalisé pour que le
/// tracé reste collé à une seule chaussée, donc à UNE seule ligne à l'écran.
double _penaliteVirage(_Arete? arrivee, _Arete sortie) {
  if (arrivee == null ||
      arrivee.points.length < 2 ||
      sortie.points.length < 2) {
    return 0;
  }
  final entree = arrivee.points[arrivee.points.length - 2];
  final sortieCap =
      _angleVers(sortie.points.first.latitude, sortie.points.first.longitude,
          sortie.points[1].latitude, sortie.points[1].longitude);
  final entreeCap = _angleVers(
      entree.latitude, entree.longitude,
      arrivee.points.last.latitude, arrivee.points.last.longitude);
  var diff = (sortieCap - entreeCap).abs() % 360;
  if (diff > 180) diff = 360 - diff;
  if (diff >= 45) {
    if (diff < 70) return 20;
    if (diff < 120) return 45;
    if (diff < 150) return 80;
    // Demi-tour quasi pur : sans surcoût marqué, le chemin « descend » une
    // chaussée d'un boulevard séparé puis « remonte » l'autre, ce qui dessine
    // deux lignes parallèles au lieu d'une seule.
    return 140;
  }
  // Cap quasi identique : tout droit… sauf si la sortie décolle latéralement
  // vers l'autre chaussée. On teste les deux premiers pas de la sortie pour
  // ne pas se faire piéger par la géométrie du carrefour lui-même.
  var ecart = _ecartLateral(sortie.points[1], entree, arrivee.points.last);
  if (sortie.points.length > 2) {
    ecart = math.max(
      ecart,
      _ecartLateral(sortie.points[2], entree, arrivee.points.last),
    );
  }
  if (ecart > 12) return 150;
  return 0;
}

/// Distance perpendiculaire (en mètres) de [p] à la droite [a]-[b].
double _ecartLateral(LatLng p, LatLng a, LatLng b) {
  const rayon = 111320.0;
  final cosLat = math.cos((a.latitude + b.latitude) * 0.5 * math.pi / 180);
  final bx = (b.longitude - a.longitude) * rayon * cosLat;
  final by = (b.latitude - a.latitude) * rayon;
  final px = (p.longitude - a.longitude) * rayon * cosLat;
  final py = (p.latitude - a.latitude) * rayon;
  final longueur = math.sqrt(bx * bx + by * by);
  if (longueur <= 0) return _distanceMetres(p, a);
  return (px * by - py * bx).abs() / longueur;
}

/// Pénalité de changement de chaussée sur un boulevard séparé : le chemin
/// doit rester sur UNE seule ligne du début à la fin. Deux cas :
///  • passage direct à une chaussée jumelle → très lourd ;
///  • départ vers une rue transversale alors que la chaussée jumelle est
///    raccordée au même carrefour (le passage se fera par là) → modéré.
/// Les arêtes virtuelles (-1, raccords départ/arrivée) ne pénalisent rien.
double _penaliteChaussee(
  _Arete? entree,
  _Arete sortie,
  int noeud,
  _GrapheRoutes g,
  Map<int, Set<int>> jumeaux,
) {
  if (entree == null || entree.idTroncon < 0 || sortie.idTroncon < 0) return 0;
  if (entree.idTroncon == sortie.idTroncon) return 0;

  final jumellesEntree = jumeaux[entree.idTroncon];
  if (jumellesEntree == null || jumellesEntree.isEmpty) return 0;

  if (jumellesEntree.contains(sortie.idTroncon)) {
    // Saut direct sur l'autre chaussée.
    return 350;
  }

  // La chaussée qu'on quitte a une jumelle accessible depuis ce même
  // carrefour : on est en train de basculer d'une ligne de l'artère à
  // l'autre via la transversale.
  final surPlace = g.tronconsParNoeud[noeud];
  if (surPlace == null) return 0;
  for (final id in surPlace) {
    if (id != entree.idTroncon && jumellesEntree.contains(id)) return 60;
  }
  return 0;
}

_Chemin? _dijkstra(
  _GrapheRoutes g,
  int depart,
  int arrivee,
  Map<int, Set<int>> jumeaux, {
  Set<int> interditTroncons = const {},
  Set<int> noeudsInterdits = const {},
  Set<(int, int)> aretesInterdites = const {},
  Set<int> tronconsPenalises = const {},
}) {
  final dist = <int, double>{depart: 0};
  final precedent = <int, (int source, _Arete arete)>{};
  final tas = _Tas()..ajouter(0, depart);

  while (!tas.estVide) {
    final (d, n) = tas.retirer();
    if (n == arrivee) break;
    if (d > (dist[n] ?? double.infinity)) continue;
    final aretes = g.adjacence[n];
    if (aretes == null) continue;
    final entree = precedent[n]?.$2;
    for (final arete in aretes) {
      // Rues déjà empruntées par une jambe précédente : on ne les réutilise
      // pas. Les arêtes virtuelles (-1, raccords départ/arrivée) restent
      // toujours permises.
      if (arete.idTroncon >= 0 &&
          interditTroncons.contains(arete.idTroncon)) {
        continue;
      }
      // Nœuds de la racine (Yen) : le chemin spur ne repasse jamais par un
      // nœud déjà sur la racine, hormis le nœud spur lui-même (départ).
      if (noeudsInterdits.contains(arete.vers)) {
        continue;
      }
      // Arêtes retirées (Yen) : interdiction de traverser un arc précis.
      if (aretesInterdites.contains((n, arete.vers))) {
        continue;
      }
      var penalite = _penaliteVirage(entree, arete);
      penalite += _penaliteChaussee(entree, arete, n, g, jumeaux);
      // Rue déjà empruntée par une jambe précédente (étape) : réutilisable en
      // dernier ressort seulement, grâce à un surcoût qui fait pencher Dijkstra
      // vers tout détour raisonnable plutôt que vers une ligne qui se replie.
      if (arete.idTroncon >= 0 &&
          tronconsPenalises.contains(arete.idTroncon)) {
        penalite += _penaliteReutilisationMetres;
      }
      final nd = d + arete.cout + penalite;
      if (nd < (dist[arete.vers] ?? double.infinity)) {
        dist[arete.vers] = nd;
        precedent[arete.vers] = (n, arete);
        tas.ajouter(nd, arete.vers);
      }
    }
  }

  if (!dist.containsKey(arrivee)) return null;

  final aretes = <_Arete>[];
  var courant = arrivee;
  while (courant != depart) {
    final (source, arete) = precedent[courant]!;
    aretes.add(arete);
    courant = source;
  }

  final aretesOrdonnees = aretes.reversed.toList(growable: false);
  final noeuds = <int>[depart];
  for (final arete in aretesOrdonnees) {
    noeuds.add(arete.vers);
  }

  return _Chemin(noeuds, aretesOrdonnees, dist[arrivee]!);
}

/// Nombre de chemins alternatifs cherchés à chaque palier de la phase 1 :
/// les 5 lignes les plus rapides d'abord, puis on élargit par nouvelles
/// fournées de [_kCheminsMax] tant que la meilleure ligne n'est pas propre.
const int _kCheminsMax = 5;

/// Plafond total de chemins cherchés en phase 1 (paliers de 5, jamais de
/// recalcul des chemins déjà produits). Au-delà, on s'arrête et on retient la
/// meilleure ligne quelle que soit sa couleur.
const int _kCheminsPlafond = 25;

/// Surcoût (équivalent-mètres) appliqué quand une jambe réutilise une rue déjà
/// empruntée par une jambe précédente : Dijkstra préfère un détour tant qu'il
/// coûte moins que ce surcoût, et ne double une chaussée qu'en dernier ressort.
const double _penaliteReutilisationMetres = 1200;

/// Plafond de candidats conservés à chaque palier (jambe d'étape) : les deux
/// variantes (sans superposition + naturelle) font croître l'ensemble vite ;
/// au-delà, seuls les tracés les plus courts survivent au palier suivant.
const int _maxCandidatsEtapes = 10;

/// Budget de lancements de Dijkstra pour l'ensemble de la recherche des k
/// chemins : borne le coût sur les grands réseaux (5 alternatives × longueur
/// de tracé peut devenir lourd) sans jamais renvoyer zéro chemin — le premier
/// Dijkstra fait déjà partie des résultats.
const int _budgetDijkstra = 30;

/// Génère les chemins les plus courts UN PAR UN (Yen incrémental) : chaque
/// appel de [suivant] reprend exactement l'état de la recherche précédente,
/// donc jamais de recalcul des chemins déjà produits quand la recherche
/// s'élargit par paliers de 5.
class _GenerateurChemins {
  _GenerateurChemins(
    this.g,
    this.depart,
    this.arrivee,
    this.jumeaux);

  final _GrapheRoutes g;
  final int depart;
  final int arrivee;
  final Map<int, Set<int>> jumeaux;

  /// Chemins déjà produits, par ordre de coût croissant. Leur dernier sert de
  /// racine à la recherche du chemin suivant.
  final List<_Chemin> _trouves = [];
  final List<_Chemin> _enAttente = [];
  final Set<String> _vus = {};
  var _lancees = 0;
  var _initialise = false;

  /// Prochain chemin le plus court, ou null si le réseau ne peut plus en
  /// produire. Le premier appel rend le plus court d'entre eux.
  _Chemin? suivant() {
    if (!_initialise) {
      _initialise = true;
      return _premier();
    }
    return _suivant();
  }

  _Chemin? _premier() {
    final premier = _dijkstra(g, depart, arrivee, jumeaux,
        interditTroncons: const {});
    if (premier == null) return null;
    _lancees++;
    _trouves.add(premier);
    _vus.add(_signature(premier.noeuds));
    return premier;
  }

  _Chemin? _suivant() {
    final base = _trouves.last;
    for (var i = 0; i < base.noeuds.length - 1; i++) {
      if (_lancees >= _budgetDijkstra) break;
      final spur = base.noeuds[i];
      final racine = base.noeuds.sublist(0, i + 1);
      final racineAretes = base.aretes.sublist(0, i);

      // Retrait des arêtes : pour chaque chemin déjà retenu empruntant cette
      // même racine, on interdit de réutiliser l'arête qui la prolonge.
      final interdites = <(int, int)>{};
      for (final c in _trouves) {
        if (c.noeuds.length <= i) continue;
        var meme = true;
        for (var j = 0; j <= i; j++) {
          if (c.noeuds[j] != racine[j]) {
            meme = false;
            break;
          }
        }
        if (meme) interdites.add((c.noeuds[i], c.noeuds[i + 1]));
      }

      // Retrait des nœuds : le chemin spur ne repasse par aucun nœud de la
      // racine (sauf le nœud spur lui-même, d'où sublist(0, i)).
      final noeudsInterdits = <int>{...racine.sublist(0, i)};

      _lancees++;
      final spurChemin = _dijkstra(g, spur, arrivee, jumeaux,
          interditTroncons: const {},
          noeudsInterdits: noeudsInterdits,
          aretesInterdites: interdites);
      if (spurChemin == null) continue;

      final coutRacine =
          racineAretes.fold(0.0, (acc, a) => acc + a.cout);
      final total = _Chemin(
        [...racine, ...spurChemin.noeuds.sublist(1)],
        [...racineAretes, ...spurChemin.aretes],
        coutRacine + spurChemin.cout,
      );
      if (_vus.contains(_signature(total.noeuds))) continue;
      _vus.add(_signature(total.noeuds));
      _enAttente.add(total);
    }

    if (_enAttente.isEmpty) return null;
    _enAttente.sort((a, b) => a.cout.compareTo(b.cout));
    final suivant = _enAttente.removeAt(0);
    _trouves.add(suivant);
    return suivant;
  }

  String _signature(List<int> noeuds) => noeuds.join('>');
}

/// Tronçons de chaussée auxquels appartiennent les arêtes d'un chemin.
Set<int> _tronconsDe(_Chemin chemin) => {
      for (final a in chemin.aretes)
        if (a.idTroncon >= 0) a.idTroncon,
    };

/// Points du tracé complet d'un candidat (toutes jambes confondues), avec la
/// même déduplication d'indices que le classement final.
List<LatLng> _pointsDe(_Candidat candidat) {
  final pts = <LatLng>[];
  for (final jambe in candidat.jambes) {
    for (final a in jambe) {
      for (final p in a.points) {
        if (pts.isNotEmpty && _distanceMetres(pts.last, p) < 3.0) continue;
        pts.add(p);
      }
    }
  }
  return pts;
}

/// Nombre de replis (chaussées repassées au même endroit) d'un tracé : deux
/// points à au moins [ecart] indices d'écart ne doivent pas se retrouver à
/// moins de [seuilRepli] m.
int _nbReplis(List<LatLng> pts) {
  const ecart = 40;
  const seuilRepli = 25.0;
  var replis = 0;
  for (var i = 0; i + ecart < pts.length; i++) {
    final p = pts[i];
    for (var j = i + ecart; j < pts.length; j++) {
      if (_distanceMetres(p, pts[j]) < seuilRepli) replis++;
    }
  }
  return replis;
}

/// Longueur totale cumulée des jambes d'un candidat : sert à borner le nombre
/// de candidats conservés à chaque palier.
double _longueurTotale(_Candidat candidat) {
  var total = 0.0;
  for (final jambe in candidat.jambes) {
    for (final a in jambe) {
      total += a.longueurMetres;
    }
  }
  return total;
}

/// Phase 2 : classement des candidats par score « distance + trafic » : celui
/// au plus petit score est la seule route retenue.
_Candidat _meilleurCandidat(List<_Candidat> candidats) {
  var meilleur = candidats.first;
  var meilleurScore = double.infinity;
  for (final candidat in candidats) {
    final score = _scoreCandidat(candidat);
    if (score < meilleurScore) {
      meilleurScore = score;
      meilleur = candidat;
    }
  }
  return meilleur;
}

/// Une ligne est « propre » quand ses couleurs tiennent les exigences de
/// l'utilisateur, mesurées sur la longueur réelle empruntée :
///  • au moins 50 % de route fluide (vert, sévérité < 1),
///  • 0 % de rouge (sévérité 2 → 2,5),
///  • 0 % de noir, route bloquée (sévérité ≥ 2,5),
///  • moins de 30 % d'orange foncé (sévérité 1,5 → 2).
/// L'orange clair (1 → 1,5) n'est soumis à aucune contrainte.
bool _couleursPropres(_Candidat candidat) {
  var total = 0.0;
  var verte = 0.0;
  var orangeFonce = 0.0;
  var rouge = 0.0;
  var noire = 0.0;
  for (final jambe in candidat.jambes) {
    for (final a in jambe) {
      final l = a.longueurMetres;
      total += l;
      final s = a.severite;
      if (s < 1.0) {
        verte += l;
      } else if (s < 1.5) {
        // Orange clair : aucune contrainte.
      } else if (s < 2.0) {
        orangeFonce += l;
      } else if (s < 2.5) {
        rouge += l;
      } else {
        noire += l;
      }
    }
  }
  if (total <= 0) return false;
  return verte / total >= 0.50 && rouge == 0 && noire == 0 &&
      orangeFonce / total < 0.30;
}

/// Répartition par longueur réelle des couleurs d'un candidat, dans les mêmes
/// tranches que [_couleursPropres] : vert (< 1), orange clair (1 → 1,5),
/// orange foncé (1,5 → 2), rouge (2 → 2,5), noir (≥ 2,5).
/// Chaîne lisible « 62,4 % vert · 20,1 % orange clair · 12,0 % orange foncé ·
/// 5,5 % rouge · 0,0 % noir ».
String _distributionCouleurs(_Candidat candidat) {
  var total = 0.0;
  final longueurs = [0.0, 0.0, 0.0, 0.0, 0.0];
  for (final jambe in candidat.jambes) {
    for (final a in jambe) {
      final l = a.longueurMetres;
      total += l;
      final s = a.severite;
      if (s < 1.0) {
        longueurs[0] += l;
      } else if (s < 1.5) {
        longueurs[1] += l;
      } else if (s < 2.0) {
        longueurs[2] += l;
      } else if (s < 2.5) {
        longueurs[3] += l;
      } else {
        longueurs[4] += l;
      }
    }
  }
  if (total <= 0) return 'aucune longueur';
  String pct(double metres) => '${(metres / total * 100).toStringAsFixed(1)} %';
  return '${pct(longueurs[0])} vert · ${pct(longueurs[1])} orange clair · '
      '${pct(longueurs[2])} orange foncé · ${pct(longueurs[3])} rouge · '
      '${pct(longueurs[4])} noir';
}

/// Phase 2 : score « distance + trafic » d'un candidat. Temps de base à
/// vitesse libre (distance ÷ 9 m/s) + majoration selon l'état de circulation
/// réel rencontré (méthode additive : pour un bouchon, (facteur − 1) ×
/// distance ÷ 9 m/s). Le candidat au plus petit score est la seule route
/// retenue.
double _scoreCandidat(_Candidat candidat) {
  var base = 0.0;
  var majoration = 0.0;
  for (final jambe in candidat.jambes) {
    for (final a in jambe) {
      base += a.longueurMetres / 9.0;
      majoration += a.longueurMetres * (_facteur(a.severite) - 1.0) / 9.0;
    }
  }
  // Pénalité « une seule ligne » : un tracé qui repasse à moins de
  // [seuilRepli] m d'un point déjà dessiné au moins [ecart] indices plus tôt
  // (jambe de départ qui se replie sur la jambe d'arrivée) est fortement
  // pénalisé au classement. Les chemins de Yen et les variantes naturelles se
  // départagent alors en faveur de la variante sans double tracé, même si elle
  // coûte quelques mètres de plus.
  base += _nbReplis(_pointsDe(candidat)) * 500.0;
  return base + majoration;
}

/// Allège le tracé final sans en changer la forme visible : supprime les
/// points quasi confondus (raccords entre ways) et les micro-détours dus aux
/// projections du départ/de l'arrivée ou aux jonctions des chaussées. Chaque
/// point conservé garde sa sévérité pour la coloration tronçon par tronçon.
(List<LatLng>, List<double>) _alleger(List<LatLng> pts, List<double> sev) {
  if (pts.length < 3 || pts.length != sev.length) return (pts, sev);
  const seuilDoublon = 3.0;
  const porteeDetour = 70.0;
  const seuilEcart = 6.0;

  final points = <LatLng>[pts.first];
  final severites = <double>[sev.first];
  for (var i = 1; i < pts.length - 1; i++) {
    final precedent = points.last;
    final actuel = pts[i];
    final suivant = pts[i + 1];
    if (_distanceMetres(precedent, actuel) < seuilDoublon) continue;
    if (_distanceMetres(precedent, suivant) < porteeDetour &&
        _deviationSegment(actuel, precedent, suivant) < seuilEcart) {
      continue;
    }
    points.add(actuel);
    severites.add(sev[i]);
  }
  if (_distanceMetres(points.last, pts.last) >= seuilDoublon) {
    points.add(pts.last);
    severites.add(sev.last);
  }
  if (points.length < 2) return (pts, sev);
  return (points, severites);
}

/// Distance perpendiculaire de [p] au segment [a]-[b] (en mètres).
double _deviationSegment(LatLng p, LatLng a, LatLng b) {
  const rayon = 111320.0;
  final cosLat = math.cos((a.latitude + b.latitude) * 0.5 * math.pi / 180);
  final bx = (b.longitude - a.longitude) * rayon * cosLat;
  final by = (b.latitude - a.latitude) * rayon;
  final px = (p.longitude - a.longitude) * rayon * cosLat;
  final py = (p.latitude - a.latitude) * rayon;
  final len2 = bx * bx + by * by;
  if (len2 <= 0) return _distanceMetres(p, a);
  final t = ((px * bx + py * by) / len2).clamp(0.0, 1.0);
  final dx = px - t * bx;
  final dy = py - t * by;
  return math.sqrt(dx * dx + dy * dy);
}
