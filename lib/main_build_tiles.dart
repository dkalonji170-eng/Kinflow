// ignore_for_file: avoid_print
// Outil de construction de l'archive de tuiles embarquées.
//
// Usage (sur ta machine, une seule fois) :
//   flutter run -d linux -t lib/main_build_tiles.dart
//
// Télécharge toutes les régions (Afrique z2-6, RDC z7-9, Kinshasa z10-16,
// satellite + étiquettes z13-16) puis exporte l'archive FMTC vers
// `build/kinshasa.fmtc`. Copie ensuite ce fichier dans `assets/` et
// reconstruis l'app : les tuiles seront déjà présentes à la première ouverture.
//
// Option : définir la variable d'environnement KINFLOW_TILES_OUT pour choisir
// le dossier de sortie.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'services/tile_regions.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final outDir =
      Platform.environment['KINFLOW_TILES_OUT'] ?? 'build';
  await Directory(outDir).create(recursive: true);
  final archivePath = '$outDir/kinshasa.fmtc';

  print('[BuildTiles] Initialisation FMTC...');
  await FMTCObjectBoxBackend().initialise();
  final store = FMTCStore('kinshasa');
  await store.manage.create();
  print('[BuildTiles] Magasin prêt.');

  print('[BuildTiles] Téléchargement des régions...');
  await telechargerTachesKinflow(
    store: store,
    parallelThreads: 4,
    onProgression: (nom, effectue, total) {
      print('[BuildTiles] $nom : $effectue/$total tuiles');
    },
  );

  print('[BuildTiles] Export de l\'archive...');
  final nbTiles = await FMTCRoot.external(
    pathToArchive: archivePath,
  ).export(storeNames: ['kinshasa']);

  final tailleMo =
      (await File(archivePath).length() / (1024 * 1024)).toStringAsFixed(1);
  print('[BuildTiles] TERMINÉ : $nbTiles tuiles exportées');
  print('[BuildTiles] Fichier : $archivePath ($tailleMo Mo)');
  print('[BuildTiles] Copie ce fichier dans assets/kinshasa.fmtc puis '
      'reconstruis l\'app.');
  exit(0);
}
