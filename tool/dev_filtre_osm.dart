import 'dart:convert';
import 'dart:io';

/// Filtre une réponse Overpass `out geom` sur la zone urbaine de Kinshasa et
/// renumérote les ids : les ways rejetées sont retirées, les way ways ayant
/// au moins un point dans la boîte sont conservées entières (les corridors du
/// Dijkstra restent couverts même en bordure).
void main(List<String> args) {
  final entree = args[0];
  final sortie = args.length > 1 ? args[1] : '${entree}_urbain.json';
  final sud = args.length > 2 ? double.parse(args[2]) : -4.70;
  final nord = args.length > 3 ? double.parse(args[3]) : -4.18;
  final ouest = args.length > 4 ? double.parse(args[4]) : 15.05;
  final est = args.length > 5 ? double.parse(args[5]) : 15.60;

  final data = json.decode(File(entree).readAsStringSync());
  final elements = (data as Map<String, dynamic>)['elements'] as List? ?? const [];
  final gardes = <Map<String, dynamic>>[];
  var id = 1;
  var totalPts = 0;
  var miniLat = 90.0, maxiLat = -90.0, miniLon = 180.0, maxiLon = -180.0;
  final parClasse = <String, int>{};
  for (final e in elements) {
    final m = e as Map<String, dynamic>;
    if (m['type'] != 'way') continue;
    final tags = (m['tags'] as Map? ?? const {});
    final classe = (tags['highway'] ?? '').toString();
    if (classe.isEmpty) continue;
    // Les ruelles et accès privés représentent 95 % des points sans apporter
    // de connectivité inter-quartiers : l'asset garde le réseau principal.
    if (classe == 'residential' || classe == 'service') continue;
    final geometrie = m['geometry'] as List? ?? const [];
    var dansBoite = false;
    for (final g in geometrie) {
      final lat = (g['lat'] as num).toDouble();
      final lon = (g['lon'] as num).toDouble();
      if (lat >= sud && lat <= nord && lon >= ouest && lon <= est) {
        dansBoite = true;
        break;
      }
    }
    if (!dansBoite) continue;
    parClasse[classe] = (parClasse[classe] ?? 0) + 1;
    m['id'] = id++;
    gardes.add(m);
    for (final g in geometrie) {
      final lat = (g['lat'] as num).toDouble();
      final lon = (g['lon'] as num).toDouble();
      totalPts++;
      if (lat < miniLat) miniLat = lat;
      if (lat > maxiLat) maxiLat = lat;
      if (lon < miniLon) miniLon = lon;
      if (lon > maxiLon) maxiLon = lon;
    }
  }
  final j = {'version': 0.6, 'generator': 'kinflow-filter', 'elements': gardes};
  File(sortie).writeAsStringSync(json.encode(j), flush: true);
  stdout.writeln('${gardes.length} ways, $totalPts points → $sortie');
  stdout.writeln('bbox réel: lat $miniLat..$maxiLat lon $miniLon..$maxiLon');
  final cles = parClasse.keys.toList()..sort();
  for (final c in cles) {
    stdout.writeln('  $c : ${parClasse[c]}');
  }
}