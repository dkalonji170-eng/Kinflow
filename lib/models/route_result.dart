import 'package:latlong2/latlong.dart';

class RouteResult {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  /// Sévérité du trafic (0 = fluide .. 3 = bloquée) associée à chaque point
  /// de [points], connue uniquement pour le calcul local (null en repli OSRM).
  final List<double>? severites;

  /// Index du premier point de [points] posé sur la chaussée : la ligne
  /// colorée ne commence qu'à partir de lui. Les points précédents relient
  /// le point réel de départ (bâtiment, cour…) à la route et sont dessinés
  /// en pointillés. 0 par défaut (départ directement sur la route).
  final int indexDebutRoute;

  /// Index du dernier point de [points] posé sur la chaussée ; les points
  /// suivants rejoignent l'arrivée réelle en pointillés. -1 = le dernier
  /// point (arrivée directement sur la route).
  final int indexFinRoute;

  /// Identifiants (id OSM) des segments de circulation empruntés par le
  /// tracé bleu → vert (ordonnancement libre). Renseigné par le moteur
  /// local : la carte affiche l'itinéraire en sélectionnant EXACTEMENT ces
  /// polylignes colorées déjà chargées et en masquant toutes les autres.
  /// Vide (repli OSRM) : la carte se rabat sur [points].
  final List<int> segmentsIds;

  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.severites,
    this.indexDebutRoute = 0,
    this.indexFinRoute = -1,
    this.segmentsIds = const [],
  });

  /// Borne de début de la portion routée (colorée), toujours valide.
  int get debutRoute => indexDebutRoute.clamp(0, points.length - 1).toInt();

  /// Borne de fin de la portion routée (colorée), toujours valide.
  int get finRoute =>
      (indexFinRoute < 0 ? points.length - 1 : indexFinRoute)
          .clamp(debutRoute, points.length - 1)
          .toInt();
}
