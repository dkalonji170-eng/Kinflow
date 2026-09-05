import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Seuil angulaire (degrés) : écart minimal entre le cap courant et le cap
/// de référence pour autoriser un recadrage de l'orientation de la carte.
const double seuilAngleDegres = 10.0;

/// Seuil spatial (mètres) : distance minimale parcourue depuis le dernier
/// recadrage pour autoriser le suivant. Empêche les recadrages en rafale
/// causés par le seul bruit du GPS à l'arrêt ou aux vitesses très faibles.
const double seuilDistanceMetres = 5.0;

/// Précision GPS maximale (mètres) pour que la position participe au calcul
/// de distance. Au-delà, le bruit seul peut simuler un déplacement de 5 m
/// et déclencher un faux recadrage : la position est alors ignorée.
const double precisionGpsMaxMetres = 25.0;

/// Normalise un angle en degrés dans [0°, 360°).
double normaliserDegres(double degres) {
  final r = degres % 360.0;
  return r < 0 ? r + 360.0 : r;
}

/// Différence angulaire circulaire SIGNÉE de [de] vers [vers], dans
/// (-180°, +180°]. Le passage 359° -> 1° donne +2° et non -358° :
/// on ne compare jamais naïvement deux caps bruts.
double differenceAngulaireDegres(double de, double vers) {
  var d = (vers - de) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d <= -180.0) d += 360.0;
  return d;
}

/// Distance géodésique entre deux points (formule de Haversine), en mètres.
/// Une soustraction simple des latitudes/longitudes est incorrecte car un
/// degré de longitude rétrécit avec la latitude.
double distanceHaversineMetres(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const rayonTerreMetres = 6371000.0;
  final phi1 = lat1 * math.pi / 180.0;
  final phi2 = lat2 * math.pi / 180.0;
  final dPhi = (lat2 - lat1) * math.pi / 180.0;
  final dLambda = (lon2 - lon1) * math.pi / 180.0;
  final a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(phi1) *
          math.cos(phi2) *
          math.sin(dLambda / 2) *
          math.sin(dLambda / 2);
  return 2 * rayonTerreMetres * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Filtre passe-bas circulaire du cap : moyenne vectorielle exponentielle.
///
/// Une moyenne arithmétique classique est FAUSSE sur les angles : la moyenne
/// de 359° et 1° donnerait 180° au lieu de ~0°. On moyenne donc les vecteurs
/// unités (sin, cos) puis on revient à l'angle par atan2 — ce qui gère
/// naturellement la continuité autour du nord.
class FiltreCap {
  FiltreCap({this.raideur = 0.25});

  /// Poids de chaque nouvelle mesure (0..1). Petit = filtrage fort mais
  /// réponse lente ; grand = réactivité immédiate mais bruit visible.
  final double raideur;

  double _x = 0; // composante Est du vecteur moyen
  double _y = 0; // composante Nord du vecteur moyen
  bool _initialise = false;

  /// Cap filtré courant en degrés [0°, 360°), ou null avant la 1re mesure.
  double? get valeur {
    if (!_initialise) return null;
    return normaliserDegres(math.atan2(_x, _y) * 180.0 / math.pi);
  }

  void ajouter(double capDegres) {
    if (capDegres.isNaN || capDegres.isInfinite || capDegres < 0) {
      // Cap invalide (GPS immobile renvoie souvent -1) : ignoré.
      return;
    }
    final rad = capDegres * math.pi / 180.0;
    final sx = math.sin(rad);
    final sy = math.cos(rad);
    if (!_initialise) {
      _x = sx;
      _y = sy;
      _initialise = true;
      return;
    }
    final a = raideur.clamp(0.0, 1.0);
    var nx = _x + (sx - _x) * a;
    var ny = _y + (sy - _y) * a;
    final norme = math.sqrt(nx * nx + ny * ny);
    // Vecteurs quasi opposites (cap oscillant à 180° près, typique d'un
    // signal dégradé) : conserver l'état précédent plutôt qu'un angle
    // arbitraire.
    if (norme < 1e-3) return;
    _x = nx / norme;
    _y = ny / norme;
  }

  void reinitialiser() {
    _x = 0;
    _y = 0;
    _initialise = false;
  }
}

/// Contrôleur d'orientation navigation : système événementiel à DOUBLE SEUIL
/// qui décide quand la carte doit se réorienter (direction de déplacement
/// remise vers le haut).
///
/// Fenêtre glissante : après chaque recadrage, le cap ET la position servis
/// deviennent la nouvelle référence. Les seuils suivants (>= [seuilAngleDegres]
/// ET >= [seuilDistanceMetres]) sont mesurés depuis CE nouveau référentiel,
/// pas depuis une direction initiale fixe — sinon une accumulation lente
/// de petits virages déclencherait des recadrages permanents.
///
/// Entrées attendues : UNE mise à jour PAR MESURE GPS (pas par frame),
/// cap déjà restreint côté écran à la course réelle (vitesse >= 1 m/s).
class ControleurOrientation {
  final FiltreCap _filtreCap = FiltreCap();

  /// referenceHeading : cap filtré ayant servi au dernier recadrage.
  double? _capReference;

  /// referencePosition : position GPS correspondant au dernier recadrage.
  LatLng? _positionReference;

  /// Cap filtré courant (diagnostic / affichage).
  double? get capFiltre => _filtreCap.valeur;

  /// Cap de référence courant (diagnostic / affichage).
  double? get capReference => _capReference;

  /// Dernier delta angulaire mesuré depuis la référence (degrés absolus).
  double get deltaAngulaire {
    final ref = _capReference;
    final cap = _filtreCap.valeur;
    if (ref == null || cap == null) return 0;
    return differenceAngulaireDegres(ref, cap).abs();
  }

  /// Traite une nouvelle mesure GPS.
  ///
  /// [capBrutDegres] : cap brut de déplacement (course GPS, 0 = Nord).
  /// [position] : position courante. [precisionMetres] : précision horizontale
  /// déclarée par le GPS ; si elle dépasse [precisionGpsMaxMetres], la
  /// composante DISTANCE du test n'est plus validable (bruit > seuil réel).
  ///
  /// Retourne la rotation cible de la carte (en degrés, prête pour la caméra)
  /// SI le recadrage se déclenche, sinon null.
  double? mettreAJour({
    required double capBrutDegres,
    required LatLng position,
    required double precisionMetres,
  }) {
    _filtreCap.ajouter(capBrutDegres);
    final capFiltre = _filtreCap.valeur;
    if (capFiltre == null) return null;

    final reference = _capReference;
    if (reference == null) {
      // Premier cap exploitable de la session : alignement immédiat et pose
      // du référentiel initial (cap + position).
      return _recadrer(capFiltre, position);
    }

    final delta = differenceAngulaireDegres(reference, capFiltre).abs();

    // Composante distance : validée seulement si le GPS est assez précis
    // pour distinguer 5 m réels du bruit de mesure.
    var distanceOk = false;
    if (precisionMetres <= precisionGpsMaxMetres &&
        _positionReference != null) {
      final ref = _positionReference!;
      distanceOk = distanceHaversineMetres(
            ref.latitude,
            ref.longitude,
            position.latitude,
            position.longitude,
          ) >=
          seuilDistanceMetres;
    }

    if (delta < seuilAngleDegres || !distanceOk) return null;
    return _recadrer(capFiltre, position);
  }

  /// Recadrage : la carte pivote vers le cap courant et ce couple
  /// (cap, position) devient la nouvelle référence. Le suivi repart de zéro :
  /// c'est l'hystérésis qui empêche les recadrages en cascade.
  double _recadrer(double capFiltre, LatLng position) {
    _capReference = normaliserDegres(capFiltre);
    _positionReference = position;
    // La rotation caméra est l'opposé du cap : direction vers le haut.
    return normaliserDegres(-capFiltre);
  }

  /// Réinitialisation complète (entrée/sortie du mode navigation) : le
  /// prochain cap valide réalignera la carte immédiatement.
  void reinitialiser() {
    _filtreCap.reinitialiser();
    _capReference = null;
    _positionReference = null;
  }
}
