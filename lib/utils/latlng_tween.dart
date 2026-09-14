// Interpolation linéaire entre deux points LatLng pour les animations de
// caméra. Extraite de `traffic_map.dart` pour être réutilisable.
import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

class LatLngTween extends Tween<LatLng> {
  LatLngTween({super.begin, super.end});

  @override
  LatLng lerp(double t) {
    final b = begin!;
    final e = end!;
    return LatLng(
      b.latitude + (e.latitude - b.latitude) * t,
      b.longitude + (e.longitude - b.longitude) * t,
    );
  }
}