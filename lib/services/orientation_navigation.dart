import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Seuil angulaire (degrés) : écart minimal entre le cap de référence et le
/// cap courant pour déclencher un recadrage de la carte.
///
/// 12° : la carte se redresse dès qu'un virage est réellement amorcé, sans
/// suivre le bruit d'un GPS qui « cherche » sa route en ligne droite (les
/// oscillations usuelles de cap, ±10°, restent sous ce seuil après filtrage).
const double seuilAngleDegres = 12.0;

/// Seuil de STABILISATION (degrés) : écart maximal entre deux caps bruts
/// consécutifs pour considérer que le virage est terminé.
///
/// C'est la pièce maîtresse du comportement attendu : tant que le cap bouge
/// (virage en cours), la carte ne tourne pas. Dès que le cap se stabilise,
/// elle pivote d'un seul geste vers la direction finale. Sans ce test, une
/// carte pivoterait à chaque mesure pendant tout le virage, ce qui donnait
/// exactement la succession de « petits tours » que l'on veut éviter.
///
/// Abaissé de 12° à 9° : le virage est reconnu comme terminé un peu plus tôt,
/// donc la carte se redresse plus près du coin.
const double seuilStabilisationDegres = 9.0;

/// Seuil de FORÇAGE (degrés) : au-delà de cet écart accumulé depuis la
/// référence, on pivote même si le cap bouge encore. Évite qu'un très long
/// virage (échangeur, rond-point) laisse la carte désalignée pendant des
/// dizaines de mètres. Abaissé de 70° à 50° pour raccourcir ce délai.
const double seuilAngleForceDegres = 50.0;

/// Seuil spatial (mètres) : distance minimale parcourue depuis le dernier
/// recadrage pour autoriser le suivant. Empêche les recadrages en rafale
/// causés par le seul bruit du GPS à l'arrêt ou aux vitesses très faibles.
/// Ramené de 4 à 3 m : la carte peut se réorienter plus tôt après un virage.
const double seuilDistanceMetres = 3.0;

/// Précision GPS de RÉFÉRENCE (mètres). Elle sert de borne haute à la
/// majoration du seuil de distance : au-delà de cette imprécision, exiger
/// davantage de mètres n'apporte plus rien (on ne distinguerait plus un vrai
/// déplacement d'un bruit), on plafonne donc la majoration.
///
/// À ne PAS confondre avec une désactivation du test : couper purement le
/// recadrage dès que la précision se dégrade laissait la carte désalignée
/// pendant des dizaines de mètres après un virage (voir [ControleurOrientation]).
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
  final a =
      math.sin(dPhi / 2) * math.sin(dPhi / 2) +
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
  FiltreCap({this.raideur = 0.6});

  /// Poids de chaque nouvelle mesure (0..1). Petit = filtrage fort mais
  /// réponse lente ; grand = réactivité immédiate mais bruit visible.
  ///
  /// 0,6 : après un virage, le cap filtré a déjà parcouru 60 % de l'écart en
  /// une mesure, ce qui permet de DÉTECTER le virage sur la mesure suivante
  /// au lieu d'attendre que le filtre converge lentement (cette convergence
  /// progressive était la cause des « petits tours » successifs).
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
    // Vecteurs quasi opposés (cap oscillant à 180° près, typique d'un
    // signal dégradé) : conserver l'état précédent plutôt qu'un angle
    // arbitraire.
    if (norme < 1e-3) return;
    _x = nx / norme;
    _y = ny / norme;
  }

  /// Force le filtre sur [capDegres] sans passer par le lissage.
  ///
  /// Appelé au moment d'un recadrage : la carte pivote vers le cap COURANT
  /// (et non vers un cap filtré encore en retard), donc la rotation est
  /// complète d'un seul geste. Le filtre repart de cette direction, ce qui
  /// évite qu'il « rattrape » ensuite son retard en déclenchant une deuxième
  /// puis une troisième petite rotation.
  void forcer(double capDegres) {
    final rad = normaliserDegres(capDegres) * math.pi / 180.0;
    _x = math.sin(rad);
    _y = math.cos(rad);
    _initialise = true;
  }

  void reinitialiser() {
    _x = 0;
    _y = 0;
    _initialise = false;
  }
}

/// Contrôleur d'orientation navigation : décide QUAND la carte doit se
/// réorienter (direction de déplacement remise vers le haut) et vers quel cap.
///
/// Principe — c'est le cœur du comportement attendu :
///
///  1. tant que le cap BOUGE (virage en cours), la carte ne tourne pas ;
///  2. dès que le cap s'est STABILISÉ (deux mesures proches), la carte pivote
///     en une seule fois vers la direction finale, même si le virage est de
///     90° ou 180° ;
///  3. entre deux virages, la rotation est totalement figée.
///
/// Ce fonctionnement s'oppose volontairement à un asservissement continu, qui
/// « corrigeait » la carte à chaque mètre parcouru : c'est lui qui produisait
/// la succession de petits tours pendant un virage.
///
/// Fenêtre glissante : après chaque recadrage, le cap ET la position servis
/// deviennent la nouvelle référence. Les seuils sont mesurés depuis CE
/// référentiel, pas depuis une direction initiale fixe.
///
/// Entrées attendues : UNE mise à jour PAR MESURE GPS (pas par frame).
class ControleurOrientation {
  ControleurOrientation({
    this.seuilAngle = seuilAngleDegres,
    this.seuilDistance = seuilDistanceMetres,
  });

  /// Écart angulaire minimal (degrés) pour envisager un recadrage.
  final double seuilAngle;

  /// Déplacement minimal (mètres) depuis le dernier recadrage.
  final double seuilDistance;

  final FiltreCap _filtreCap = FiltreCap();

  /// Cap brut de la mesure précédente : sert au test de stabilisation.
  double? _capBrutPrecedent;

  /// Cap ayant servi au dernier recadrage.
  double? _capReference;

  /// Position GPS correspondant au dernier recadrage.
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
  /// déclarée par le GPS ; elle majore la distance exigée (un GPS imprécis
  /// doit « prouver » davantage de déplacement), sans jamais désactiver le
  /// recadrage.
  ///
  /// Retourne la rotation cible de la carte (en degrés, prête pour la caméra)
  /// SI un recadrage se déclenche, sinon null.
  double? mettreAJour({
    required double capBrutDegres,
    required LatLng position,
    required double precisionMetres,
  }) {
    if (capBrutDegres.isNaN || capBrutDegres.isInfinite || capBrutDegres < 0) {
      return null;
    }
    _filtreCap.ajouter(capBrutDegres);
    final capFiltre = _filtreCap.valeur;
    if (capFiltre == null) return null;

    final precedent = _capBrutPrecedent;
    _capBrutPrecedent = capBrutDegres;

    final reference = _capReference;
    if (reference == null) {
      // Aucune référence posée à l'entrée du suivi : premier cap exploitable
      // de la session, alignement immédiat et pose du référentiel initial.
      return _recadrer(capBrutDegres, position);
    }

    if (_positionReference == null) {
      // La référence angulaire a déjà été posée par la rotation affichée à
      // l'entrée du suivi (vue d'ensemble d'un itinéraire, par exemple) :
      // la première mesure ne fait que poser l'origine du test de distance.
      _positionReference = position;
      return null;
    }

    final delta = differenceAngulaireDegres(reference, capFiltre).abs();

    // Composante distance : la distance exigée dépend de l'angle :
    //  - virage franc (>= 45°) : 1,5 m suffisent, l'information est peu
    //    ambiguë et attendre ferait rater le moment du virage ;
    //  - virage moyen (>= 30°) : 3 m ;
    //  - petit écart (12–30°) : 6 m, car à cette amplitude le bruit de cap
    //    d'un GPS à pied peut facilement simuler un virage.
    final distanceBase = delta >= 45.0
        ? 1.5
        : delta >= 30.0
        ? seuilDistance
        : seuilDistance * 2;
    // Majoration liée à l'imprécision GPS : un point annoncé à ±20 m peut
    // « sauter » de 20 m sans que l'utilisateur ait bougé. Plus le GPS est
    // imprécis, plus la distance EXIGÉE grandit — mais le test n'est jamais
    // désactivé : couper le recadrage dès que la précision dépasse 25 m
    // (courant en ville, sous les arbres) laissait la carte mal alignée sur
    // des dizaines de mètres après chaque virage. On plafonne la majoration
    // à 40 % de [precisionGpsMaxMetres] pour que le seuil reste franchissable
    // même avec un signal médiocre, tout en réagissant plus tôt (0,35 au lieu
    // de 0,5 auparavant).
    final majorationPrecision = (precisionMetres * 0.35)
        .clamp(0.0, precisionGpsMaxMetres * 0.4)
        .toDouble();
    final distanceRequise = distanceBase + majorationPrecision;
    final ref = _positionReference!;
    final distanceOk =
        distanceHaversineMetres(
          ref.latitude,
          ref.longitude,
          position.latitude,
          position.longitude,
        ) >=
        distanceRequise;

    if (delta < seuilAngle || !distanceOk) return null;

    // Le cap est-il stabilisé ? Tant que le cap BRUT continue de tourner, on
    // attend : pivoter maintenant ne serait qu'une étape d'un virage encore
    // en cours, donc un « petit tour » de plus. C'est ce test qui fait que la
    // carte se redresse d'un bloc à la FIN du virage, et non progressivement.
    final variation = precedent == null
        ? double.infinity
        : differenceAngulaireDegres(precedent, capBrutDegres).abs();
    final stabilise = variation <= seuilStabilisationDegres;
    // Exception : virage très prononcé qui n'en finit pas (échangeur,
    // rond-point). On ne laisse pas la carte désalignée indéfiniment.
    final force = delta >= seuilAngleForceDegres;

    if (!stabilise && !force) return null;
    // Le cap est stabilisé : on pivote vers le cap BRUT courant (et non vers
    // le cap filtré, encore en retard de plusieurs dizaines de degrés). La
    // rotation est ainsi complète du premier coup ; le filtre est recalé
    // dessus par [_recadrer] pour ne pas rejouer ce retard ensuite.
    return _recadrer(capBrutDegres, position);
  }

  /// Recadrage : la carte pivote vers [capCible] (le cap brut courant, et non
  /// le cap filtré encore en retard) et ce couple (cap, position) devient la
  /// nouvelle référence. Le filtre est recalé sur ce cap pour que la rotation
  /// soit complète et définitive — sans quoi le filtre, encore en retard,
  /// provoquerait une deuxième puis une troisième petite rotation dans les
  /// mesures suivantes.
  double _recadrer(double capCible, LatLng position) {
    final cap = normaliserDegres(capCible);
    _filtreCap.forcer(cap);
    _capReference = cap;
    _positionReference = position;
    _capBrutPrecedent = cap;
    // La rotation caméra est l'opposé du cap : direction vers le haut.
    return normaliserDegres(-cap);
  }

  /// Réinitialisation complète (entrée/sortie du mode navigation).
  ///
  /// Si [rotationInitialeDegres] est fournie (la rotation affichée par la
  /// caméra), elle devient la référence angulaire : le prochain cap NE
  /// réaligne plus la carte d'un coup — seul un vrai virage la fera pivoter.
  /// Sans elle, le premier cap valide réaligne immédiatement (bouton
  /// « Ma position » sans itinéraire).
  void reinitialiser({double? rotationInitialeDegres}) {
    _filtreCap.reinitialiser();
    _capBrutPrecedent = null;
    _capReference = rotationInitialeDegres == null
        ? null
        : normaliserDegres(-rotationInitialeDegres);
    _positionReference = null;
  }
}
