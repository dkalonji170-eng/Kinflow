import 'dart:math' as math;
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/road_segment.dart';
import '../models/route_result.dart';
import 'diagnostics_service.dart';
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

  const _ArgumentsItineraire({
    required this.segments,
    required this.points,
    required this.zones,
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
    final List<RoadSegment> segments;
    try {
      segments = await _roads.obtenirRoutes(
        couloir,
        detailsComplets: !lointain,
      );
    } catch (e) {
      // Réseau Overpass indisponible : on renvoie null pour que l'appelant
      // bascule sur OSRM au lieu de laisser le calcul bloqué.
      Journal.e('MOTEUR LOCAL', 'Chargement des routes impossible', {
        'erreur': '$e',
        'mode': lointain ? 'grands axes' : 'détail complet',
      });
      debugPrint('[KinFlow] Échec chargement routes itinéraire: $e');
      return null;
    }
    if (segments.length < 2) {
      Journal.a('MOTEUR LOCAL', 'Réseau routier trop pauvre pour calculer', {
        'segments_recus': segments.length,
      });
      return null;
    }

    Journal.i('MOTEUR LOCAL', 'Calcul Dijkstra lancé en isolat', {
      'segments': segments.length,
      'zones_trafic': zones.length,
      'etapes': etapes.length,
      'mode': lointain ? 'grands axes' : 'détail complet',
    });
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
      .toList(growable: false);
  if (segments.length < 2) return null;

  final parcours = [
    for (final p in args.points) LatLng(p.lat, p.lon),
  ];
  if (parcours.length < 2) return null;

  // Snap de chaque point du parcours sur le réseau de rues.
  final snaps = <_Snap>[];
  for (final p in parcours) {
    final snap = _segmentLePlusProche(p, segments);
    if (snap == null) return null;
    snaps.add(snap);
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
    final cout = longueur * _facteur(sev);
    final a = graphe.noeudPour(t.points.first);
    final b = graphe.noeudPour(t.points.last);
    graphe.ajouterArete(a, b, t.points, longueur, cout, sev, idTroncon: ti);
  }

  // Nœud virtuel par point du parcours, chacun relié à sa rue de
  // raccrochage : les jambes Dijkstra passent obligatoirement par eux.
  final idsVirtuels = <int>[];
  for (var i = 0; i < parcours.length; i++) {
    final id = graphe.nouveauNoeud(parcours[i]);
    idsVirtuels.add(id);
    _relierSnap(
        graphe, args, simulateur, maintenant, id, parcours[i], snaps[i]);
  }

  // Départ et arrivée d'une même rue : raccourci direct sans détour par
  // les nœuds des extrémités de la chaussée.
  for (var i = 0; i + 1 < parcours.length; i++) {
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
      d * _facteur(sev),
      sev,
    );
  }

  // Une jambe Dijkstra par paire consécutive : chaque étape est un passage
  // obligé entre le départ (ou l'étape précédente) et la suite du parcours.
  var distanceTotale = 0.0;
  var coutTotal = 0.0;
  final points = <LatLng>[];
  final severites = <double>[];
  for (var i = 0; i + 1 < parcours.length; i++) {
    final resultat =
        _dijkstra(graphe, idsVirtuels[i], idsVirtuels[i + 1], jumeaux);
    if (resultat == null) return null;
    final (ptsJambe, distJambe, coutJambe, sevJambe) = resultat;
    distanceTotale += distJambe;
    coutTotal += coutJambe;
    // Au raccord, le point d'étape figure déjà en fin de jambe précédente :
    // on ne le duplique pas.
    for (var k = points.isEmpty ? 0 : 1; k < ptsJambe.length; k++) {
      if (points.isNotEmpty &&
          _distanceMetres(points.last, ptsJambe[k]) < 3.0) {
        continue;
      }
      points.add(ptsJambe[k]);
      severites.add(sevJambe[k]);
    }
  }
  if (points.length < 2) return null;

  // Départ/arrivée tombant dans une parcelle (bâtiment, cour…) : la portion
  // hors route reste dans le tracé mais est bornée pour être dessinée en
  // pointillés noirs ; la couleur ne commence qu'une fois la route atteinte.
  // En deçà du seuil, l'imprécision GPS fait que l'utilisateur est réputé
  // sur la route : pas de pointillés.
  var debutRoute = 0;
  var finRoute = points.length - 1;
  if (_distanceMetres(parcours.first, snaps.first.projete) >
      _seuilHorsRouteMetres) {
    debutRoute =
        _indexLePlusProche(points, snaps.first.projete, depuisLaFin: false);
  }
  if (_distanceMetres(parcours.last, snaps.last.projete) >
      _seuilHorsRouteMetres) {
    finRoute =
        _indexLePlusProche(points, snaps.last.projete, depuisLaFin: true);
  }
  if (finRoute - debutRoute < 1) {
    // Tracé minuscule entièrement hors route : tout garder coloré plutôt
    // que de ne rien afficher.
    debutRoute = 0;
    finRoute = points.length - 1;
  }

  return RouteResult(
    points: points,
    distanceMeters: distanceTotale,
    durationSeconds: coutTotal / 9.0,
    severites: severites,
    indexDebutRoute: debutRoute,
    indexFinRoute: finRoute,
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
  final facteur = _facteur(sev);

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
    dDebut * facteur,
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
    dFin * facteur,
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

(List<LatLng>, double, double, List<double>)? _dijkstra(
  _GrapheRoutes g,
  int depart,
  int arrivee,
  Map<int, Set<int>> jumeaux,
) {
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
      var penalite = _penaliteVirage(entree, arete);
      penalite += _penaliteChaussee(entree, arete, n, g, jumeaux);
      final nd = d + arete.cout + penalite;
      if (nd < (dist[arete.vers] ?? double.infinity)) {
        dist[arete.vers] = nd;
        precedent[arete.vers] = (n, arete);
        tas.ajouter(nd, arete.vers);
      }
    }
  }

  if (!dist.containsKey(arrivee)) return null;

  final troncons = <_Arete>[];
  var courant = arrivee;
  while (courant != depart) {
    final (source, arete) = precedent[courant]!;
    troncons.add(arete);
    courant = source;
  }

  var distanceTotale = 0.0;
  var coutTotal = 0.0;
  final points = <LatLng>[];
  final severites = <double>[];
  for (final arete in troncons.reversed) {
    distanceTotale += arete.longueurMetres;
    coutTotal += arete.cout;
    for (final p in arete.points) {
      // Les tronçons consécutifs se raccordent à quelques mètres près :
      // au-delà, on garde le point pour ne pas casser la ligne.
      if (points.isNotEmpty && _distanceMetres(points.last, p) < 3.0) {
        continue;
      }
      points.add(p);
      severites.add(arete.severite);
    }
  }

  final (pointsFinaux, severitesFinales) = _alleger(points, severites);
  return (pointsFinaux, distanceTotale, coutTotal, severitesFinales);
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
