import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/search_result.dart';
import '../services/ia_service.dart';
import '../theme/kinflow_theme.dart';
import 'traffic_screen.dart';

/// Une bulle de la discussion avec Kinflow.
class _Bulle {
  _Bulle({required this.deIA, required this.texte, this.actions});

  final bool deIA;
  final String texte;

  /// Étiquettes des actions exécutées (ex. « 📍 Marie localisée »), affichées
  /// sous la bulle de Kinflow pour montrer ce qu'il a fait concrètement.
  final List<String>? actions;

  /// Vrai pendant que l'IA « écrit » (indicateur de frappe).
  final bool enCours = false;
}

/// Écran de discussion avec Kinflow, l'ami(e) IA de KinFlow.
///
/// On discute comme avec un ami. Kinflow peut exécuter de vraies actions :
/// localiser un ami, tracer un itinéraire, chercher un lieu, envoyer un
/// message. Chaque action est affichée comme une petite étiquette puis
/// l'IA finalise sa réponse.
class AmiIaScreen extends StatefulWidget {
  const AmiIaScreen({super.key});

  @override
  State<AmiIaScreen> createState() => _AmiIaScreenState();
}

class _AmiIaScreenState extends State<AmiIaScreen> {
  final TextEditingController _saisie = TextEditingController();
  final ScrollController _defilement = ScrollController();
  final IAService _ia = IAService.instance;

  final List<_Bulle> _bulles = [];
  bool _iaEcrit = false;

  @override
  void initState() {
    super.initState();
    if (_bulles.isEmpty) {
      _bulles.add(
        _Bulle(
          deIA: true,
          texte:
              'Salut ! 👋 Je suis Kinflow, ton ami(e) dans KinFlow. '
              'Demande-moi de localiser un ami, de tracer un itinéraire, '
              'de chercher un lieu, ou on peut juste discuter. 😊',
        ),
      );
    }
  }

  @override
  void dispose() {
    _saisie.dispose();
    _defilement.dispose();
    super.dispose();
  }

  void _descendreEnBas() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_defilement.hasClients) return;
      _defilement.animateTo(
        _defilement.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Envoi + traitement des réponses de l'IA
  // ---------------------------------------------------------------------------

  Future<void> _envoyer() async {
    final texte = _saisie.text.trim();
    if (texte.isEmpty || _iaEcrit) return;
    _saisie.clear();
    setState(() => _bulles.add(_Bulle(deIA: false, texte: texte)));
    _descendreEnBas();
    await _demanderIA(texte);
  }

  /// Envoie [texte] à l'IA, exécute les actions demandées, puis laisse l'IA
  /// finaliser sa réponse.
  Future<void> _demanderIA(String texte) async {
    setState(() => _iaEcrit = true);
    _descendreEnBas();

    ReponseIA reponse = await _ia.envoyer(texte);
    if (!mounted) return;

    // Tant que l'IA demande des actions, on les exécute puis on lui renvoie
    // les résultats (elle peut enchaîner plusieurs actions d'affilée).
    while (reponse.actions.isNotEmpty) {
      final (resultats, etiquettes) = await _executerActions(reponse.actions);
      if (!mounted) return;
      setState(() {
        _bulles.add(
          _Bulle(deIA: true, texte: reponse.texte, actions: etiquettes),
        );
      });
      _descendreEnBas();
      reponse = await _ia.repondreAuxActions(resultats);
      if (!mounted) return;
    }

    setState(() => _iaEcrit = false);
    if (reponse.texte.isNotEmpty) {
      setState(() => _bulles.add(_Bulle(deIA: true, texte: reponse.texte)));
    }
    _descendreEnBas();
  }

  /// Exécute une liste d'actions. Retourne les réponses à renvoyer à l'IA
  /// (format functionResponse) et les étiquettes à afficher à l'écran.
  Future<(List<Map<String, dynamic>>, List<String>)> _executerActions(
    List<ActionIA> actions,
  ) async {
    final resultats = <Map<String, dynamic>>[];
    final etiquettes = <String>[];

    for (final action in actions) {
      switch (action.nom) {
        case 'localiser_ami':
          final r = await _actionLocaliserAmi(action.arguments);
          resultats.add(r.$1);
          etiquettes.add(r.$2);
          break;
        case 'itineraire_vers':
          final r = await _actionItineraire(action.arguments);
          resultats.add(r.$1);
          etiquettes.add(r.$2);
          break;
        case 'rechercher_lieu':
          final r = await _actionRechercher(action.arguments);
          resultats.add(r.$1);
          etiquettes.add(r.$2);
          break;
        case 'envoyer_message_ami':
          final r = await _actionEnvoyerMessage(action.arguments);
          resultats.add(r.$1);
          etiquettes.add(r.$2);
          break;
        default:
          resultats.add({
            'nom': action.nom,
            'reponse': {'succes': false, 'erreur': 'fonction_inconnue'},
          });
          etiquettes.add('❓ Action inconnue');
      }
    }
    return (resultats, etiquettes);
  }

  // ---------------------------------------------------------------------------
  // Les 4 actions de Kinflow
  // ---------------------------------------------------------------------------

  /// Localise un ami et ouvre la carte centrée sur lui.
  Future<(Map<String, dynamic>, String)> _actionLocaliserAmi(
    Map<String, dynamic> args,
  ) async {
    final nom = args['nom_ami']?.toString() ?? '';
    final ami = await _ia.localiserAmi(nom);
    if (!mounted) {
      return (
        {
          'nom': 'localiser_ami',
          'reponse': {'succes': false},
        },
        '⛔ Localisation annulée',
      );
    }
    if (ami == null) {
      return (
        {
          'nom': 'localiser_ami',
          'reponse': {'succes': false, 'ami': nom},
        },
        '🔍 Ami(e) « $nom » introuvable',
      );
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TrafficScreen(amiALocaliser: ami),
      ),
    );
    return (
      {
        'nom': 'localiser_ami',
        'reponse': {'succes': true, 'ami': ami.nom},
      },
      '📍 ${ami.nom} localisé(e)',
    );
  }

  /// Trace un itinéraire vers une destination et ouvre la carte.
  Future<(Map<String, dynamic>, String)> _actionItineraire(
    Map<String, dynamic> args,
  ) async {
    final destination = args['destination']?.toString() ?? '';
    final resultats = await _ia.rechercherLieu(destination);
    if (!mounted) {
      return (
        {
          'nom': 'itineraire_vers',
          'reponse': {'succes': false},
        },
        '⛔ Itinéraire annulé',
      );
    }
    if (resultats.isEmpty) {
      return (
        {
          'nom': 'itineraire_vers',
          'reponse': {'succes': false, 'destination': destination},
        },
        '🧭 Destination « $destination » introuvable',
      );
    }
    final lieu = resultats.first;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TrafficScreen(
          arriveeInitiale: LatLng(lieu.latitude, lieu.longitude),
          arriveeNomInitial: lieu.nom,
        ),
      ),
    );
    return (
      {
        'nom': 'itineraire_vers',
        'reponse': {'succes': true, 'destination': lieu.nom},
      },
      '🧭 Itinéraire vers ${lieu.nom}',
    );
  }

  /// Cherche un lieu et affiche les résultats dans la discussion.
  Future<(Map<String, dynamic>, String)> _actionRechercher(
    Map<String, dynamic> args,
  ) async {
    final terme = args['terme']?.toString() ?? '';
    final resultats = await _ia.rechercherLieu(terme);
    if (!mounted) {
      return (
        {
          'nom': 'rechercher_lieu',
          'reponse': {'succes': false},
        },
        '⛔ Recherche annulée',
      );
    }
    if (resultats.isEmpty) {
      return (
        {
          'nom': 'rechercher_lieu',
          'reponse': {'succes': false, 'terme': terme},
        },
        '🔍 Rien trouvé pour « $terme »',
      );
    }
    _afficherResultatsLieux(terme, resultats);
    return (
      {
        'nom': 'rechercher_lieu',
        'reponse': {
          'succes': true,
          'terme': terme,
          'resultats': resultats
              .take(5)
              .map(
                (r) => {
                  'nom': r.nom,
                  'latitude': r.latitude,
                  'longitude': r.longitude,
                },
              )
              .toList(),
        },
      },
      '🔎 ${resultats.length} lieu(x) trouvé(s) pour « $terme »',
    );
  }

  /// Envoie un message à un ami.
  Future<(Map<String, dynamic>, String)> _actionEnvoyerMessage(
    Map<String, dynamic> args,
  ) async {
    final nom = args['nom_ami']?.toString() ?? '';
    final message = args['message']?.toString() ?? '';
    final code = await _ia.envoyerMessageAmi(nom, message);
    if (!mounted) {
      return (
        {
          'nom': 'envoyer_message_ami',
          'reponse': {'succes': false},
        },
        '⛔ Envoi annulé',
      );
    }
    return switch (code) {
      'ok' => (
        {
          'nom': 'envoyer_message_ami',
          'reponse': {'succes': true, 'ami': nom},
        },
        '✉️ Message envoyé à $nom',
      ),
      'ami_introuvable' => (
        {
          'nom': 'envoyer_message_ami',
          'reponse': {'succes': false, 'ami': nom},
        },
        '🔍 Ami(e) « $nom » introuvable',
      ),
      _ => (
        {
          'nom': 'envoyer_message_ami',
          'reponse': {'succes': false, 'erreur': code},
        },
        '⚠️ Envoi à $nom impossible (réseau)',
      ),
    };
  }

  /// Affiche les lieux trouvés dans une feuille, avec bouton « itinéraire ».
  void _afficherResultatsLieux(String terme, List<SearchResult> resultats) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: resultats.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'Résultats pour « $terme »',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              );
            }
            final lieu = resultats[index - 1];
            return ListTile(
              leading: const Icon(Icons.place, color: KinColors.primary),
              title: Text(lieu.nom),
              subtitle: lieu.sousTitre.isEmpty ? null : Text(lieu.sousTitre),
              trailing: const Icon(Icons.directions),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => TrafficScreen(
                      arriveeInitiale: LatLng(lieu.latitude, lieu.longitude),
                      arriveeNomInitial: lieu.nom,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Interface
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [KinColors.primary, KinColors.primaryClair],
                ),
              ),
              child: const Center(
                child: Text('🤖', style: TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Kinflow',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      height: 1.15,
                    ),
                  ),
                  Text(
                    'Ton ami(e) IA',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Nouvelle discussion',
            onPressed: () {
              setState(() {
                _ia.reinitialiser();
                _bulles.clear();
                _bulles.add(
                  _Bulle(
                    deIA: true,
                    texte: 'On repart à zéro ! De quoi veux-tu parler ? 😊',
                  ),
                );
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _defilement,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _bulles.length + (_iaEcrit ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _bulles.length) return _indicateurEcriture(theme);
                return _afficherBulle(_bulles[index], theme);
              },
            ),
          ),
          _barreEnvoi(theme),
        ],
      ),
    );
  }

  Widget _indicateurEcriture(ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: const SizedBox(
          width: 40,
          height: 16,
          child: Center(
            child: Text('…', style: TextStyle(fontSize: 20, height: 1)),
          ),
        ),
      ),
    );
  }

  Widget _afficherBulle(_Bulle bulle, ThemeData theme) {
    final moi = !bulle.deIA;
    return Align(
      alignment: moi ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          crossAxisAlignment: moi
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bulle.texte.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: moi
                      ? KinColors.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(moi ? 18 : 4),
                    bottomRight: Radius.circular(moi ? 4 : 18),
                  ),
                ),
                child: Text(
                  bulle.texte,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: moi ? Colors.white : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            if (bulle.actions != null && bulle.actions!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final e in bulle.actions!)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: KinColors.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: KinColors.accent.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          e,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _barreEnvoi(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _saisie,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                enabled: !_iaEcrit,
                onSubmitted: (_) => _envoyer(),
                decoration: const InputDecoration(
                  hintText: 'Discute avec Kinflow…',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _iaEcrit ? null : _envoyer,
              icon: const Icon(Icons.send),
              tooltip: 'Envoyer',
            ),
          ],
        ),
      ),
    );
  }
}
