// Fabrique le graphe routier embarqué (`assets/kinflow_routes.bin`) à partir
// de sources OSM, pour un routage hors‑ligne dans KinFlow.
//
// Usage (depuis la racine du projet) :
//   dart run tool/fabrique_graphe.dart --maillage -o assets/kinflow_routes.bin
//   dart run tool/fabrique_graphe.dart --osm data.osm -o assets/kinflow_routes.bin
//   dart run tool/fabrique_graphe.dart --overpass overpass.json -o assets/kinflow_routes.bin
//
// Le fichier .bin peut être regénéré sur le PC de l'utilisateur à partir de
// vraies données OSM (fichier .osm du Geofabrik Congo, ou une réponse Overpass
// pour Kinshasa) — il n'est jamais contacté depuis l'app : celle-ci se sert du
// network (Overpass) en repli quand l'asset est absent ou insuffisant.

import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';

import 'package:kinflow/models/road_segment.dart';
import 'package:kinflow/services/offline_graph_codec.dart';

const _classeES = {
  'motorway': 0.55,
  'motorway_link': 0.55,
  'trunk': 0.62,
  'trunk_link': 0.62,
  'primary': 0.7,
  'primary_link': 0.7,
  'secondary': 0.78,
  'secondary_link': 0.78,
  'tertiary': 0.85,
  'tertiary_link': 0.85,
  'unclassified': 1.0,
  'residential': 1.0,
  'living_street': 1.0,
  'service': 1.1,
  'road': 1.0,
};

void _usage() {
  stderr.writeln('''
fabrique_graphe — génère l'asset de routage hors‑ligne de KinFlow.

Usage:
  dart run tool/fabrique_graphe.dart --maillage [-o out.bin]
  dart run tool/fabrique_graphe.dart --osm <fichier.osm> -o out.bin
  dart run tool/fabrique_graphe.dart --overpass <overpass.json> -o out.bin

Options:
  -o, --out <chemin>   Fichier de sortie (défaut: assets/kinflow_routes.bin)
  --noize-clean        Ne pas réduire les micro‑dentelures d'un pixel
''');
}

void main(List<String> args) {
  String? entree;
  var mode = '';
  var out = 'assets/kinflow_routes.bin';

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--maillage') {
      mode = 'maillage';
    } else if (a == '--osm') {
      mode = 'osm';
      entree = args[++i];
    } else if (a == '--overpass') {
      mode = 'overpass';
      entree = args[++i];
    } else if (a == '-o' || a == '--out') {
      out = args[++i];
    } else if (a == '-h' || a == '--help') {
      _usage();
      return;
    }
  }

  if (mode.isEmpty) {
    _usage();
    exit(2);
  }

  final List<RoadSegment> segments;
  switch (mode) {
    case 'maillage':
      segments = _genererMaillage();
    case 'osm':
      segments = _lireOsm(File(entree!).readAsStringSync());
    case 'overpass':
      segments = _lireOverpass(File(entree!).readAsStringSync());
    default:
      _usage();
      exit(2);
  }

  if (segments.length < 2) {
    stderr.writeln('Aucun segment exploitable (${segments.length}).');
    exit(1);
  }

  final octets = GrapheCodec.encoderSegments(segments);
  final f = File(out);
  f.createSync(recursive: true);
  f.writeAsBytesSync(octets, flush: true);
  final nbPoints = segments.fold<int>(0, (n, s) => n + s.points.length);
  stdout.writeln('OK : ${segments.length} segments, '
      '$nbPoints points, ${(octets.length / 1024).toStringAsFixed(1)} Ko '
      '→ $out');
}

/// Mode de secours : une grille routière complète et CONNECTÉE couvrant
/// Kinshasa et ses environs, utilisable tant que de vraies données OSM ne
/// sont pas fournies (le bac à sable ne peut pas joindre Overpass).
///
/// Chaque ligne porte un point à CHAQUE intersection avec une ligne
/// perpendiculaire : le Dijkstra peut tourner à tous les carrefours et deux
/// points quelconques de la zone restent toujours reliables — y compris sur
/// une longue distance. Le fichier produit est ensuite remplaçable tel quel
/// par `--osm` ou `--overpass`.
List<RoadSegment> _genererMaillage() {
  // Zone couverte : l'aire urbaine de Kinshasa plus une marge, pour qu'un
  // couloir d'itinéraire (déjà élargi de ±0.03 par le Dijkstra) reste
  // entièrement dans l'asset et évite le repli réseau.
  const latMin = -4.65;
  const latMax = -4.20;
  const lonMin = 15.05;
  const lonMax = 15.55;

  // Pas de ~0.006° (≈ 650 m) : assez fin pour relier n'importe quel quartier
  // sans gonfler l'asset (une grille 100×100 ne fait que quelques centaines
  // de Ko). Une ligne sur 6 est un axe « primaire » nommé, le reste du
  // maillage est en « residential » (détail réseau, pas d'affichage).
  const pas = 0.006;
  const sur6 = 6;

  final lats = <double>[];
  for (var lat = latMin; lat <= latMax + 1e-9; lat += pas) {
    lats.add(lat);
  }
  final lons = <double>[];
  for (var lon = lonMin; lon <= lonMax + 1e-9; lon += pas) {
    lons.add(lon);
  }

  final segments = <RoadSegment>[];
  var id = 1;

  // Lignes horizontales (boulevards).
  for (var i = 0; i < lats.length; i++) {
    final majeur = i % sur6 == 0;
    final points = <LatLng>[
      for (final lon in lons) LatLng(lats[i], lon),
    ];
    segments.add(RoadSegment(
      id: id++,
      nom: majeur ? 'Boulevard ${i ~/ sur6}' : '',
      classe: majeur ? 'primary' : 'residential',
      points: points,
    ));
  }

  // Lignes verticales (avenues).
  for (var j = 0; j < lons.length; j++) {
    final majeur = j % sur6 == 0;
    final points = <LatLng>[
      for (final lat in lats) LatLng(lat, lons[j]),
    ];
    segments.add(RoadSegment(
      id: id++,
      nom: majeur ? 'Avenue ${j ~/ sur6}' : '',
      classe: majeur ? 'primary' : 'residential',
      points: points,
    ));
  }

  return segments;
}

/// Lit un fichier OSM (plan XML du Geofabrik / export Overpass XML).
List<RoadSegment> _lireOsm(String brut) {
  final nodeLat = <String, LatLng>{};

  // <node id=".." lat=".." lon=".."/>
  final nodeReg = RegExp(
      r'<node\s+id="(-?\d+)"\s+lat="([0-9.eE+]+)"\s+lon="([0-9.eE+]+)"/>');
  for (final m in nodeReg.allMatches(brut)) {
    final lat = double.parse(m.group(2)!);
    final lon = double.parse(m.group(3)!);
    nodeLat[m.group(1)!] = LatLng(lat, lon);
  }

  final wayBlocks = RegExp(r'<way\b[^>]*>(.*?)</way>', dotAll: true)
      .allMatches(brut)
      .map((m) => m.group(1)!)
      .toList();

  final segments = <RoadSegment>[];
  var id = 1;
  for (final block in wayBlocks) {
    final refs = RegExp(r'<nd\s+ref="(-?\d+)"\s*/>')
        .allMatches(block)
        .map((m) => m.group(1)!)
        .toList();
    final tags = <String, String>{};
    for (final tm in RegExp(r'<tag\s+k="([^"]*)"\s+v="([^"]*)"\s*/>')
        .allMatches(block)) {
      tags[tm.group(1)!] = tm.group(2)!;
    }
    final classe = tags['highway'];
    if (classe == null || !_classeES.containsKey(classe)) continue;
    if (refs.length < 2) continue;
    final pts = <LatLng>[];
    var ok = true;
    for (final r in refs) {
      final p = nodeLat[r];
      if (p == null) {
        ok = false;
        break;
      }
      pts.add(p);
    }
    if (!ok) continue;
    segments.add(RoadSegment(
      id: id++,
      nom: tags['name'] ?? '',
      classe: classe,
      points: pts,
    ));
  }
  return segments;
}

/// Lit une réponse Overpass JSON (`out geom;`) — même format que [RoadService].
List<RoadSegment> _lireOverpass(String brut) {
  final decoded = json.decode(brut) as Map<String, dynamic>;
  final elements = decoded['elements'] as List? ?? const [];
  final segments = <RoadSegment>[];
  var id = 1;
  for (final e in elements) {
    if ((e as Map)['type'] != 'way') continue;
    final tags = (e['tags'] as Map<String, dynamic>?) ?? const {};
    final classe = tags['highway'] as String?;
    if (classe == null || !_classeES.containsKey(classe)) continue;
    final geometry = e['geometry'] as List? ?? const [];
    if (geometry.length < 2) continue;
    final points = <LatLng>[];
    for (final g in geometry) {
      points.add(LatLng(
        (g['lat'] as num).toDouble(),
        (g['lon'] as num).toDouble(),
      ));
    }
    segments.add(RoadSegment(
      id: id++,
      nom: tags['name'] as String? ?? '',
      classe: classe,
      points: points,
    ));
  }
  return segments;
}
