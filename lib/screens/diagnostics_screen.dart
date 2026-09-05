import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/data_usage_service.dart';
import '../services/diagnostics_service.dart';

/// Fenêtre « Mon application » : lecture en direct du journal de diagnostic.
/// Les entrées sont listées dans l'ordre chronologique (la plus ancienne en
/// haut), filtrables par module, par niveau et par recherche texte.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() =>
      _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final ScrollController _defilement = ScrollController();

  String? _moduleFiltre;
  NiveauJournal? _niveauFiltre;
  String _recherche = '';
  bool _auFond = true;

  @override
  void initState() {
    super.initState();
    Journal.instance.addListener(_surMiseAJour);
    _defilement.addListener(_surDefilement);
    WidgetsBinding.instance.addPostFrameCallback((_) => _allerAuFond());
    Journal.instance.marquerErreursVues();
  }

  @override
  void dispose() {
    Journal.instance.removeListener(_surMiseAJour);
    _defilement.removeListener(_surDefilement);
    _defilement.dispose();
    super.dispose();
  }

  void _surDefilement() {
    final controleur = _defilement;
    if (!controleur.hasClients) return;
    final auFond = controleur.position.maxScrollExtent -
            controleur.offset <
        60;
    if (auFond != _auFond) setState(() => _auFond = auFond);
  }

  void _surMiseAJour() {
    if (!_mounted) return;
    setState(() {});
    // La fenêtre est ouverte : tout ce qui arrive est vu sur place.
    Journal.instance.marquerErreursVues();
    if (_auFond) WidgetsBinding.instance.addPostFrameCallback((_) => _allerAuFond());
  }

  bool get _mounted => mounted;

  void _allerAuFond() {
    if (!_defilement.hasClients) return;
    _defilement.jumpTo(_defilement.position.maxScrollExtent);
  }

  /// Plafond d'affichage : au-delà, seules les plus récentes sont rendues.
  /// Le rapport complet reste intégralement disponible via l'export.
  static const int _maxAffichees = 400;

  List<EntreeJournal> get _entreesFiltrees {
    final requete = _recherche.toLowerCase().trim();
    final resultats = Journal.instance.entrees.where((entree) {
      if (_moduleFiltre != null && entree.module != _moduleFiltre) {
        return false;
      }
      if (_niveauFiltre != null && entree.niveau != _niveauFiltre) {
        return false;
      }
      if (requete.isNotEmpty &&
          !entree.message.toLowerCase().contains(requete) &&
          !entree.detailsFormates.toLowerCase().contains(requete)) {
        return false;
      }
      return true;
    }).toList();
    if (resultats.length > _maxAffichees) {
      return resultats.sublist(resultats.length - _maxAffichees);
    }
    return resultats;
  }

  @override
  Widget build(BuildContext context) {
    final entrees = _entreesFiltrees;
    final sombre =
        Theme.of(context).brightness == Brightness.dark;
    final couleurTexte = sombre ? Colors.white : Colors.black;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon application'),
        actions: [
          IconButton(
            tooltip: 'Copier tout le rapport',
            icon: const Icon(Icons.copy_all),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: Journal.instance.exporterTexte()),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Rapport complet copié. Colle-le pour analyse.',
                    ),
                  ),
                );
              }
            },
          ),
          IconButton(
            tooltip: 'Vider le journal',
            icon: const Icon(Icons.delete_sweep),
            onPressed: Journal.instance.vide
                ? null
                : () {
                    Journal.instance.vider();
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          _panneauConsoData(),
          const Divider(height: 1),
          _barreFiltres(couleurTexte),
          const Divider(height: 1),
          Expanded(
            child: entrees.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Aucun événement pour ce filtre.\n\n'
                        'Utilise l\'application normalement : chaque action '
                        '(position, carte, itinéraire...) s\'inscrira ici.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: couleurTexte.withValues(alpha: 0.6)),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _defilement,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: entrees.length,
                    itemBuilder: (context, index) =>
                        _tuile(entrees[index], sombre),
                  ),
          ),
        ],
      ),
      floatingActionButton: _auFond
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _defilement.animateTo(
                _defilement.position.maxScrollExtent,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              ),
              icon: const Icon(Icons.arrow_downward),
              label: const Text('Dernier événement'),
            ),
    );
  }

  /// Panneau temporaire de diagnostic : consommation de données mobiles par
  /// fonction, cumulée depuis l'ouverture de l'application.
  Widget _panneauConsoData() {
    final usage = DataUsageService.instance;
    return ListenableBuilder(
      listenable: usage,
      builder: (context, _) {
        final lignes = [
          for (final c in CategorieData.values)
            (c.libelle, usage.octetsRecusPour(c), usage.octetsEnvoyesPour(c)),
        ];
        final totalRecus = usage.totalOctetsRecus;
        final totalEnvoyes = usage.totalOctetsEnvoyes;
        return Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.data_usage, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'Consommation de données (depuis l\'ouverture)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    '↓ ${DataUsageService.enMo(totalRecus)}'
                    '  ↑ ${DataUsageService.enMo(totalEnvoyes)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final (libelle, recus, envoyes) in lignes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          libelle,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      Text(
                        '↓ ${DataUsageService.enMo(recus)}'
                        '   ↑ ${DataUsageService.enMo(envoyes)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _barreFiltres(Color couleurTexte) {
    final modules = Journal.instance.modules;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _moduleFiltre,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Module',
                    border: OutlineInputBorder(),
                    isCollapsed: false,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Tous les modules'),
                    ),
                    for (final module in modules)
                      DropdownMenuItem<String?>(
                        value: module,
                        child: Text(module),
                      ),
                  ],
                  onChanged: (valeur) =>
                      setState(() => _moduleFiltre = valeur),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Rechercher',
                    isDense: true,
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search, size: 20),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  onChanged: (valeur) => setState(() => _recherche = valeur),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              _puceNiveau(null, 'Tous', couleurTexte),
              _puceNiveau(NiveauJournal.info, 'Info', couleurTexte),
              _puceNiveau(NiveauJournal.succes, 'OK', couleurTexte),
              _puceNiveau(NiveauJournal.attention, 'Attention', couleurTexte),
              _puceNiveau(NiveauJournal.erreur, 'Erreur', couleurTexte),
            ],
          ),
        ],
      ),
    );
  }

  Widget _puceNiveau(NiveauJournal? niveau, String libelle, Color couleurTexte) {
    final selectionnee = _niveauFiltre == niveau;
    return ChoiceChip(
      label: Text(libelle,
          style: TextStyle(fontSize: 12, color: selectionnee ? null : couleurTexte)),
      selected: selectionnee,
      onSelected: (_) => setState(() => _niveauFiltre = niveau),
      visualDensity: VisualDensity.compact,
    );
  }

  Color _couleurNiveau(NiveauJournal niveau, bool sombre) => switch (niveau) {
        NiveauJournal.info => Colors.blue,
        NiveauJournal.succes => Colors.green,
        NiveauJournal.attention => Colors.orange,
        NiveauJournal.erreur => Colors.red,
      };

  IconData _iconeNiveau(NiveauJournal niveau) => switch (niveau) {
        NiveauJournal.info => Icons.info_outline,
        NiveauJournal.succes => Icons.check_circle_outline,
        NiveauJournal.attention => Icons.warning_amber_outlined,
        NiveauJournal.erreur => Icons.error_outline,
      };

  Widget _tuile(EntreeJournal entree, bool sombre) {
    final couleur = _couleurNiveau(entree.niveau, sombre);
    final details = entree.detailsFormates;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child:
                  Icon(_iconeNiveau(entree.niveau), size: 16, color: couleur),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${entree.heureFormatee} ',
                          style: TextStyle(
                            fontSize: 11,
                            fontFeatures: [const FontFeature.tabularFigures()],
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.55),
                          ),
                        ),
                        TextSpan(
                          text: entree.module,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: couleur,
                          ),
                        ),
                        if (entree.precedente)
                          TextSpan(
                            text: '  (session précédente)',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    entree.message,
                    style: const TextStyle(fontSize: 13.5, height: 1.25),
                  ),
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      details,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
