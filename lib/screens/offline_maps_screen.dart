import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show TileLayer;
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart'
    show tileDownloadService, initFmtc, waitForFmtc, fmtcSucceeded;
import '../services/diagnostics_service.dart';
import '../services/tile_regions.dart';

class _CarteOffline {
  final String nom;
  final String description;
  final IconData icone;
  final TacheTuiles tache;
  final double octetsMoyens;
  const _CarteOffline({
    required this.nom,
    required this.description,
    required this.icone,
    required this.tache,
    required this.octetsMoyens,
  });
}

final List<_CarteOffline> _cartes = [
  _CarteOffline(
    nom: 'Kinshasa',
    description: 'Rues et quartiers de Kinshasa (zoom 10 à 16)',
    icone: Icons.map,
    tache: tacheKinshasa,
    octetsMoyens: 25,
  ),
  _CarteOffline(
    nom: 'Satellite',
    description: 'Imagerie satellite de Kinshasa (zoom 13 à 16)',
    icone: Icons.satellite_alt,
    tache: tacheSatellite,
    octetsMoyens: 45,
  ),
  _CarteOffline(
    nom: 'Étiquettes',
    description: 'Noms des rues et des lieux (zoom 13 à 16)',
    icone: Icons.label,
    tache: tacheEtiquettes,
    octetsMoyens: 15,
  ),
  _CarteOffline(
    nom: 'RDC',
    description:
        "Vue générale de la République démocratique du Congo (zoom 7 à 9)",
    icone: Icons.map_outlined,
    tache: tacheRdc,
    octetsMoyens: 20,
  ),
  _CarteOffline(
    nom: 'Afrique',
    description: "Vue d'ensemble du continent africain (zoom 2 à 6)",
    icone: Icons.public,
    tache: tacheAfrique,
    octetsMoyens: 15,
  ),
];

class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key});

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  final FMTCStore _store = FMTCStore('kinshasa');

  bool _pret = false;
  bool _initialisationEnCours = true;

  final Map<String, int> _tuilesEstimees = {};
  final Map<String, DateTime> _telechargees = {};
  int _tuilesStore = 0;
  double _tailleStoreKo = 0;

  double _progress = 0;
  String _status = '';

  StreamSubscription<double>? _progressSub;
  StreamSubscription<String>? _statusSub;
  StreamSubscription<String>? _tacheTermineeSub;

  @override
  void initState() {
    super.initState();
    _progressSub = tileDownloadService.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    _statusSub = tileDownloadService.status.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _tacheTermineeSub = tileDownloadService.tacheTerminee.listen((nom) {
      if (mounted) setState(() => _telechargees[nom] = DateTime.now());
      _sauvegarderTelechargees();
      _rafraichirStats();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialiser());
  }

  Future<void> _initialiser() async {
    try {
      if (!kIsWeb) {
        unawaited(initFmtc());
        try {
          await waitForFmtc.timeout(const Duration(seconds: 30));
        } catch (_) {}
      }
      await _chargerTelechargees();
      await _rafraichirStats();
      await _calculerTailles();
      if (!mounted) return;
      setState(() {
        _pret = kIsWeb || fmtcSucceeded;
        _initialisationEnCours = false;
      });
    } catch (e) {
      debugPrint('[KinFlow] Erreur init cartes hors ligne: $e');
      if (!mounted) return;
      setState(() {
        _pret = false;
        _initialisationEnCours = false;
      });
    }
  }

  Future<void> _chargerTelechargees() async {
    final prefs = await SharedPreferences.getInstance();
    final brut = prefs.getString('cartes_offline');
    final data = brut == null ? <String, dynamic>{} : json.decode(brut);
    final noms = _cartes.map((c) => c.nom).toSet();
    _telechargees.clear();
    for (final entry in (data as Map<String, dynamic>).entries) {
      if (!noms.contains(entry.key)) continue;
      final date = DateTime.tryParse(entry.value.toString());
      if (date != null) _telechargees[entry.key] = date;
    }
  }

  Future<void> _sauvegarderTelechargees() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      for (final e in _telechargees.entries) e.key: e.value.toIso8601String(),
    };
    await prefs.setString('cartes_offline', json.encode(data));
  }

  Future<void> _rafraichirStats() async {
    try {
      final stats = await _store.stats.all;
      if (!mounted) return;
      setState(() {
        _tuilesStore = stats.length;
        _tailleStoreKo = stats.size;
      });
    } catch (_) {}
  }

  Future<void> _calculerTailles() async {
    for (final carte in _cartes) {
      final region = RectangleRegion(carte.tache.limites).toDownloadable(
        minZoom: carte.tache.minZoom,
        maxZoom: carte.tache.maxZoom,
        options: TileLayer(
          urlTemplate: carte.tache.urlTemplate,
          userAgentPackageName: 'com.kinflow.kinflow',
        ),
      );
      final nb = await _store.download.countTiles(region);
      if (!mounted) return;
      setState(() => _tuilesEstimees[carte.nom] = nb);
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _statusSub?.cancel();
    _tacheTermineeSub?.cancel();
    super.dispose();
  }

  void _telechargerUneCarte(_CarteOffline carte) {
    Journal.i('TUILES', 'Téléchargement d\'une région demandé', {
      'region': carte.nom,
    });
    setState(() => _progress = 0);
    unawaited(tileDownloadService.telecharger([carte.tache]));
  }

  void _telechargerTout() {
    Journal.i('TUILES', 'Téléchargement de toutes les régions demandé');
    setState(() => _progress = 0);
    unawaited(tileDownloadService.start());
  }

  Future<void> _effacerTout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Effacer les cartes',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        content: Text(
          'Toutes les tuiles téléchargées seront supprimées. Vous devrez les '
          'retélécharger pour utiliser les cartes hors ligne.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Annuler',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Effacer',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    Journal.a('TUILES', 'Effacement de toutes les cartes hors ligne confirmé');
    try {
      await tileDownloadService.cancel();
      await _store.manage.reset();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('cartes_offline');
      _telechargees.clear();
      await _rafraichirStats();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cartes hors ligne effacées.')),
      );
    } catch (e) {
      debugPrint('[KinFlow] Erreur effacement cartes: $e');
      Journal.e('TUILES', 'Effacement des cartes impossible', {'erreur': '$e'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'effacer les cartes.')),
      );
    }
  }

  String _formaterMo(double ko) {
    if (ko < 1) return '0 Mo';
    return '${(ko / 1024).toStringAsFixed(1)} Mo';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cartes hors ligne'), centerTitle: true),
      body: _initialisationEnCours
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Préparation des cartes...'),
                ],
              ),
            )
          : !_pret
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Les cartes hors ligne ne sont pas disponibles sur '
                  'cette version.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                if (tileDownloadService.isDownloading) _enTeteProgression(),
                _enTeteStockage(),
                Expanded(
                  child: ListView.separated(
                    itemCount: _cartes.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      return _ligneCarte(_cartes[index]);
                    },
                  ),
                ),
                _barreActions(),
              ],
            ),
    );
  }

  Widget _enTeteProgression() {
    final enCours = tileDownloadService.isDownloading;
    final etape = tileDownloadService.etapeCourante;
    final total = tileDownloadService.tachesEnCours.length;
    final nomEtape = enCours && etape > 0 && etape <= total
        ? tileDownloadService.tachesEnCours[etape - 1].nom
        : '';

    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            enCours ? 'Étape $etape sur $total : $nomEtape' : _status,
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: (_progress / 100).clamp(0, 1),
            backgroundColor: colorScheme.onSurface.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(colorScheme.primary),
            minHeight: 5,
          ),
          const SizedBox(height: 4),
          Text(
            _status,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _enTeteStockage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$_tuilesStore tuiles en cache',
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            _formaterMo(_tailleStoreKo),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _ligneCarte(_CarteOffline carte) {
    final enCours =
        tileDownloadService.isDownloading &&
        tileDownloadService.etapeCourante > 0 &&
        tileDownloadService.tachesEnCours.length >=
            tileDownloadService.etapeCourante &&
        tileDownloadService
                .tachesEnCours[tileDownloadService.etapeCourante - 1]
                .nom ==
            carte.nom;

    final estimee = _tuilesEstimees[carte.nom];
    final telechargee = _telechargees[carte.nom];
    final tailleMo = estimee == null
        ? null
        : (estimee * carte.octetsMoyens / 1024).toStringAsFixed(1);

    return ListTile(
      leading: Icon(carte.icone, size: 32),
      title: Text(
        carte.nom,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(carte.description, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 2),
          Text(
            tailleMo == null
                ? 'Taille en cours de calcul...'
                : '≈ $tailleMo Mo',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: enCours
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : telechargee != null
          ? const Icon(Icons.check_circle, color: Colors.green)
          : SizedBox(
              width: 96,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: tileDownloadService.isDownloading
                    ? null
                    : () => _telechargerUneCarte(carte),
                child: const Text(
                  'Télécharger',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ),
      isThreeLine: true,
    );
  }

  Widget _barreActions() {
    if (tileDownloadService.isDownloading) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: tileDownloadService.isPaused
                      ? tileDownloadService.resume
                      : () => unawaited(tileDownloadService.pause()),
                  icon: Icon(
                    tileDownloadService.isPaused
                        ? Icons.play_arrow
                        : Icons.pause,
                  ),
                  label: Text(
                    tileDownloadService.isPaused ? 'Reprendre' : 'Pause',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(tileDownloadService.cancel()),
                  icon: const Icon(Icons.close),
                  label: const Text('Annuler'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _telechargerTout,
                icon: const Icon(Icons.download),
                label: const Text('Tout télécharger'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _tuilesStore > 0 ? _effacerTout : null,
                icon: const Icon(Icons.delete_sweep),
                label: const Text('Effacer tout'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
