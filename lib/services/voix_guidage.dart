import 'package:flutter/foundation.dart'
    show visibleForTesting;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geo.dart' show capTrace, deltaRotation, distanceMetres;

/// Type de virage détecté sur le tracé.
enum TypeVirage { gauche, droite, demiTour }

/// Un point du tracé où la direction change nettement (> 30°), avec l'index
/// du point-vertex dans la polyligne de l'itinéraire.
class Manoeuvre {
  final int index;
  final TypeVirage type;

  /// Valeur absolue du changement de cap en degrés : sert à départager deux
  /// virages très proches (on garde le plus marqué).
  final double ampleur;

  const Manoeuvre({
    required this.index,
    required this.type,
    required this.ampleur,
  });
}

/// Guidage vocal d'un itinéraire : analyse la géométrie du tracé pour
/// transformer les changements de cap en instructions parlées simples —
/// « Dans 300 mètres, tournez à gauche », « Vous êtes arrivé à destination ».
///
/// Totalement optionnel et silencieux tant qu'aucun itinéraire n'est affiché.
/// Si le synthétiseur est indisponible (pas d'API de voix sur la plateforme),
/// le guidage se neutralise tout seul sans jamais faire planter l'app.
class VoixGuidage {
  // Distances d'annonce (mètres restants avant le virage) et d'arrivée.
  static const double _seuilAnnonceLoinMetres = 300;
  static const double _seuilAnnonceMoyenMetres = 100;
  static const double _seuilAnnonceProcheMetres = 50;
  static const double _seuilArriveeMetres = 30;

  // Un virage est retenu quand le cap change d'au moins 30°.
  static const double _seuilVirageDegres = 30;

  // Fenêtre d'échantillonnage des caps (mètres) : on ne compare jamais deux
  // points voisins (bruit), mais deux points séparés par cette distance.
  static const double _fenetreCapsMetres = 22;

  // Deux virages détectés à moins de cette distance : on ne garde que le plus
  // marqué (le zigzag d'un même carrefour).
  static const double _seuilFusionViragesMetres = 25;

  FlutterTts? _tts;
  bool _disponible = false;

  List<LatLng> _points = const [];
  List<Manoeuvre> _manoeuvres = const [];

  /// Index (dans [_manoeuvres]) de la prochaine instruction à passer.
  int _indexProchain = 0;

  /// Niveau d'annonce déjà prononcé pour le virage courant
  /// (-1 = rien, 0 = 300 m, 1 = 100 m, 2 = imminent). La progression est
  /// monotone : on ne répète jamais deux fois la même distance.
  int _niveauAnnonce = -1;

  /// Vrai quand « Vous êtes arrivé à destination » a déjà été dit.
  bool _arriveeAnnoncee = false;

  /// Vrai tant qu'un itinéraire est affiché : la voix peut parler.
  bool _guidageActif = false;

  VoixGuidage() {
    try {
      _tts = FlutterTts();
    } catch (_) {
      _tts = null;
    }
  }

  /// Prépare le guidage pour un nouveau tracé (à appeler à chaque fois qu'un
  /// itinéraire est affiché ou remplacé) : recalcule les virages et remet les
  /// niveaux d'annonce à zéro.
  Future<void> preparer(List<LatLng> points) async {
    _points = List.of(points);
    _manoeuvres = calculerManoeuvres(_points);
    _indexProchain = 0;
    _niveauAnnonce = -1;
    _arriveeAnnoncee = false;
    _guidageActif = true;
    if (!_disponible) {
      await _initialiser();
    }
  }

  /// Coupe le guidage (itinéraire annulé, écran fermé) et arrête toute voix
  /// en cours.
  void arreter() {
    _guidageActif = false;
    final tts = _tts;
    if (tts == null) return;
    try {
      tts.stop();
    } catch (_) {
      // synthétiseur indisponible : ignoré
    }
  }

  /// Fait avancer le raisonnement avec une nouvelle position le long du
  /// tracé. [indexCourant] est l'index du point de l'itinéraire le plus
  /// proche de la position (calculé par la carte à chaque fix GPS accepté).
  void raisonner({required int indexCourant, required LatLng position}) {
    if (!_guidageActif || !_disponible) return;
    final points = _points;
    if (points.length < 2) return;

    final index = indexCourant.clamp(0, points.length - 1);

    // Arrivée : à ~30 m du dernier point, une seule fois.
    final distanceArrivee =
        _distanceEnAvant(index, position, points.length - 1);
    if (!_arriveeAnnoncee && distanceArrivee <= _seuilArriveeMetres) {
      _arriveeAnnoncee = true;
      _niveauAnnonce = -1;
      _parler('Vous êtes arrivé à destination.');
      return;
    }

    // Le prochain virage se trouve-t-il encore devant nous ?
    while (_indexProchain < _manoeuvres.length &&
        _manoeuvres[_indexProchain].index < index) {
      _indexProchain++;
      _niveauAnnonce = -1;
    }
    if (_indexProchain >= _manoeuvres.length) return;

    final manoeuvre = _manoeuvres[_indexProchain];
    final distance = _distanceEnAvant(index, position, manoeuvre.index);

    final instruction =
        instructionPour(distance, manoeuvre.type, _niveauAnnonce);
    if (instruction == null) return;
    _niveauAnnonce = instruction.$2;
    _parler(instruction.$1);
  }

  /// Décision pure : renvoie la phrase à prononcer (et son niveau) pour un
  /// virage situé à [distance] mètres, ou null si rien ne doit être dit
  /// encore (ni répété). Séparée pour être testable sans synthétiseur.
  @visibleForTesting
  static (String, int)? instructionPour(
    double distance,
    TypeVirage type,
    int niveauAnnonce,
  ) {
    if (distance <= _seuilAnnonceProcheMetres && niveauAnnonce < 2) {
      return (_phrase(type, 2), 2);
    }
    if (distance <= _seuilAnnonceMoyenMetres && niveauAnnonce < 1) {
      return (_phrase(type, 1), 1);
    }
    if (distance <= _seuilAnnonceLoinMetres && niveauAnnonce < 0) {
      return (_phrase(type, 0), 0);
    }
    return null;
  }

  Future<void> _initialiser() async {
    final tts = _tts;
    if (tts == null) return;
    try {
      await tts.setLanguage('fr-FR');
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1.0);
      _disponible = true;
    } catch (_) {
      _disponible = false;
    }
  }

  Future<void> _parler(String texte) async {
    final tts = _tts;
    if (!_disponible || tts == null || !_guidageActif) return;
    try {
      await tts.stop();
      await tts.speak(texte);
    } catch (_) {
      _disponible = false;
    }
  }

  static String _phrase(TypeVirage type, int niveau) {
    switch (type) {
      case TypeVirage.gauche:
        if (niveau == 0) return 'Dans 300 mètres, tournez à gauche.';
        if (niveau == 1) return 'Dans 100 mètres, tournez à gauche.';
        return 'Tournez à gauche.';
      case TypeVirage.droite:
        if (niveau == 0) return 'Dans 300 mètres, tournez à droite.';
        if (niveau == 1) return 'Dans 100 mètres, tournez à droite.';
        return 'Tournez à droite.';
      case TypeVirage.demiTour:
        if (niveau == 0) return 'Dans 300 mètres, faites demi-tour.';
        if (niveau == 1) return 'Dans 100 mètres, faites demi-tour.';
        return 'Faites demi-tour.';
    }
  }

  /// Distance, le long de la route, entre la position courante (projetée sur
  /// [indexDep]) et le point d'index [indexCible].
  double _distanceEnAvant(int indexDep, LatLng position, int indexCible) {
    final points = _points;
    var distance = distanceMetres(position, points[indexDep]);
    for (var i = indexDep; i < indexCible && i < points.length - 1; i++) {
      distance += distanceMetres(points[i], points[i + 1]);
    }
    return distance;
  }
}

/// Transforme la polyligne d'un itinéraire en liste de virages : chaque point
/// où le cap de la route change d'au moins 30° devient une manoeuvre, avec un
/// lissage (caps échantillonnés à ~22 m) pour ignorer le bruit des virages
/// serrés et la fusion des zigzags rapprochés.
List<Manoeuvre> calculerManoeuvres(List<LatLng> points) {
  if (points.length < 6) return const [];
  final manoeuvres = <Manoeuvre>[];

  for (var i = 1; i < points.length - 1; i++) {
    final entrant = _pointEchantillon(points, i, reculer: true);
    final sortant = _pointEchantillon(points, i, reculer: false);
    if (entrant == null || sortant == null) continue;

    final capEntrant = capTrace(entrant, points[i]);
    final capSortant = capTrace(points[i], sortant);
    final delta = deltaRotation(capEntrant, capSortant).abs();
    if (delta < VoixGuidage._seuilVirageDegres) continue;

    late final TypeVirage type;
    if (delta > 165) {
      type = TypeVirage.demiTour;
    } else if (deltaRotation(capEntrant, capSortant) > 0) {
      // Cap boussole croissant (nord 0° → est 90°) = rotation horaire = droite.
      type = TypeVirage.droite;
    } else {
      type = TypeVirage.gauche;
    }

    if (manoeuvres.isNotEmpty &&
        distanceMetres(points[manoeuvres.last.index], points[i]) <
            VoixGuidage._seuilFusionViragesMetres) {
      if (delta > manoeuvres.last.ampleur) {
        manoeuvres[manoeuvres.length - 1] =
            Manoeuvre(index: i, type: type, ampleur: delta);
      }
      continue;
    }

    manoeuvres.add(Manoeuvre(index: i, type: type, ampleur: delta));
  }
  return manoeuvres;
}

/// Point situé à environ [_fenetreCapsMetres] de [i] sur la polyligne, en
/// arrière ([reculer] vrai) ou en avant. Null si le tracé ne s'étend pas
/// assez loin dans cette direction pour échantillonner un cap fiable.
LatLng? _pointEchantillon(
  List<LatLng> points,
  int i, {
  required bool reculer,
}) {
  final fenetre = VoixGuidage._fenetreCapsMetres;
  if (reculer) {
    for (var j = i - 1; j >= 0; j--) {
      if (distanceMetres(points[j], points[i]) >= fenetre) return points[j];
    }
    // Pas assez de recul : cap impossible à estimer (début de tracé).
    return null;
  }
  for (var j = i + 1; j < points.length; j++) {
    if (distanceMetres(points[i], points[j]) >= fenetre) return points[j];
  }
  return null;
}