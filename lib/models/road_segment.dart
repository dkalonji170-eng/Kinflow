import 'package:latlong2/latlong.dart';

class RoadSegment {
  final int id;
  final String nom;
  final String classe;
  final List<LatLng> points;

  const RoadSegment({
    required this.id,
    required this.nom,
    required this.classe,
    required this.points,
  });
}
