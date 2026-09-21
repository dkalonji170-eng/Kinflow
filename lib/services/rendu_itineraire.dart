import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../models/road_segment.dart';
import 'severite.dart';
import 'traffic_simulator.dart';
import 'traffic_stats_service.dart';

/// Rendu de la ligne d'itinéraire : découpage tronçon par tronçon en
/// polylignes colorées (mêmes couleurs que les rues) avec raccords de départ
/// / arrivée hors chaussée en POINTILLÉS NOIRS. Fonction pure alimentée par
/// le widget de carte (zones, simulateur, fond) : toutes les retouches
/// visuelles (épaisseurs, alpha, pointillés) se font ici.

typedef ZonePourPoint = ZoneTrafic? Function(LatLng point);

/// La ligne de l'itinéraire calculé, colorée tronçon par tronçon avec les
/// mêmes couleurs que les rues : la sévérité calculée par le moteur local
/// pour chaque tronçon (classe de rue + zones signalées) transmise via
/// [severites], ou à défaut l'état simulé générique puis les zones couvertes.
/// Itinéraire : UNE seule ligne, épaisseur constante, dont la couleur suit
/// l'état des routes tronçon par tronçon. Les transitions de couleur sont
/// jointes par des caps ronds pour rester un tracé unique et continu. La
/// couleur ne couvre QUE la portion sur chaussée [debutRoute..finRoute] : un
/// départ ou une arrivée hors route est raccordé par des pointillés noirs,
/// jamais par la couleur elle-même.
List<Polyline> decouperItineraireParEtat({
  required List<LatLng> points,
  required int debutRoute,
  required int finRoute,
  required int debutVisuel,
  required bool fondSombre,
  required List<double>? severites,
  required TrafficSimulator simulateur,
  required ZonePourPoint zonePourPoint,
  LatLng? departAncre,
  DateTime? moment,
}) {
  if (points.length < 2) return const [];

  final maintenant = moment ?? DateTime.now();
  final baseOpacite = fondSombre ? 0.9 : 0.8;
  const epaisseur = 6.0;

  // Borne de la portion encore visible pendant le suivi réel.
  final fin = points.length - 1;
  final debutVisuelBorne = debutVisuel.clamp(0, fin).toInt();

  // La portion routée visible : intersection de la chaussée avec ce qui
  // n'est pas encore parcouru pendant le suivi réel.
  var debutColore = debutVisuelBorne > debutRoute ? debutVisuelBorne : debutRoute;
  var finColore = finRoute < fin ? finRoute : fin;
  if (finColore - debutColore + 1 < 2) {
    // Borne incohérente (micro-tracé, suivi en fin de parcours) : repli sur
    // tout ce qui est encore visible, sans décrochage pointillé.
    debutColore = debutVisuelBorne;
    finColore = fin;
  }

  final pointsRoute = points.sublist(debutColore, finColore + 1);
  if (pointsRoute.length < 2) return const [];

  final severitesRoute =
      severites != null && severites.length == points.length
          ? severites.sublist(debutColore, finColore + 1)
          : null;
  final severiteParPoint =
      severitesRoute != null && severitesRoute.length == pointsRoute.length;

  final segment = RoadSegment(
    id: -1,
    nom: '',
    classe: 'primary',
    points: pointsRoute,
  );
  final simEtat = simulateur.estimer(segment, moment: maintenant);

  ({Color couleur, double opacite}) attribut(int i) {
    Color base;
    if (severiteParPoint) {
      base = couleurSeverite(severitesRoute[i]);
    } else {
      base = simEtat.couleur;
    }
    final milieu = LatLng(
      (pointsRoute[i].latitude + pointsRoute[i + 1].latitude) / 2,
      (pointsRoute[i].longitude + pointsRoute[i + 1].longitude) / 2,
    );
    final zone = zonePourPoint(milieu);
    if (zone == null) {
      return (couleur: base, opacite: baseOpacite);
    }
    // Même fusion que les rues : fiabilité faible → on se rapproche de l'état
    // simulé, un signalement isolé ne noircit pas tout le tracé.
    final f = zone.fiabilite.clamp(0.0, 1.0);
    return (
      couleur: Color.lerp(base, zone.etat.couleur, f)!,
      opacite: (0.35 + 0.65 * f).clamp(0.0, 1.0),
    );
  }

  // L'itinéraire est UNE seule ligne, épaisseur constante, dont la couleur
  // suit l'état des routes tronçon par tronçon. Aucun contour : les
  // polylignes de trafic étant masquées pendant l'itinéraire, le tracé n'a
  // besoin d'aucun liseré pour se détacher.
  final polylignes = <Polyline>[];
  var courant = <LatLng>[pointsRoute.first];
  var couleur = simEtat.couleur;
  var opacite = baseOpacite;

  void fermer() {
    if (courant.length >= 2) {
      polylignes.add(Polyline(
        points: List.of(courant),
        strokeWidth: epaisseur,
        color: couleur.withValues(alpha: opacite.clamp(0.0, 1.0)),
        // Caps ronds : les tronçons colorés se recouvrent aux transitions
        // sans laisser voir le contour, la ligne reste unique et continue.
        strokeCap: StrokeCap.round,
        strokeJoin: StrokeJoin.round,
      ));
    }
  }

  for (var i = 0; i < pointsRoute.length - 1; i++) {
    final a = attribut(i);
    if (a.couleur != couleur || a.opacite != opacite) {
      fermer();
      courant = <LatLng>[pointsRoute[i]];
      couleur = a.couleur;
      opacite = a.opacite;
    }
    courant.add(pointsRoute[i + 1]);
  }
  fermer();

  const epaisseurPointilles = 3.2;
  final couleurPointilles =
      Colors.black.withValues(alpha: fondSombre ? 0.95 : 0.8);

  // Pointillés noirs de l'ARRIVÉE : quand la destination tombe hors chaussée,
  // la portion qui la relie à la route est dessinée en pointillés, comme chez
  // Yango. Seul le raccord d'arrivée est émis ici : celui du DÉPART vit dans
  // construireRaccordDepart(), car il doit suivre la position bleue en direct.
  // Si la destination est trop éloignée (> 500 m), le long pointillé n'a plus
  // de sens visuel : on ne le trace pas.
  if (finRoute < fin && finRoute >= debutVisuelBorne) {
    final roadEnd = points[finRoute];
    final destination = points[fin];
    final distanceHorsRoute = const Distance().distance(roadEnd, destination);
    if (distanceHorsRoute <= _distanceMaxRaccordArriveeMetres) {
      polylignes.add(
        Polyline(
          points: points.sublist(finRoute, fin + 1),
          strokeWidth: epaisseurPointilles,
          color: couleurPointilles,
          pattern: StrokePattern.dotted(),
          strokeCap: StrokeCap.round,
        ),
      );
    }
  }

  return polylignes;
}

/// Au-delà de cette distance de la position bleue vivante au point d'ancrage
/// de l'itinéraire, le départ est jugé hors chaussée : un raccord en
/// pointillés noirs est dessiné. Voulu plus tolérant que la borne du moteur :
/// ces pointillés-là suivent le point bleu EN DIRECT, là où le GPS le pose
/// (même un saut dans la parcelle), sans attendre le prochain recalcul.
const double _seuilRaccordDepartMetres = 18;

/// Distance maximale (en mètres) entre la dernière portion routée et la
/// destination pour que le raccord d'arrivée en pointillés noirs soit dessiné.
/// Au-delà (destination très éloignée du réseau cartographié, point sauvage),
/// le long pointillé n'a plus de sens et encombre la vue : on ne le trace pas.
const double _distanceMaxRaccordArriveeMetres = 500;

/// Raccords en POINTILLÉS NOIRS qui relient la position bleue vivante à la
/// chaussée quand l'itinéraire commence hors route (bâtiment, parcelle).
/// Simple modèle visuel — PAS une route — montrant qu'il faut aller jusqu'à
/// la chaussée. Émis uniquement tant que rien du départ n'a été parcouru
/// ([debutVisuel] == 0) et tant que le point bleu reste éloigné de la route.
///
/// - [departAncre] fourni (GPS vivant) : droite [departAncre → roadStart], à
///   jour à chaque fix — le point bleu saute, les pointillés sautent avec lui.
/// - Sans [departAncre] : on retombe sur le raccord calculé (portion hors
///   route du tracé), borné par la décision du moteur ([debutRoute] > 0).
List<Polyline> construireRaccordDepart({
  required List<LatLng> points,
  required int debutRoute,
  required int debutVisuel,
  required bool fondSombre,
  LatLng? departAncre,
}) {
  if (points.length < 2) return const [];
  if (debutVisuel > 0) return const [];
  final roadStart = points[debutRoute.clamp(0, points.length - 1)];
  const epaisseurPointilles = 3.2;
  final couleurPointilles =
      Colors.black.withValues(alpha: fondSombre ? 0.95 : 0.8);

  if (departAncre == null) {
    // Aucune position vivante : raccord statique du tracé calculé, émis
    // seulement si le moteur a jugé le départ hors route.
    if (debutRoute <= 0) return const [];
    return [
      Polyline(
        points: points.sublist(0, debutRoute + 1),
        strokeWidth: epaisseurPointilles,
        color: couleurPointilles,
        pattern: StrokePattern.dotted(),
        strokeCap: StrokeCap.round,
      ),
    ];
  }

  final distance = const Distance().distance(departAncre, roadStart);
  if (distance <= _seuilRaccordDepartMetres) return const [];
  return [
    Polyline(
      points: <LatLng>[departAncre, roadStart],
      strokeWidth: epaisseurPointilles,
      color: couleurPointilles,
      pattern: StrokePattern.dotted(),
      strokeCap: StrokeCap.round,
    ),
  ];
}