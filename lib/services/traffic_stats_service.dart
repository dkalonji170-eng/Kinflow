import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/traffic_state.dart';

/// Un signalement anonyme provenant de Supabase.
class Signalement {
  final String etat;
  final double latitude;
  final double longitude;

  /// Cap GPS en degrés (0 = nord). Null si la direction est inconnue.
  final double? cap;

  /// Moment où le témoin a signalé. Servira à pondérer la fiabilité :
  /// un signalement récent pèse plus qu'un signalement vieilli.
  /// Null si l'ancienneté est inconnue (repli : considéré comme récent).
  final DateTime? creeA;

  const Signalement({
    required this.etat,
    required this.latitude,
    required this.longitude,
    this.cap,
    this.creeA,
  });
}

/// Cône de vision d'un témoin : couvre un angle devant lui, jusqu'à
/// une certaine portée. Sans cap, il couvre tout autour (360°).
class ConeVision {
  final LatLng origine;
  final double? cap;

  /// Portée en mètres.
  final double rayon;

  /// Demi-angle du cône de vision (45° → champ de vision de 90°).
  static const double demiAngleDegres = 45;

  const ConeVision({
    required this.origine,
    required this.cap,
    required this.rayon,
  });

  /// Le point est-il visible dans ce cône ?
  bool couvre(LatLng point) {
    final distance = TrafficStatsService.distanceMetres(
      origine.latitude,
      origine.longitude,
      point.latitude,
      point.longitude,
    );
    if (distance > rayon) return false;

    final c = cap;
    if (c == null) return true;

    final angle = _angleVers(point);
    var diff = (angle - c) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return diff.abs() <= demiAngleDegres;
  }

  /// Angle (degrés) de [point] vu depuis [origine], 0 = nord.
  double _angleVers(LatLng point) {
    final lat1 = origine.latitude * math.pi / 180;
    final lat2 = point.latitude * math.pi / 180;
    final dLon = (point.longitude - origine.longitude) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}

/// Une zone de trafic issue des statistiques collaboratives : l'union des
/// cônes de vision des témoins de l'état majoritaire.
class ZoneTrafic {
  final EtatTrafic etat;
  final LatLng centre;
  final int nb; // nombre de témoins pour l'état majoritaire

  /// Nombre total de signalements dans la zone (tous états confondus).
  final int total;

  /// Fiabilité des statistiques, de 0 (aucune) à 1 (très fiable).
  /// Combine le nombre de témoins, le consensus et l'ancienneté.
  final double fiabilite;

  /// Dernière confirmation de la zone (témoin majoritaire le plus récent) :
  /// la couleur s'estompe au fil du temps, jusqu'à redevenir l'état simulé.
  final DateTime? derniereConfirmation;

  final List<ConeVision> cones;

  const ZoneTrafic({
    required this.etat,
    required this.centre,
    required this.nb,
    required this.total,
    required this.fiabilite,
    this.derniereConfirmation,
    required this.cones,
  });

  /// Le point est-il couvert par au moins un cône de la zone ?
  bool couvre(LatLng point) {
    for (final cone in cones) {
      if (cone.couvre(point)) return true;
    }
    return false;
  }
}

/// Statistiques collaboratives : regroupe les signalements proches et
/// construit des zones couvertes par les cônes de vision des témoins.
class TrafficStatsService {
  /// Deux signalements à moins de cette distance appartiennent au même
  /// groupe. 250 m au lieu de 500 : assez large pour que 3 témoins isolés
  /// se rejoignent, assez serré pour ne pas fusionner des routes distinctes.
  static const double distanceFusion = 250;

  /// Nombre minimal de témoins pour produire de vraies statistiques.
  static const int minimumTemoins = 3;

  /// Nombre maximal de zones gardées (les plus attestées d'abord) : borne le
  /// coût du test "le point est-il dans un cône" pour chaque arête de route.
  static const int maxZones = 60;

  /// Durée (heures) au-delà de laquelle un signalement n'influence plus rien.
  static const double fenetreHeures = 1.0;

  /// Portée en mètres d'un cône de vision : 30 + 10 × (n − 3).
  /// Chaque témoin supplémentaire ajoute 10 m de portée.
  static double rayonPour(int n) {
    if (n < minimumTemoins) return 0;
    return 30.0 + 10 * (n - minimumTemoins);
  }

  /// Fiabilité brute selon le nombre de témoins :
  /// 3 → 0.40, 4 → 0.49, 5 → 0.57, 6 → 0.66, 7 → 0.74, 8 → 0.83,
  /// 9 → 0.91, 10 → 1.00. Plafonnée à 1.
  /// Un plancher un peu plus haut (0.40 au lieu de 0.35) garde les zones
  /// créées avec le minimum de témoins bien visibles au démarrage de l'app.
  static double fiabilitePour(int n) {
    if (n < minimumTemoins) return 0;
    final progression = ((n - minimumTemoins) / 7).clamp(0.0, 1.0);
    return 0.4 + 0.6 * progression;
  }

  /// Fraîcheur d'un signalement : 1 tout neuf, tendant vers 0 quand il
  /// s'approche de la fin de la fenêtre. Un signalement vieilli compte moins.
  static double recencePour(DateTime? creeA, DateTime maintenant) {
    final t = creeA;
    if (t == null) return 1.0;
    final age = maintenant.difference(t).inSeconds;
    if (age <= 0) return 1.0;
    return (1 - age / (fenetreHeures * 3600)).clamp(0.0, 1.0);
  }

  static List<Signalement> depuisSupabase(List<Map<String, dynamic>> brut) {
    final resultats = <Signalement>[];
    for (final e in brut) {
      final etat = (e['etat'] as String?)?.trim();
      final lat = (e['latitude'] as num?)?.toDouble();
      final lon = (e['longitude'] as num?)?.toDouble();
      final cap = (e['cap'] as num?)?.toDouble();
      if (etat == null || lat == null || lon == null) continue;
      if (EtatTrafic.depuisLibelle(etat) == null) continue;

      // Ancienneté du signalement (ISO 8601). Si absente ou illisible,
      // on le considère comme frais (dégradation douce si l'API est ancienne).
      DateTime? creeA;
      try {
        final brut = e['cree_a'];
        if (brut is String) creeA = DateTime.parse(brut);
      } catch (_) {
        creeA = null;
      }

      resultats.add(
        Signalement(
          etat: etat,
          latitude: lat,
          longitude: lon,
          cap: cap,
          creeA: creeA,
        ),
      );
    }
    return resultats;
  }

  /// Regroupe les signalements en zones et ne garde que celles avec au moins
  /// [minimumTemoins] témoins pour l'état majoritaire.
  List<ZoneTrafic> calculerZones(List<Signalement> signalements) {
    if (signalements.length < minimumTemoins) return const [];

    final zones = <ZoneTrafic>[];
    for (final groupe in _regrouper(signalements)) {
      final parEtat = <String, List<Signalement>>{};
      for (final s in groupe) {
        parEtat.putIfAbsent(s.etat, () => []).add(s);
      }

      String majoritaire = parEtat.keys.first;
      for (final etat in parEtat.keys) {
        if (parEtat[etat]!.length > parEtat[majoritaire]!.length) {
          majoritaire = etat;
        }
      }

      final temoins = parEtat[majoritaire]!;
      if (temoins.length < minimumTemoins) continue;

      // Fiabilité : plus de témoins = plus fiable, un meilleur accord
      // (consensus) renforce la confiance, et une confirmation récente
      // vaut mieux qu'un signalement vieilli.
      final consensus = temoins.length / groupe.length;
      final derniereConfirmation = temoins
          .map((s) => s.creeA)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (a, b) => (a == null || b.isAfter(a)) ? b : a);
      final recence = recencePour(derniereConfirmation, DateTime.now());
      final fiabilite = (fiabilitePour(temoins.length) *
              (0.6 + 0.4 * consensus) *
              recence)
          .clamp(0.0, 1.0);

      final rayon = rayonPour(temoins.length);
      final cones = [
        for (final s in temoins)
          ConeVision(
            origine: LatLng(s.latitude, s.longitude),
            cap: s.cap,
            rayon: rayon,
          ),
      ];

      zones.add(
        ZoneTrafic(
          etat: EtatTrafic.depuisLibelle(majoritaire)!,
          centre: _centroide(temoins),
          nb: temoins.length,
          total: groupe.length,
          fiabilite: fiabilite,
          derniereConfirmation: derniereConfirmation,
          cones: cones,
        ),
      );
    }

    // Les zones les plus attestées d'abord (la carte prend la plus forte),
    // puis on garde seulement les plus solides pour borner le coût.
    zones.sort((a, b) => b.nb.compareTo(a.nb));
    return zones.take(maxZones).toList();
  }

  List<List<Signalement>> _regrouper(List<Signalement> points) {
    final parent = List.generate(points.length, (i) => i);

    int find(int i) {
      while (parent[i] != i) {
        parent[i] = parent[parent[i]];
        i = parent[i];
      }
      return i;
    }

    void union(int a, int b) {
      parent[find(a)] = find(b);
    }

    for (var i = 0; i < points.length; i++) {
      for (var j = i + 1; j < points.length; j++) {
        if (distanceMetres(
              points[i].latitude,
              points[i].longitude,
              points[j].latitude,
              points[j].longitude,
            ) <=
            distanceFusion) {
          union(i, j);
        }
      }
    }

    final groupes = <int, List<Signalement>>{};
    for (var i = 0; i < points.length; i++) {
      groupes.putIfAbsent(find(i), () => []).add(points[i]);
    }
    return groupes.values.toList();
  }

  LatLng _centroide(List<Signalement> points) {
    var lat = 0.0;
    var lon = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lon += p.longitude;
    }
    return LatLng(lat / points.length, lon / points.length);
  }

  /// Distance en mètres entre deux coordonnées (haversine).
  static double distanceMetres(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }
}
