import 'dart:async';
import 'dart:developer';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'data_usage_service.dart';
import 'diagnostics_service.dart';
import 'tile_regions.dart';

/// Télécharge les cartes hors ligne région par région, avec une progression
/// globale par étapes (comme Google Maps).
///
/// Une seule boucle de téléchargement à la fois : pause, reprise et annulation
/// sont pilotées directement sur l'instance FMTC active, ce qui évite les
/// double-téléchargements lorsque le réseau coupe puis revient.
class TileDownloadService {
  TileDownloadService() : _store = FMTCStore('kinshasa');

  static const Object _instanceId = 'kinflow_download';

  final FMTCStore _store;

  final StreamController<double> _progressController =
      StreamController<double>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  final StreamController<String> _tacheTermineeController =
      StreamController<String>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<DownloadProgress>? _downloadProgressSub;
  StreamSubscription<TileEvent>? _tileEventsSub;

  List<TacheTuiles> _tachesEnCours = const [];
  bool _isDownloading = false;
  bool _pauseManuelle = false;
  bool _pauseReseau = false;
  bool _enAttenteReseau = false;
  int _runId = 0;
  int _etapeCourante = 0;

  /// Progression globale de 0 à 100.
  Stream<double> get progress => _progressController.stream;

  /// Message d'état lisible (ex. « Étape 2/5 : Kinshasa (42%) »).
  Stream<String> get status => _statusController.stream;

  /// Nom de la région venant de terminer son téléchargement.
  Stream<String> get tacheTerminee => _tacheTermineeController.stream;

  bool get isDownloading => _isDownloading;
  bool get isPaused => _pauseManuelle || _pauseReseau;
  int get etapeCourante => _etapeCourante;
  List<TacheTuiles> get tachesEnCours => _tachesEnCours;

  /// Télécharge toutes les régions de KinFlow.
  Future<void> start() => telecharger(listTachesKinflow);

  /// Lance (ou ignore si déjà en cours) le téléchargement des régions données.
  Future<void> telecharger(List<TacheTuiles> taches) async {
    if (_isDownloading) return;
    if (taches.isEmpty) return;
    _tachesEnCours = List.of(taches);
    _etapeCourante = 0;
    _pauseManuelle = false;
    _pauseReseau = false;

    if (!await _estConnecte()) {
      _enAttenteReseau = true;
      _statusController.add('Pas de connexion internet');
      Journal.a('TUILES',
          'Téléchargement en attente : aucune connexion internet');
      _activerEcouteReseau();
      return;
    }

    _enAttenteReseau = false;
    _isDownloading = true;
    _runId++;
    final runId = _runId;
    _activerEcouteReseau();

    Journal.i('TUILES', 'Téléchargement des cartes hors ligne démarré', {
      'regions': taches.length,
    });

    try {
      await _boucle(runId);
    } catch (e, st) {
      log('[TileDownload] ERREUR téléchargement: $e');
      log('[TileDownload] Stack: $st');
      Journal.e('TUILES', 'Le téléchargement des cartes a échoué', {
        'erreur': '$e',
      });
      if (runId == _runId) {
        _statusController.add('Erreur : $e');
      }
    } finally {
      if (runId == _runId) {
        _isDownloading = false;
        _pauseManuelle = false;
        _pauseReseau = false;
        _connectivitySub?.cancel();
        _connectivitySub = null;
      }
    }
  }

  Future<void> _boucle(int runId) async {
    var totalGlobal = 0;
    try {
      for (final tache in _tachesEnCours) {
        if (runId != _runId) return;
        totalGlobal += await _store.download.countTiles(_regionDe(tache));
      }
    } catch (e) {
      Journal.e('TUILES', 'Impossible d\'accéder au cache de cartes', {
        'erreur': '$e',
      });
      _statusController.add('Erreur : cache de cartes indisponible');
      return;
    }

    if (totalGlobal <= 0) {
      _progressController.add(100);
      _statusController.add('Cartes déjà à jour');
      return;
    }

    var effectue = 0;
    for (var i = 0; i < _tachesEnCours.length; i++) {
      if (runId != _runId) return;
      final tache = _tachesEnCours[i];

      int nbTache;
      try {
        nbTache = await _store.download.countTiles(_regionDe(tache));
      } catch (e) {
        Journal.a('TUILES', 'Comptage impossible pour « ${tache.nom} »', {
          'erreur': '$e',
        });
        continue;
      }
      if (nbTache <= 0) continue;

      _etapeCourante = i + 1;
      var partiel = 0;
      try {
        await _telechargerUne(
          tache,
          (p) {
            partiel = p.attemptedTilesCount;
            final globale = (effectue + partiel) / totalGlobal * 100;
            _progressController.add(globale.clamp(0, 100));
            _statusController.add(
              'Étape ${i + 1}/${_tachesEnCours.length} : ${tache.nom} '
              '(${p.percentageProgress.clamp(0, 100).toStringAsFixed(0)}%)',
            );
          },
        );
      } catch (e) {
        Journal.e('TUILES', 'Échec du téléchargement « ${tache.nom} »', {
          'erreur': '$e',
        });
      }
      if (runId != _runId) return;
      effectue += partiel;
      _tacheTermineeController.add(tache.nom);
    }

    _progressController.add(100);
    _statusController.add('Téléchargement terminé');
    Journal.s('TUILES', 'Téléchargement des cartes terminé');
  }

  Future<void> _telechargerUne(
    TacheTuiles tache,
    void Function(DownloadProgress) onProgress,
  ) async {
    const maxRetries = 2;
    for (var tentative = 0; tentative <= maxRetries; tentative++) {
      final (:downloadProgress, :tileEvents) = _store.download.startForeground(
        region: _regionDe(tache),
        parallelThreads: 4,
        skipExistingTiles: true,
        skipSeaTiles: true,
        retryFailedRequestTiles: true,
        instanceId: _instanceId,
      );

      // Mesure des méga-octets réellement téléchargés par cette région :
      // la taille cumulée des tuiles réussies (successfulTilesSize) progresse
      // au fil des tuiles récupérées sur le réseau. On accumule les deltas
      // pour ne compter chaque tuile qu'une seule fois.
      var taillePrecedente = 0.0;
      _downloadProgressSub = downloadProgress.listen(
        (p) {
          final taille = p.successfulTilesSize;
          final delta = (taille - taillePrecedente).round();
          if (delta > 0) {
            DataUsageService.instance.enregistrer(
              CategorieData.cartes,
              octetsRecus: delta,
            );
          }
          taillePrecedente = taille;
          onProgress(p);
        },
        onError: (_) {},
      );
      _tileEventsSub = tileEvents.listen((_) {}, onError: (_) {});

      try {
        await downloadProgress.last.timeout(const Duration(minutes: 30));
        return;
      } on TimeoutException {
        Journal.e('TUILES', 'Délai dépassé sur la région « ${tache.nom} »',
            {'delai': '30 min'});
        await _store.download.cancel(instanceId: _instanceId);
        return;
      } catch (e) {
        await _downloadProgressSub?.cancel();
        await _tileEventsSub?.cancel();
        _downloadProgressSub = null;
        _tileEventsSub = null;
        if (tentative < maxRetries) {
          final delai = Duration(seconds: 5 * (tentative + 1));
          Journal.a('TUILES', 'Erreur sur « ${tache.nom} », nouvelle tentative dans ${delai.inSeconds} s', {
            'erreur': '$e',
          });
          await _store.download.cancel(instanceId: _instanceId);
          await Future<void>.delayed(delai);
        } else {
          rethrow;
        }
      } finally {
        await _downloadProgressSub?.cancel();
        await _tileEventsSub?.cancel();
        _downloadProgressSub = null;
        _tileEventsSub = null;
      }
    }
  }

  /// Met en pause le téléchargement en cours.
  Future<void> pause() async {
    if (!_isDownloading || isPaused) return;
    _pauseManuelle = true;
    await _store.download.pause(instanceId: _instanceId);
    _statusController.add('Téléchargement en pause');
  }

  /// Reprend le téléchargement mis en pause manuellement.
  void resume() {
    if (!_isDownloading || !_pauseManuelle || _pauseReseau) return;
    _pauseManuelle = false;
    _store.download.resume(instanceId: _instanceId);
    _statusController.add('Reprise du téléchargement...');
  }

  /// Annule le téléchargement en cours ou l'attente réseau.
  Future<void> cancel() async {
    _runId++;
    _enAttenteReseau = false;
    _pauseManuelle = false;
    _pauseReseau = false;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    if (_isDownloading) {
      await _store.download.cancel(instanceId: _instanceId);
      _isDownloading = false;
      _progressController.add(0);
    }
    _statusController.add('Téléchargement annulé');
  }

  Future<bool> _estConnecte() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  void _activerEcouteReseau() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final connecte = results.any((r) => r != ConnectivityResult.none);

      if (!connecte) {
        if (_isDownloading && !_pauseReseau && !_pauseManuelle) {
          _pauseReseau = true;
          unawaited(_store.download.pause(instanceId: _instanceId));
          _statusController.add('Réseau perdu - téléchargement en pause');
        }
        return;
      }

      if (_pauseReseau && _isDownloading) {
        _pauseReseau = false;
        _store.download.resume(instanceId: _instanceId);
        _statusController.add('Réseau rétabli - reprise...');
      } else if (_enAttenteReseau) {
        _enAttenteReseau = false;
        unawaited(telecharger(_tachesEnCours));
      }
    });
  }

  DownloadableRegion _regionDe(TacheTuiles tache) =>
      RectangleRegion(tache.limites).toDownloadable(
        minZoom: tache.minZoom,
        maxZoom: tache.maxZoom,
        options: TileLayer(
          urlTemplate: tache.urlTemplate,
          userAgentPackageName: 'com.kinflow.kinflow',
        ),
      );

  Future<void> dispose() async {
    await _connectivitySub?.cancel();
    await _downloadProgressSub?.cancel();
    await _tileEventsSub?.cancel();
    await _store.download.cancel(instanceId: _instanceId);
    await _progressController.close();
    await _statusController.close();
    await _tacheTermineeController.close();
  }
}
