import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geo.dart' show normaliserDegre;

/// Vue d'ensemble d'un itinéraire : calcul PUR du cadrage (centre, zoom,
/// rotation) qui présente la ligne verticalement, le point vert au-dessus du
/// point bleu. Aucun état, aucune animation : tout est modèle + unité
/// testable — les réglages de cadrage (marges, zoom min, ancrage) vivent ici.
class VueItineraireResultat {
  final LatLng centre;
  final double zoom;
  final double rotation;

  const VueItineraireResultat({
    required this.centre,
    required this.zoom,
    required this.rotation,
  });
}

/// Calcule le cadrage de la vue d'ensemble. Renvoie null pour les cas
/// dégénérés (moins de 2 points, coordonnées non finies, portée < 5 m, carte
/// pas encore dimensionnée) : l'appelant se rabat alors sur une animation
/// vers le point de départ.
VueItineraireResultat? calculerVueItineraire({
  required MapCamera camera,
  required List<LatLng> points,
  required int debutRoute,
  required int finRoute,
  double zoomMin = 11.0,
  double zoomMax = 19.0,
  double zoomPlancherAbsolu = 5.0,
  double margeGauche = 56.0,
  double margeDroite = 56.0,
  double margeHaut = 96.0,
  double margeBas = 48.0,
  double fractionBas = 2.0 / 3.0,
  double facteurRespiration = 0.88,
}) {
  if (points.length < 2) return null;

  final depart = points.first;
  final arrivee = points.last;
  final dLat = arrivee.latitude - depart.latitude;
  final dLon = arrivee.longitude - depart.longitude;
  if (!dLat.isFinite || !dLon.isFinite) return null;

  // Rotation qui redresse le tracé à la verticale, vert au-dessus du bleu
  // (même convention que le suivi de navigation).
  final capDeg = math.atan2(dLon, dLat) * 180.0 / math.pi;
  final rotation = normaliserDegre(-capDeg);

  // Portée trop courte : mieux vaut zooms sur le départ que cadrer un point.
  final cosLat =
      math.cos((depart.latitude + arrivee.latitude) * 0.5 * math.pi / 180);
  final porteeMetres = math.max(
    dLat.abs() * 111320,
    dLon.abs() * 111320 * cosLat,
  );
  if (porteeMetres < 5) return null;

  final taille = camera.nonRotatedSize;
  if (!taille.x.isFinite ||
      !taille.y.isFinite ||
      taille.x <= 0 ||
      taille.y <= 0) {
    return null;
  }

  // Points à cadrer : uniquement la portion SUR CHAUSSÉE [debutRoute..finRoute]
  // plus les deux extrémités (bleu/vert). Un point parasite loin de la
  // chaussée (secours OSRM, épingle lointaine, raccord hors route) élargirait
  // sinon la boîte englobante jusqu'au continent : la vue reste sur la ville.
  var debutCadre = 0;
  var finCadre = points.length - 1;
  if (finRoute - debutRoute + 1 >= 2) {
    debutCadre = debutRoute.clamp(0, points.length - 1);
    finCadre = finRoute.clamp(debutCadre, points.length - 1);
  }
  final aCadrer = <LatLng>[];
  void ajouterAuCadre(LatLng p) {
    if (aCadrer.isEmpty || aCadrer.last != p) aCadrer.add(p);
  }

  ajouterAuCadre(points.first);
  for (var i = debutCadre; i <= finCadre; i++) {
    ajouterAuCadre(points[i]);
  }
  ajouterAuCadre(points.last);

  // Garde-fou anti parasite : un point anormalement loin du tracé (raccord
  // hors route très long, fix GPS égaré, épingle lointaine) élargirait la
  // boîte englobante jusqu'à l'océan et le centre calculé partirait hors
  // carte. On retire du cadre tout point plus éloigné du segment droit
  // départ → arrivée que ~3 fois la portée du trajet (mini 3 km) : un tracé
  // urbain tortueux reste toujours dans cette enveloppe, un parasite situé à
  // des dizaines de kilomètres n'a aucune chance.
  final toleranceMetres = math.max(porteeMetres * 3.0, 3000.0);
  final aCadrerFiltre = <LatLng>[];
  for (final p in aCadrer) {
    if (_distanceAuSegmentMetres(p, depart, arrivee) <= toleranceMetres) {
      aCadrerFiltre.add(p);
    }
  }
  if (aCadrerFiltre.length < 2) return null;

  // Le point bleu est cloué au centre horizontal, aux deux tiers de la
  // hauteur visible : la même disposition que le recentrage « Ma position ».
  final w = taille.x;
  final h = taille.y;
  final ancrageX = w / 2.0;
  final ancrageY = h * fractionBas;
  final dxAncre = ancrageX - w / 2.0;
  final dyAncre = ancrageY - h / 2.0;

  final theta = rotation * math.pi / 180.0;
  final cosT = math.cos(theta);
  final sinT = math.sin(theta);

  double rotX(double x, double y) => x * cosT - y * sinT;
  double rotY(double x, double y) => x * sinT + y * cosT;
  double invRotX(double x, double y) => x * cosT + y * sinT;
  double invRotY(double x, double y) => -x * sinT + y * cosT;

  // Projection de chaque point relatif au départ, dans le repère écran
  // redressé : l'échelle de zoom est déduite des bornes ainsi obtenues.
  final zRef = camera.zoom;
  final projDepart = camera.project(points.first, zRef);
  var minSx = double.infinity;
  var maxSx = double.negativeInfinity;
  var minSy = double.infinity;
  var maxSy = double.negativeInfinity;
  for (final p in aCadrerFiltre) {
    final proj = camera.project(p, zRef);
    final dx = proj.x - projDepart.x;
    final dy = proj.y - projDepart.y;
    final sx = rotX(dx, dy);
    final sy = rotY(dx, dy);
    if (!sx.isFinite || !sy.isFinite) continue;
    if (sx < minSx) minSx = sx;
    if (sx > maxSx) maxSx = sx;
    if (sy < minSy) minSy = sy;
    if (sy > maxSy) maxSy = sy;
  }

  // Plus grande échelle qui garde tout le tracé dans la vue, le point bleu
  // restant cloué à son ancrage ; [facteurRespiration] pour respirer un peu.
  final contraintes = <double>[];
  if (minSy < 0) contraintes.add((margeHaut - ancrageY) / minSy);
  if (maxSy > 0) contraintes.add((h - margeBas - ancrageY) / maxSy);
  if (minSx < 0) contraintes.add((margeGauche - ancrageX) / minSx);
  if (maxSx > 0) contraintes.add((w - margeDroite - ancrageX) / maxSx);

  var echelle = contraintes.reduce(math.min) * facteurRespiration;
  if (!echelle.isFinite || echelle <= 0) echelle = 1.0;

  // Zoom final. [zoomMin] est le plancher des cadrages ordinaires, mais un
  // tracé trop long pour tenir dans la vue à ce zoom descend en dessous : la
  // vue d'ensemble doit montrer tout le tracé. Un plancher technique absolu
  // évite de basculer dans une vue « monde » ; [zoomMax] reste un plafond
  // technique absolu.
  final zoomBrut = zRef + math.log(echelle) / math.ln2;
  final zoom = (zoomBrut < zoomMin
          ? zoomBrut.clamp(zoomPlancherAbsolu, zoomMax)
          : zoomBrut.clamp(zoomMin, zoomMax))
      .toDouble();

  // Centre final : projeté du point bleu décalé en sens inverse, pour que le
  // bleu tombe exactement sur son ancrage (centré, deux tiers vers le bas).
  // [projDepart] est exprimé dans le repère du zoom de départ [zRef] : il doit
  // être remis à l'échelle du zoom FINAL retenu (×[echelleFinal] = 2^Δzoom),
  // et non à l'échelle brute [echelle] — quand le zoom a été plafonné, les
  // deux diffèrent d'un facteur qui, appliqué aux pixels mondiaux du point
  // bleu (des millions de pixels depuis l'origine mercator), enverrait le
  // centre calculé à des milliers de kilomètres du tracé.
  final echelleFinal = math.pow(2.0, zoom - zRef).toDouble();
  final centre = camera.unproject(
    math.Point<double>(
      projDepart.x * echelleFinal - invRotX(dxAncre, dyAncre),
      projDepart.y * echelleFinal - invRotY(dxAncre, dyAncre),
    ),
    zoom,
  );

  return VueItineraireResultat(centre: centre, zoom: zoom, rotation: rotation);
}

/// Distance perpendiculaire (en mètres) de [p] au segment [a]-[b], calculée
/// en projection équirectangulaire locale (négligeable sur des portées de
/// quelques kilomètres). Version bornée au segment : un point passé l'une des
/// extrémités est mesuré depuis cette extrémité.
double _distanceAuSegmentMetres(LatLng p, LatLng a, LatLng b) {
  const rayon = 111320.0;
  final cosLat = math.cos((a.latitude + b.latitude) * 0.5 * math.pi / 180);
  final bx = (b.longitude - a.longitude) * rayon * cosLat;
  final by = (b.latitude - a.latitude) * rayon;
  final px = (p.longitude - a.longitude) * rayon * cosLat;
  final py = (p.latitude - a.latitude) * rayon;
  final len2 = bx * bx + by * by;
  if (len2 <= 0) {
    final dx = p.longitude - a.longitude;
    final dy = p.latitude - a.latitude;
    final dlonM = dx * rayon * cosLat;
    final dlatM = dy * rayon;
    return math.sqrt(dlonM * dlonM + dlatM * dlatM);
  }
  final t = ((px * bx + py * by) / len2).clamp(0.0, 1.0);
  final dx = px - t * bx;
  final dy = py - t * by;
  return math.sqrt(dx * dx + dy * dy);
}