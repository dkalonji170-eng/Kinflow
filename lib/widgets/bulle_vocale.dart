import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';
import '../theme/kinflow_theme.dart';

/// Bulle d'un message vocal : bouton lecture/pause, barre de progression et
/// durée. L'audio est lu soit depuis un fichier local (message en cours d'envoi),
/// soit depuis une URL signée résolue à la volée (message déjà reçu).
class BulleVocale extends StatefulWidget {
  const BulleVocale({
    super.key,
    this.cheminLocal,
    this.resoudreSource,
    required this.dureeMs,
    required this.moi,
    required this.heure,
    this.indicateur,
  });

  /// Fichier déjà présent sur l'appareil (optimiste : message que je viens
  /// d'enregistrer, lu immédiatement sans passer par le réseau).
  final String? cheminLocal;

  /// Résout la source jouable (URL signée, chemin distant…) pour les messages
  /// déjà stockés côté serveur.
  final Future<String?> Function()? resoudreSource;

  final int dureeMs;
  final bool moi;
  final String heure;
  final Widget? indicateur;

  @override
  State<BulleVocale> createState() => _BulleVocaleState();
}

class _BulleVocaleState extends State<BulleVocale> {
  final AudioPlayer _lecteur = AudioPlayer();
  bool _lectureEnCours = false;
  bool _chargementSource = false;
  String? _source;
  bool _sourceEstUrl = false;
  Duration _position = Duration.zero;
  Duration _duree = Duration.zero;
  StreamSubscription<PlayerState>? _etatSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _dureeSub;

  @override
  void initState() {
    super.initState();
    _duree = Duration(milliseconds: widget.dureeMs.clamp(0, 3600000));
    _chercherFichierLocal();
    _etatSub = _lecteur.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _lectureEnCours = s == PlayerState.playing);
      if (s == PlayerState.completed) {
        setState(() => _position = Duration.zero);
      }
    });
    _posSub = _lecteur.onPositionChanged.listen((d) {
      if (!mounted) return;
      setState(() => _position = d);
    });
    _dureeSub = _lecteur.onDurationChanged.listen((d) {
      if (!mounted || d == Duration.zero) return;
      setState(() => _duree = d);
    });
  }

  /// Vérifie (sans réseau) si le fichier local existe encore : il permet une
  /// lecture immédiate, même hors connexion, pour un envoi tout juste fait.
  Future<void> _chercherFichierLocal() async {
    final local = widget.cheminLocal;
    if (local == null || local.isEmpty) return;
    if (await File(local).exists()) {
      if (!mounted) return;
      setState(() {
        _source = local;
        _sourceEstUrl = false;
      });
    }
  }

  /// Résout la source réseau (URL signée) à la demande, uniquement au premier
  /// appui sur lecture : pas d'appel inutile pour les bulles jamais écoutées.
  Future<void> _resoudreSourceDistante() async {
    if (_source != null || _chargementSource) return;
    final resolver = widget.resoudreSource;
    if (resolver == null) return;
    setState(() => _chargementSource = true);
    String? src;
    try {
      src = await resolver();
    } catch (e) {
      Journal.e('SOCIAL', 'Résolution de l\'adresse du vocal échouée', {
        'erreur': '$e',
      });
      src = null;
    }
    if (!mounted) return;
    setState(() {
      _chargementSource = false;
      if (src != null && src.isNotEmpty) {
        _source = src;
        _sourceEstUrl = src.startsWith('http://') || src.startsWith('https://');
      }
    });
    if (src == null || src.isEmpty) {
      Journal.a('SOCIAL', 'Adresse du vocal introuvable (URL signée)');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message vocal indisponible.')),
        );
      }
    }
  }

  Future<void> _basculerLecture() async {
    if (_source == null) {
      await _chercherFichierLocal();
      if (_source == null) await _resoudreSourceDistante();
      if (_source == null) return; // le message d'échec a déjà été affiché
    }
    if (_lectureEnCours) {
      await _lecteur.pause();
    } else {
      try {
        if (_sourceEstUrl) {
          await _lecteur.play(UrlSource(_source!));
        } else {
          await _lecteur.play(DeviceFileSource(_source!));
        }
      } catch (e) {
        Journal.e('SOCIAL', 'Lecture du vocal impossible', {
          'erreur': '$e',
          'url': _sourceEstUrl ? 'oui' : 'non',
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Lecture impossible.')),
          );
        }
      }
    }
  }

  String _formaterDuree(Duration d) {
    final sec = d.inSeconds % 60;
    final min = d.inMinutes % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _etatSub?.cancel();
    _posSub?.cancel();
    _dureeSub?.cancel();
    _lecteur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moi = widget.moi;
    final fond = moi ? KinColors.vertArrivee : KinColors.bleu;
    final total =
        _duree.inMilliseconds == 0 ? widget.dureeMs : _duree.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, total);
    final progress = total <= 0 ? 0.0 : (posMs / total).clamp(0.0, 1.0);
    // En lecture : temps écoulé ; à l'arrêt : durée totale du message.
    final texteDuree =
        _formaterDuree(Duration(milliseconds: _lectureEnCours ? posMs : total));

    return Align(
      alignment: moi ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
          minWidth: 168,
        ),
        decoration: BoxDecoration(
          color: fond,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: Colors.white24,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: _chargementSource
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            _lectureEnCours ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                          ),
                    onPressed: _chargementSource ? null : _basculerLecture,
                    tooltip: _lectureEnCours ? 'Pause' : 'Lire',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: Colors.white30,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        texteDuree,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.heure,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                if (moi && widget.indicateur != null) ...[
                  const SizedBox(width: 4),
                  widget.indicateur!,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
