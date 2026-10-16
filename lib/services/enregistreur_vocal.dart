import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class EnregistreurVocal {
  final AudioRecorder _recorder = AudioRecorder();
  String? _chemin;

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
    return true;
  }

  Future<String?> arreter() async {
    final chemin = await _recorder.stop();
    _chemin = null;
    return chemin;
  }

  Future<void> annuler() async {
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
      await _recorder.dispose();
    } catch (_) {}
  }
}
