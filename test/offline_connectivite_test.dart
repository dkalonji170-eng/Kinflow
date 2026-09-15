import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/itineraire_service.dart';
import 'package:kinflow/services/offline_graph_codec.dart';
import 'package:latlong2/latlong.dart';

/// Garantit que l'asset embarqué (vrai réseau routier OSM) est assez CONNECTÉ
/// pour relier les quartiers éloignés de Kinshasa, avec la même tolérance de
/// fusion de nœuds que le moteur local (12 m), et que le service d'itinéraire
/// sait s'en servir en secours quand Overpass est indisponible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('l\'asset relie les quartiers éloignés de Kinshasa', () {
    final fichier = File('assets/kinflow_routes.bin');
    expect(fichier.existsSync(), isTrue,
        reason: 'Lancer dart run tool/fabrique_graphe.dart --overpass '
            '<osm.json> -o assets/kinflow_routes.bin avant ce test.');

    final brut = GrapheCodec.decoderHorsLigne(fichier.readAsBytesSync());
    final zone = LimitesGraphe(
      nord: brut.latMax,
      sud: brut.latMin,
      est: brut.lonMax,
      ouest: brut.lonMin,
    );

    final segments = brut.segmentsDans(zone);
    expect(segments.length, greaterThan(100));

    // Graphe reconstruit comme le fait le moteur local : nœuds fusionnés à
    // moins de 12 m (imprécisions de cartographie), jamais les deux chaussées
    // d'un boulevard séparé (15 à 30 m d'écart).
    const tailleCellule = 0.00025;
    const toleranceMetres = 12.0;
    final grille = <int, List<int>>{};
    final points = <LatLng>[];
    final voisins = <int, List<int>>{};
    int cle(int r, int c) => r * 1000003 + c;

    int noeudPour(LatLng p) {
      final r = (p.latitude / tailleCellule).floor();
      final c = (p.longitude / tailleCellule).floor();
      for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
          final ids = grille[cle(r + dr, c + dc)];
          if (ids == null) continue;
          for (final id in ids) {
            if (_distanceMetres(points[id], p) <= toleranceMetres) return id;
          }
        }
      }
      final id = points.length;
      points.add(p);
      grille.putIfAbsent(cle(r, c), () => []).add(id);
      return id;
    }

    void cote(int a, int b) {
      voisins.putIfAbsent(a, () => []).add(b);
      voisins.putIfAbsent(b, () => []).add(a);
    }

    for (final s in segments) {
      if (s.points.length < 2) continue;
      int? prec;
      for (final p in s.points) {
        final n = noeudPour(p);
        if (prec != null && prec != n) cote(prec, n);
        prec = n;
      }
    }
    expect(points.length, greaterThan(1000),
        reason: 'l\'asset doit avoir des milliers de carrefours');

    // Composantes connexes : flood à travers tous les carrefours.
    final communaute = <int, int>{};
    var nbComposantes = 0;
    for (final n in voisins.keys) {
      if (communaute.containsKey(n)) continue;
      final id = nbComposantes++;
      final file = <int>[n];
      communaute[n] = id;
      while (file.isNotEmpty) {
        final c = file.removeLast();
        for (final v in voisins[c]!) {
          if (!communaute.containsKey(v)) {
            communaute[v] = id;
            file.add(v);
          }
        }
      }
    }

    // Composante connexe géante (la plus grande par taille).
    final compTaille = <int, int>{};
    for (final id in communaute.values) {
      compTaille[id] = (compTaille[id] ?? 0) + 1;
    }
    var idGeante = -1;
    var plusGrande = 0;
    compTaille.forEach((id, taille) {
      if (taille > plusGrande) {
        plusGrande = taille;
        idGeante = id;
      }
    });
    expect(plusGrande, greaterThan(points.length ~/ 2),
        reason: 'la moitié au moins des carrefours doit être jointe : un '
            'itinéraire doit exister entre les quartiers principaux.');

    // Les quartiers éloignés de la ville doivent être DANS la composante
    // géante : deux points opposés restent routables en local.
    const reperes = <String, (double, double)>{
      'Gombe centre': (-4.3047, 15.3130),
      'Centre (Limete)': (-4.33, 15.33),
      'N\'djili': (-4.405, 15.437),
      'Masina': (-4.38, 15.40),
      'Bandalungwa': (-4.34, 15.27),
      'Sud (aéroport)': (-4.65, 15.25),
    };
    for (final e in reperes.entries) {
      final (lat, lon) = e.value;
      var meilleur = 0;
      var dMin = 1e18;
      for (var i = 0; i < points.length; i++) {
        final d = _distanceMetres(points[i], LatLng(lat, lon));
        if (d < dMin) {
          dMin = d;
          meilleur = i;
        }
      }
      expect(communaute[meilleur], idGeante,
          reason: '${e.key} doit être relié au reste de la ville par le '
              'graphe embarqué.');
    }
  });

  test('hors-ligne : sans réseau, le graphe embarqué sert un itinéraire urbain',
      () async {
    // Décision produit : quand Overpass est injoignable (démarrage, 429,
    // panne du réseau africain), l'itinéraire se calcule sur le graphe
    // routier embarqué (réel OSM) plutôt que de renvoyer rien. RoadService
    // (Overpass) est injoignable en test : le service bascule donc sur
    // l'asset et doit relier deux quartiers opposés de la ville.
    final service = ItineraireService();
    final resultat = await service.calculer(
      const LatLng(-4.304, 15.313), // Gombe
      const LatLng(-4.40, 15.43), // N'djili
    );

    expect(resultat, isNotNull,
        reason: 'sans réseau Overpass, l\'itinéraire doit être servi par '
            'l\'asset embarqué (vrai réseau routier de Kinshasa).');
    expect(resultat!.first.points.length, greaterThan(10));
  });
}

const Distance _distance = Distance();

double _distanceMetres(LatLng a, LatLng b) =>
    _distance.as(LengthUnit.Meter, a, b);