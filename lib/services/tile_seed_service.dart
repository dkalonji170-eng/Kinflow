import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:path_provider/path_provider.dart';

/// Importe l'archive de tuiles embarquée dans le magasin FMTC au premier
/// lancement. Ne fait rien si le magasin contient déjà des tuiles.
class TileSeedService {
  static const String _assetArchive = 'assets/kinshasa.fmtc';

  /// Retourne `true` si l'import a été effectué, `false` sinon (déjà en cache
  /// ou échec, auquel cas le téléchargement réseau classique prend le relais).
  static Future<bool> ensureSeeded() async {
    try {
      final store = FMTCStore('kinshasa');
      final nbTiles = await store.stats.length;
      if (nbTiles > 0) return false;

      final supportDir = await getApplicationSupportDirectory();
      final fichierArchive = File('${supportDir.path}/kinshasa.fmtc');

      if (!await fichierArchive.exists()) {
        final data = await rootBundle.load(_assetArchive);
        if (data.lengthInBytes == 0) {
          debugPrint('[KinFlow] Archive embarquée absente, import ignoré.');
          return false;
        }
        await fichierArchive.writeAsBytes(
          data.buffer.asUint8List(),
          flush: true,
        );
      }

      final resultat = FMTCRoot.external(
        pathToArchive: fichierArchive.path,
      ).import(
        storeNames: ['kinshasa'],
        strategy: ImportConflictStrategy.merge,
      );
      await resultat.complete;

      if (await fichierArchive.exists()) {
        await fichierArchive.delete();
      }
      debugPrint('[KinFlow] Tuiles embarquées importées.');
      return true;
    } catch (e) {
      debugPrint('[KinFlow] Import des tuiles embarquées échoué: $e');
      return false;
    }
  }
}
