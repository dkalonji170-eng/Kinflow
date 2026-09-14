import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics_service.dart';

/// Récupère UNE FOIS l'archive complète de la carte claire (`kinshasa.fmtc`)
/// puis l'importe dans le magasin FMTC local.
///
/// Après ce téléchargement, l'appareil possède toute la carte en clair :
/// plus aucune tuile n'est rechargée sur le réseau à chaque utilisation.
/// Relancer l'application ne re-télécharge rien (tuiles déjà présentes).
class TileArchiveService {
  TileArchiveService._();

  static final TileArchiveService instance = TileArchiveService._();

  /// URL de l'archive des tuiles claires. À la compilation, on peut la changer
  /// avec `--dart-define=KINFLOW_ARCHIVE_URL=https://…/kinshasa.fmtc`.
  /// Par défaut : fichier servi à la racine du site KinFlow.
  static const String archiveUrl = String.fromEnvironment(
    'KINFLOW_ARCHIVE_URL',
    defaultValue: 'https://kinflow.netlify.app/kinshasa.fmtc',
  );

  /// Une carte claire complète contient ~4 000 tuiles (sans le satellite).
  static const int _seuilTuilesComplet = 3500;

  static const String _cleDejaTelechargee = 'archive_carte_telechargee';

  final StreamController<double> _progressController =
      StreamController<double>.broadcast();

  /// Progression du téléchargement de l'archive, de 0 à 100.
  Stream<double> get progress => _progressController.stream;

  bool _enCours = false;

  /// `true` si un téléchargement d'archive est en cours.
  bool get enCours => _enCours;

  /// `true` si l'archive a déjà été récupérée sur cet appareil.
  Future<bool> get dejaTelechargee async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_cleDejaTelechargee) ?? false;
  }

  /// Oublie l'archive (après un effacement du cache, par ex.) pour permettre
  /// de la re-télécharger.
  Future<void> marquerEfface() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cleDejaTelechargee);
  }

  /// `true` si le magasin contient déjà toute la carte claire.
  Future<bool> get dejaComplete async {
    try {
      final nb = await FMTCStore('kinshasa').stats.length;
      return nb >= _seuilTuilesComplet;
    } catch (_) {
      return false;
    }
  }

  /// Télécharge et importe l'archive une fois.
  ///
  /// Retourne le nombre de tuiles présentes après import, ou `null` si rien
  /// n'était à faire (déjà complet / déjà téléchargé / web / URL vide).
  Future<int?> telechargerUneFois() async {
    if (kIsWeb || _enCours || archiveUrl.isEmpty) return null;
    if (await dejaComplete || await dejaTelechargee) return null;

    _enCours = true;
    final store = FMTCStore('kinshasa');
    try {
      final supportDir = await getApplicationSupportDirectory();
      final fichier = File('${supportDir.path}/kinshasa.fmtc');
      if (await fichier.exists()) await fichier.delete();

      await _telecharger(fichier);

      final taille = await fichier.length();
      if (taille == 0) {
        if (await fichier.exists()) await fichier.delete();
        throw const FormatException('archive vide');
      }

      Journal.i('TUILES', 'Import de l\'archive de la carte claire', {
        'mo': (taille / (1024 * 1024)).toStringAsFixed(1),
      });
      final importation = FMTCRoot.external(pathToArchive: fichier.path).import(
        storeNames: ['kinshasa'],
        strategy: ImportConflictStrategy.merge,
      );
      await importation.complete;

      if (await fichier.exists()) await fichier.delete();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_cleDejaTelechargee, true);

      final nbTiles = await store.stats.length;
      Journal.s(
          'TUILES', 'Carte claire complète disponible hors ligne ($nbTiles tuiles)');
      return nbTiles;
    } catch (e) {
      debugPrint('[KinFlow] Échec téléchargement de l\'archive: $e');
      Journal.e('TUILES', 'Échec de l\'archive de la carte claire', {
        'erreur': '$e',
        'url': archiveUrl,
      });
      rethrow;
    } finally {
      _enCours = false;
    }
  }

  Future<void> _telecharger(File fichier) async {
    final client = http.Client();
    try {
      final requete = http.Request('GET', Uri.parse(archiveUrl));
      requete.followRedirects = true;
      final reponse = await client.send(requete);
      if (reponse.statusCode != 200) {
        throw HttpException(
            'HTTP ${reponse.statusCode} pour $archiveUrl');
      }
      final total = reponse.contentLength ?? 0;
      var recu = 0;
      final sink = fichier.openWrite();
      try {
        await for (final morceau in reponse.stream) {
          recu += morceau.length;
          sink.add(morceau);
          if (total > 0) {
            _progressController.add((recu / total * 100).clamp(0, 100));
          }
        }
      } finally {
        await sink.close();
      }
      _progressController.add(100);
    } finally {
      client.close();
    }
  }
}