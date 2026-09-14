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

  // Pointillés noirs de raccord : quand le point de départ ou d'arrivée tombe
  // hors chaussée, la portion qui le relie à la route est dessinée en
  // pointillés, comme chez Yango. Seuls les raccords encore visibles (pas
  // encore parcourus pendant le suivi réel) sont émis.
  const epaisseurPointilles = 3.2;
  final couleurPointilles =
      Colors.black.withValues(alpha: fondSombre ? 0.95 : 0.8);
  // Raccord de départ visible uniquement tant que rien n'a été masqué
  // derrière l'utilisateur (debutVisuel == 0) : sinon il serait déjà derrière
  // lui.
  if (debutVisuelBorne == 0 && debutRoute > 0) {
    polylignes.insert(
      0,
      Polyline(
        points: points.sublist(0, debutRoute + 1),
        strokeWidth: epaisseurPointilles,
        color: couleurPointilles,
        pattern: StrokePattern.dotted(),
        strokeCap: StrokeCap.round,
      ),
    );
  }
  if (finRoute < fin && finRoute >= debutVisuelBorne) {
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

  return polylignes;
}