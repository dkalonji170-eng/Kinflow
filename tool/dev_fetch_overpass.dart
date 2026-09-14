import 'dart:convert';
import 'dart:io';

/// Récupère le réseau routier réel de Kinshasa (toutes classes de rues) et
/// l'écrit en JSON `out geom` — la source attendue par fabrique_graphe.dart
/// en mode `--overpass`. Script de maintenance ponctuel.
Future<void> main(List<String> args) async {
  final out = args.isNotEmpty
      ? args[0]
      : 'tool/kinshasa_overpass.json';

  const classes =
      'motorway|motorway_link|trunk|trunk_link|primary|primary_link'
      '|secondary|secondary_link|tertiary|tertiary_link'
      '|unclassified|residential|living_street|service';
  const sud = -4.72, nord = -4.13, ouest = 15.03, est = 15.62;

  final query = '''
[out:json][timeout:180];
(
  way["highway"~"^($classes)\$"]($sud,$ouest,$nord,$est);
);
out geom;''';

  final endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://overpass.openstreetmap.ru/api/interpreter',
  ];

  String? dernierErreur;
  for (final endpoint in endpoints) {
    stdout.writeln('Tentative $endpoint ...');
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      final req = await client.postUrl(Uri.parse(endpoint));
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      req.headers.set('User-Agent', 'KinFlow-Offline/1.0');
      req.write('data=${Uri.encodeQueryComponent(query)}');
      final res = await req.close().timeout(const Duration(seconds: 200));
      final body = await res.transform(utf8.decoder).join();
      client.close();
      if (res.statusCode != 200) {
        dernierErreur = 'HTTP ${res.statusCode}: ${body.substring(0, body.length > 200 ? 200 : body.length)}';
        stdout.writeln('  $dernierErreur');
        continue;
      }
      final file = File(out);
      file.createSync(recursive: true);
      file.writeAsStringSync(body, flush: true);
      stdout.writeln('OK $out (${(file.lengthSync() / 1024).toStringAsFixed(0)} Ko) depuis $endpoint');
      return;
    } catch (e) {
      dernierErreur = '$e';
      stdout.writeln('  Échec: $e');
    }
  }
  stderr.writeln('Tous les miroirs Overpass ont échoué: $dernierErreur');
  exit(1);
}