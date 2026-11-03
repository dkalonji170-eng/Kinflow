import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../utils/forme_onde.dart';

/// Enregistreur de messages vocaux.
///
/// Il capture en plus l'AMPLITUDE du micro pendant l'enregistrement : ces
/// mesures deviennent la forme d'onde dessinée dans la bulle (comme sur
/// WhatsApp, les barres suivent le volume de la voix). Sans elles, la bulle
/// afficherait des barres décoratives sans rapport avec l'audio.
class EnregistreurVocal {
  final AudioRecorder _recorder = AudioRecorder();
  String? _chemin;

  /// Mesures d'amplitude (dBFS) relevées pendant l'enregistrement en cours.
  final List<double> _amplitudesDb = [];
  StreamSubscription<Amplitude>? _amplitudeSub;

  /// Formes d'onde du dernier enregistrement terminé (0..100, une valeur par
  /// barre). Vide tant qu'aucun enregistrement n'a abouti.
  List<int> _dernieresFormes = const [];

  /// Une mesure toutes les 100 ms : suffisant pour suivre la parole, sans
  /// saturer la mémoire sur un vocal de plusieurs minutes.
  static const Duration _periodeAmplitude = Duration(milliseconds: 100);

  /// Forme d'onde (0..100) du dernier enregistrement terminé.
  List<int> get formes => _dernieresFormes;

  Future<bool> demarrer() async {
    final has = await _recorder.hasPermission();
    if (!has) return false;
    final dir = await getTemporaryDirectory();
    final chemin =
        '${dir.path}/vocal_${DateTime.now().microsecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: chemin,
    );
    _chemin = chemin;
    _dernieresFormes = const [];
    _amplitudesDb.clear();
    await _amplitudeSub?.cancel();
    // `Amplitude.current` est un niveau en dBFS (négatif). On le relève en
    // continu plutôt qu'à la fin : c'est la seule façon d'obtenir l'enveloppe
    // réelle de la voix.
    _amplitudeSub = _recorder.onAmplitudeChanged(_periodeAmplitude).listen((a) {
      if (a.current.isFinite) _amplitudesDb.add(a.current);
    }, onError: (_) {});
    return true;
  }

  Future<String?> arreter() async {
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    final chemin = await _recorder.stop();
    _chemin = null;
    _dernieresFormes = formeOndeDepuisDb(_amplitudesDb);
    _amplitudesDb.clear();
    return chemin;
  }

  Future<void> annuler() async {
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _amplitudesDb.clear();
    _dernieresFormes = const [];
    try {
      await _recorder.stop();
    } catch (_) {}
    final c = _chemin;
    _chemin = null;
    if (c != null && c.isNotEmpty) {
      try {
        await File(c).delete();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    try {
      await _amplitudeSub?.cancel();
    } catch (_) {}
    _amplitudeSub = null;
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}
