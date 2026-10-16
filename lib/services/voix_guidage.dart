import 'package:flutter/foundation.dart'
    show visibleForTesting;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geo.dart' show capTrace, deltaRotation, distanceMetres;
import 'phrases_guidage.dart' show PhrasesGuidage;

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
/// « Suivez l'itinéraire affiché à l'écran » dès que le tracé est affiché,
/// « Dans 300 mètres, tournez à gauche », « Vous êtes arrivé à destination ».
///
/// Totalement optionnel et silencieux tant qu'aucun itinéraire n'est affiché.
/// Si le synthétiseur est indisponible (pas d'API de voix sur la plateforme),
/// le guidage se neutralise tout seul sans jamais faire planter l'app.
class VoixGuidage {
  // Distances d'annonce (mètres restants avant le virage) et d'arrivée.
  static const double _seuilAnnonceLoinMetres = 300;
  static const double _seuilAnnonceMoyenMetres = 100;
  static const double _seuilAnnonce50Metres = 50;
  static const double _seuilAnnonceImminentMetres = 20;
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

  /// Phrases personnalisées chargées depuis les Réglages (repli : défauts).
  /// Rechargées à chaque [preparer] : une modification des Réglages prend
  /// effet au prochain itinéraire affiché.
  Map<String, String> _phrases = PhrasesGuidage.parDefaut();

  /// Index (dans [_manoeuvres]) de la prochaine instruction à passer.
  int _indexProchain = 0;

  /// Niveau d'annonce déjà prononcé pour le virage courant
  /// (-1 = rien, 0 = 300 m, 1 = 100 m, 2 = 50 m, 3 = imminent). La
  /// progression est monotone : on ne répète jamais deux fois la même
  /// distance.
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
  /// itinéraire est affiché ou remplacé) : recalcule les virages, remet les
  /// niveaux d'annonce à zéro et, sauf [annoncerDepart] à false, prononce le
  /// message de départ (« Itinéraire tracé »).
  ///
  /// [annoncerDepart] sert aux CHANGEMENTS d'option (2ème, 3ème tracé
  /// pré-calculé) : la voix se prépare pour les nouveaux virages mais ne
  /// répète pas l'annonce de départ, déjà dite au tracé initial.
  Future<void> preparer(
    List<LatLng> points, {
    bool annoncerDepart = true,
  }) async {
    _phrases = await PhrasesGuidage.charger();
    _points = List.of(points);
    _manoeuvres = calculerManoeuvres(_points);
    _indexProchain = 0;
    _niveauAnnonce = -1;
    _arriveeAnnoncee = false;
    _guidageActif = true;
    if (!_disponible) {
      await _initialiser();
    }
    // Dès que l'itinéraire est tracé, la voix annonce le départ — sauf quand
    // on passe simplement d'une option d'itinéraire à une autre.
    if (annoncerDepart && _points.length >= 2) {
      await _parler(phraseDepartPour(_phrases));
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
      _parler(_phraseArrivee(_phrases));
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

    final instruction = instructionPour(
      distance,
      manoeuvre.type,
      _niveauAnnonce,
      phrases: _phrases,
    );
    if (instruction == null) return;
    _niveauAnnonce = instruction.$2;
    _parler(instruction.$1);
  }

  /// Décision pure : renvoie la phrase à prononcer (et son niveau) pour un
  /// virage situé à [distance] mètres, ou null si rien ne doit être dit
  /// encore (ni répété). Séparée pour être testable sans synthétiseur.
  /// [phrases] (facultatif) : phrases personnalisées — à défaut, les textes
  /// par défaut sont utilisés.
  @visibleForTesting
  static (String, int)? instructionPour(
    double distance,
    TypeVirage type,
    int niveauAnnonce, {
    Map<String, String>? phrases,
  }) {
    if (distance <= _seuilAnnonceImminentMetres && niveauAnnonce < 3) {
      return (_phrase(type, 3, phrases: phrases), 3);
    }
    if (distance <= _seuilAnnonce50Metres && niveauAnnonce < 2) {
      return (_phrase(type, 2, phrases: phrases), 2);
    }
    if (distance <= _seuilAnnonceMoyenMetres && niveauAnnonce < 1) {
      return (_phrase(type, 1, phrases: phrases), 1);
    }
    if (distance <= _seuilAnnonceLoinMetres && niveauAnnonce < 0) {
      return (_phrase(type, 0, phrases: phrases), 0);
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

  /// Phrase de virage à prononcer : celle de [phrases] (personnalisée) si
  /// elle est non vide, sinon le texte par défaut.
  static String _phrase(
    TypeVirage type,
    int niveau, {
    Map<String, String>? phrases,
  }) {
    if (phrases != null) {
      final personnalisee = phrases[PhrasesGuidage.clePour(type, niveau)];
      if (personnalisee != null && personnalisee.trim().isNotEmpty) {
        return personnalisee;
      }
    }
    return PhrasesGuidage.defautPour(type, niveau);
  }

  /// Phrase de départ à prononcer dès que l'itinéraire est tracé :
  /// [phrases] personnalisée non vide sinon le texte par défaut. Séparée
  /// pour être testable sans synthétiseur.
  @visibleForTesting
  static String phraseDepartPour(Map<String, String>? phrases) {
    if (phrases != null) {
      final personnalisee = phrases['depart'];
      if (personnalisee != null && personnalisee.trim().isNotEmpty) {
        return personnalisee;
      }
    }
    return PhrasesGuidage.defautDepart();
  }

  /// Phrase d'arrivée à prononcer : [phrases] personnalisée non vide sinon
  /// le texte par défaut.
  static String _phraseArrivee(Map<String, String>? phrases) {
    if (phrases != null) {
      final personnalisee = phrases['arrivee'];
      if (personnalisee != null && personnalisee.trim().isNotEmpty) {
        return personnalisee;
      }
    }
    return PhrasesGuidage.defautArrivee();
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