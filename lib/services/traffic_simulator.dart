import '../models/road_segment.dart';
import '../models/traffic_state.dart';

class TrafficSimulator {
  static const _poidsParClasse = <String, double>{
    'motorway': 0.55,
    'motorway_link': 0.45,
    'trunk': 0.6,
    'trunk_link': 0.5,
    'primary': 0.5,
    'primary_link': 0.42,
    'secondary': 0.4,
    'secondary_link': 0.34,
    'tertiary': 0.3,
    'tertiary_link': 0.26,
    'unclassified': 0.2,
    'residential': 0.15,
    'living_street': 0.1,
    'service': 0.08,
    'road': 0.2,
  };

  EtatTrafic estimer(RoadSegment segment, {DateTime? moment}) {
    final m = moment ?? DateTime.now();
    final poids = _poidsParClasse[segment.classe] ?? 0.2;
    final facteur = _facteurHoraire(m);
    final bruit = _bruitDeterministe(segment.id);

    final congestion = (poids * facteur).clamp(0.0, 1.0);
    final score = (congestion + (bruit - 0.5) * 0.4).clamp(0.0, 1.0);

    if (score < 0.3) return EtatTrafic.fluide;
    if (score < 0.5) return EtatTrafic.embouteillageLeger;
    if (score < 0.75) return EtatTrafic.grosEmbouteillages;
    return EtatTrafic.routeBloquee;
  }

  double _facteurHoraire(DateTime m) {
    final h = m.hour + m.minute / 60.0;

    double f;
    if (h < 5) {
      f = 0.15;
    } else if (h < 7) {
      f = 0.15 + (h - 5) / 2 * 0.85;
    } else if (h < 9) {
      f = 1.0;
    } else if (h < 12) {
      f = 0.6;
    } else if (h < 14) {
      f = 0.55;
    } else if (h < 15.5) {
      f = 0.65;
    } else if (h < 19) {
      f = 1.0;
    } else if (h < 21) {
      f = 0.6;
    } else {
      f = 0.3;
    }

    final weekend =
        m.weekday == DateTime.saturday || m.weekday == DateTime.sunday;
    return weekend ? f * 0.65 : f;
  }

  double _bruitDeterministe(int id) {
    final x = (id * 2654435761) & 0x7fffffff;
    return (x % 100000) / 100000.0;
  }
}
