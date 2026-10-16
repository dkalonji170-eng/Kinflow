import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/phrases_guidage.dart';

/// Écran « Guidage vocal » : l'utilisateur remplace chaque phrase prononcée
/// par sa propre formule (toujours lue par la voix du téléphone). Les
/// modifications sont enregistrées immédiatement et s'appliquent au prochain
/// itinéraire affiché.
class VoixGuidageScreen extends StatefulWidget {
  const VoixGuidageScreen({super.key});

  @override
  State<VoixGuidageScreen> createState() => _VoixGuidageScreenState();
}

class _VoixGuidageScreenState extends State<VoixGuidageScreen> {
  late final Map<String, TextEditingController> _controleurs;
  final Map<String, String> _valeurs = {};
  FlutterTts? _tts;
  Timer? _debouneSauvegarde;
  bool _pret = false;

  @override
  void initState() {
    super.initState();
    _controleurs = {
      for (final p in PhrasesGuidage.editables) p.cle: TextEditingController(),
    };
    _charger();
    _initialiserTts();
  }

  @override
  void dispose() {
    _debouneSauvegarde?.cancel();
    _tts?.stop();
    for (final c in _controleurs.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _charger() async {
    final phrases = await PhrasesGuidage.charger();
    if (!mounted) return;
    setState(() {
      for (final e in phrases.entries) {
        _valeurs[e.key] = e.value;
        _controleurs[e.key]?.text = e.value;
      }
      _pret = true;
    });
  }

  Future<void> _initialiserTts() async {
    try {
      final tts = FlutterTts();
      await tts.setLanguage('fr-FR');
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1.0);
      _tts = tts;
    } catch (_) {
      // Synthétiseur indisponible (plateforme, émulateur) : le bouton
      // « écouter » n'affichera qu'un message.
      _tts = null;
    }
  }

  Future<void> _ecouter(String cle) async {
    final texte = _controleurs[cle]?.text.trim() ?? '';
    if (texte.isEmpty) return;
    final tts = _tts;
    if (tts == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Voix indisponible sur cet appareil.")),
      );
      return;
    }
    try {
      await tts.stop();
      await tts.speak(texte);
    } catch (_) {
      // Ignoré : le guidage vocal se neutralise s'il n'y a pas de voix.
    }
  }

  /// Une saisie modifie une valeur : on sauvegarde en différé pour ne pas
  /// écrire sur disque à chaque frappe.
  void _surChangement(String cle, String texte) {
    _valeurs[cle] = texte;
    _debouneSauvegarde?.cancel();
    _debouneSauvegarde = Timer(const Duration(milliseconds: 400), () {
      PhrasesGuidage.sauvegarder(_valeurs);
    });
  }

  Future<void> _retablirDefauts() async {
    await PhrasesGuidage.reinitialiser();
    final phrases = PhrasesGuidage.parDefaut();
    for (final e in phrases.entries) {
      _valeurs[e.key] = e.value;
      _controleurs[e.key]?.text = e.value;
    }
    _debouneSauvegarde?.cancel();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Phrases par défaut rétablies."),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Guidage vocal"), centerTitle: true),
      body: _pret
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  "Composez vos propres phrases : c'est la voix du "
                  "téléphone qui les lira pendant le guidage. Elles "
                  "s'appliquent au prochain itinéraire.",
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                const _EnTeteSection('Au départ'),
                ..._champs('depart'),
                const _EnTeteSection('Tournez à gauche'),
                ..._champs('gauche'),
                const _EnTeteSection('Tournez à droite'),
                ..._champs('droite'),
                const _EnTeteSection('Faites demi-tour'),
                ..._champs('demitour'),
                const _EnTeteSection('Arrivée'),
                ..._champs('arrivee'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _retablirDefauts,
                  icon: const Icon(Icons.restore),
                  label: const Text("Rétablir les phrases par défaut"),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  List<Widget> _champs(String groupe) {
    return [
      for (final p in PhrasesGuidage.editables
          .where((p) => p.cle == groupe || p.cle.startsWith('${groupe}_')))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _controleurs[p.cle],
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: p.titre,
                    helperText: p.aide,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (texte) => _surChangement(p.cle, texte),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Écouter',
                icon: const Icon(Icons.volume_up),
                onPressed: () => _ecouter(p.cle),
              ),
            ],
          ),
        ),
    ];
  }
}

class _EnTeteSection extends StatelessWidget {
  final String titre;

  const _EnTeteSection(this.titre);

  @override
  Widget build(BuildContext context) {
    final couleur = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        titre,
        style: TextStyle(
          color: couleur,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }
}