import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart' show LatLng;

/// Constantes partagées de la carte, communes à l'écran principal et au
/// widget de carte : zoom minimum et vue « Afrique » d'attente.

/// Zoom le plus bas autorisé. En dessous, la carte ne charge ni tuiles ni
/// polylignes : elle reste désespérément vide et le zoom n'apporte rien à
/// l'utilisateur.
const double zoomMinGlobal = 8.0;

/// Bornes de la vue « Afrique » affichée tant qu'aucune position n'est connue.
final LatLngBounds bornesAfrique = LatLngBounds(
  const LatLng(-35.0, -18.0),
  const LatLng(37.5, 52.0),
);