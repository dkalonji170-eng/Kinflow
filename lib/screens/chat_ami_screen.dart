import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ami_position.dart';
import '../services/diagnostics_service.dart';
import '../services/enregistreur_vocal.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';
import '../utils/temps_relatif.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/bulle_vocale.dart';
import '../widgets/social_ui.dart';
import 'traffic_screen.dart';

/// Discussion privée avec un ami(e). Les messages ne vivent que 7 jours :
/// l'historique affiché ne contient jamais de message plus vieux (la fenêtre
/// est appliquée côté serveur).
class ChatAmiScreen extends StatefulWidget {
  const ChatAmiScreen({
    super.key,
    required this.amiId,
    required this.nom,
    this.avatar,
    this.position,
    this.onAmiSupprime,
    this.onInfoTaggee,
  });

  final String amiId;
  final String nom;
  final String? avatar;

  /// Position partagée par l'ami(e), si connue : permet de le/la localiser sur
  /// la carte ou de tracer un itinéraire depuis le menu ⋮.
  final AmiPosition? position;

  /// Appelé après un retrait réussi, pour rafraîchir la liste des amis.
  final VoidCallback? onAmiSupprime;

  /// Appelé quand on touche un message « tag » : on renvoie vers l'information
  /// correspondante dans le fil (identifiant de l'information).
  final ValueChanged<String>? onInfoTaggee;

  @override
  State<ChatAmiScreen> createState() => _ChatAmiScreenState();
}

class _ChatAmiScreenState extends State<ChatAmiScreen> {
  final TextEditingController _saisie = TextEditingController();
  final FocusNode _focusSaisie = FocusNode();
  final ScrollController _defilement = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _chargement = true;
  bool _chargementEnCours = false;
  bool _envoi = false;
  Timer? _minuteur;
  String _nomLocal = '';

  /// Mon propre profil (nom, prénom, avatar) : affiché à gauche dans la carte
  /// d'amitié en haut de la discussion.
  Map<String, String>? _monCompte;

  /// Identifiants des messages de localisation reçus pour lesquels la question
  /// (continuer la localisation / renouveler l'urgence) a déjà été traitée ou
  /// laissée de côté, pour ne pas la reposer en boucle.
  final Set<String> _promptsTraites = {};

  /// État des autorisations de localisation avec cet(te) ami(e), ou null tant
  /// qu'il n'a pas été chargé (boutons désactivés le temps du chargement).
  Map<String, dynamic>? _autorisations;

  /// Vrai pendant un appel de localisation (simple ou urgence).
  bool _localisationEnCours = false;

  // --- Messages vocaux -------------------------------------------------------
  // Le bouton de la barre bascule : micro tant que le champ est vide, avion en
  // papier dès que l'utilisateur a saisi quelque chose.
  final EnregistreurVocal _enregistreur = EnregistreurVocal();
  bool _enregistrement = false;
  bool _envoiVocal = false;
  int _secondesVocal = 0;
  DateTime? _debutVocal;
  Timer? _minuteurVocal;
  bool _champRempli = false;

  @override
  void initState() {
    super.initState();
    Journal.i('SOCIAL', 'Discussion ouverte', {'ami': widget.nom});
    _afficherCachePuisReseau();
    _chargerAutorisations();
    _chargerMonCompte();
    _chargerPromptsTraites();
    _minuteur = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _charger(silencieux: true),
    );
    // Bascule micro ⇄ avion en papier selon que le champ est vide ou non.
    _saisie.addListener(_surSaisieChangee);
  }

  void _surSaisieChangee() {
    final rempli = _saisie.text.trim().isNotEmpty;
    if (rempli == _champRempli) return;
    setState(() => _champRempli = rempli);
  }

  @override
  void dispose() {
    Journal.i('SOCIAL', 'Discussion fermée', {'ami': widget.nom});
    _minuteur?.cancel();
    _minuteurVocal?.cancel();
    _enregistreur.dispose();
    _saisie.removeListener(_surSaisieChangee);
    _saisie.dispose();
    _focusSaisie.dispose();
    _defilement.dispose();
    super.dispose();
  }

  /// Lit mon profil local pour la carte d'amitié (nom, prénom, avatar).
  Future<void> _chargerMonCompte() async {
    final compte = await SupabaseService().lireCompteLieLocal();
    if (!mounted) return;
    setState(() => _monCompte = compte);
  }

  static const String _prefixePrompt = 'loc_prompt_traite_';

  /// Recharge la liste des questions de localisation déjà traitées (ou mises de
  /// côté) sur cet appareil.
  Future<void> _chargerPromptsTraites() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs
        .getKeys()
        .where((k) => k.startsWith(_prefixePrompt))
        .map((k) => k.substring(_prefixePrompt.length));
    if (!mounted) return;
    setState(() => _promptsTraites.addAll(ids));
  }

  /// Mémorise que la question liée à [messageId] a été traitée : elle ne sera
  /// plus affichée.
  Future<void> _marquerPromptTraite(String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefixePrompt$messageId', true);
    if (mounted) setState(() => _promptsTraites.add(messageId));
  }

  /// Question affichée SOUS un message de localisation reçu : « continuer à me
  /// localiser ? » (orange) ou « renouveler l'urgence ? » (rouge). Rien pour
  /// celui qui a lancé la localisation.
  Widget _inviteLocalisation(Map<String, dynamic> message, String nomAmi) {
    if (message['moi'] == true) return const SizedBox.shrink();
    final type = message['type_systeme']?.toString() ?? '';
    final id = message['id']?.toString() ?? '';
    if (id.isEmpty || _promptsTraites.contains(id)) {
      return const SizedBox.shrink();
    }
    if (type == 'loc_simple') return _inviteLocSimple(id, nomAmi);
    if (type == 'loc_urgence') return _inviteLocUrgence(id, nomAmi);
    return const SizedBox.shrink();
  }

  Widget _inviteLocSimple(String messageId, String nomAmi) {
    final theme = Theme.of(context);
    final deja = _autorisations?['moi_autorise_ami_loc_simple'] == true;
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6, bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _orangeSimple.withValues(alpha: 0.40)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              deja
                  ? '$nomAmi peut te localiser quand il/elle veut. Continuer ?'
                  : 'Autoriser $nomAmi à te localiser quand il/elle veut ?',
              style: const TextStyle(fontSize: 12.5, height: 1.3),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    Journal.i('SOCIAL',
                        'Question de localisation laissée de côté',
                        {'ami': nomAmi});
                    _marquerPromptTraite(messageId);
                  },
                  child: const Text('Laisser'),
                ),
                const SizedBox(width: 4),
                OutlinedButton(
                  onPressed: () => _repondreLocSimple(messageId, false),
                  child: const Text('Non'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () => _repondreLocSimple(messageId, true),
                  child: const Text('Oui'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _inviteLocUrgence(String messageId, String nomAmi) {
    final theme = Theme.of(context);
    final dispo =
        _autorisations?['urgence_dispo_pour_ami_localiser_moi'] == true;
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6, bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _rougeUrgence.withValues(alpha: 0.40)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              dispo
                  ? 'La localisation d\'urgence est de nouveau disponible pour $nomAmi.'
                  : 'Renouveler la localisation d\'urgence pour $nomAmi ?',
              style: const TextStyle(fontSize: 12.5, height: 1.3),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    Journal.i('SOCIAL',
                        'Question de localisation laissée de côté',
                        {'ami': nomAmi});
                    _marquerPromptTraite(messageId);
                  },
                  child: const Text('Laisser'),
                ),
                if (!dispo) ...[
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => _renouvelerUrgence(messageId),
                    child: const Text('Renouveler'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Répond à la question de localisation simple : Oui/Non enregistré côté
  /// serveur, ou « Laisser » (aucun changement).
  Future<void> _repondreLocSimple(String messageId, bool choix) async {
    final ok = await SupabaseService()
        .definirAutorisationLocSimple(widget.amiId, choix);
    if (!mounted) return;
    if (!ok) {
      Journal.a('SOCIAL', 'Réponse à la localisation non enregistrée',
          {'ami': widget.nom});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choix non enregistré. Vérifie ta connexion.'),
        ),
      );
      return;
    }
    Journal.i('SOCIAL',
        'Question de localisation répondue : ${choix ? 'oui' : 'non'}',
        {'ami': widget.nom});
    await _chargerAutorisations();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          choix
              ? '${_nomAmiCourant()} peut te localiser.'
              : '${_nomAmiCourant()} ne peut plus te localiser.',
        ),
      ),
    );
    await _marquerPromptTraite(messageId);
  }

  /// Renouvelle la localisation d'urgence offerte à l'ami(e).
  Future<void> _renouvelerUrgence(String messageId) async {
    final ok = await SupabaseService().renouvelerUrgence(widget.amiId);
    if (!mounted) return;
    if (!ok) {
      Journal.a('SOCIAL', 'Renouvellement d\'urgence non enregistré',
          {'ami': widget.nom});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Renouvellement non enregistré. Vérifie ta connexion.'),
        ),
      );
      return;
    }
    Journal.i('SOCIAL', 'Localisation d\'urgence renouvelée',
        {'ami': widget.nom});
    await _chargerAutorisations();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Localisation d\'urgence renouvelée pour ${_nomAmiCourant()}.',
        ),
      ),
    );
    await _marquerPromptTraite(messageId);
  }

  String _nomAmiCourant() => _nomLocal.isEmpty ? widget.nom : _nomLocal;

  Future<void> _charger({bool silencieux = false}) async {
    // Un chargement est déjà en cours : sur un réseau lent (chaque appel peut
    // durer jusqu'au délai d'attente), laisser les appels s'empiler saturait le
    // réseau et vidait la liste à chaque réponse vide. On ignore les doublons.
    if (_chargementEnCours) return;
    _chargementEnCours = true;
    try {
      final service = SupabaseService();
      final messages = await service.mesMessagesAmi(widget.amiId);
      if (!mounted) return;

      if (messages.isEmpty) {
        // Serveur muet (réseau) OU discussion réellement vide. On ne remplace
        // JAMAIS ce qui est affiché par du vide : au tout premier chargement on
        // montre le cache local, sinon on garde la liste courante.
        if (_messages.isEmpty) {
          final cache = await service.chargerMessagesCache(widget.amiId);
          if (!mounted) return;
          if (cache.isNotEmpty) {
            Journal.i('SOCIAL', 'Discussion affichée depuis le cache local', {
              'ami': widget.nom,
              'messages': cache.length,
            });
            setState(() {
              _messages = cache;
              _chargement = false;
            });
            _descendreEnBas();
            return;
          }
          setState(() => _chargement = false);
        } else {
          // On garde la liste courante, mais on en retire les messages hors
          // fenêtre (plus de 7 jours) : ils ont « disparu » côté serveur. Les
          // messages lus restent donc affichés jusqu'à leur disparition, pas
          // au-delà.
          final actifs = [
            for (final m in _messages)
              if (SupabaseService.messageActif(m)) m,
          ];
          if (actifs.length != _messages.length) {
            setState(() => _messages = actifs);
            await service.sauverMessagesCache(widget.amiId, actifs);
          }
        }
        return;
      }

      // On conserve les messages locaux encore en cours d'envoi (ou en échec) :
      // ils n'existent pas encore côté serveur.
      final locaux = _messages
          .where((m) => (m['id']?.toString() ?? '').startsWith('local_'))
          .toList();
      final nouveaux = messages.length != _messages.length;
      setState(() {
        _messages = [...messages, ...locaux];
        _chargement = false;
      });
      // Cache local : la prochaine ouverture affiche la discussion tout de suite.
      await service.sauverMessagesCache(widget.amiId, messages);
      if (nouveaux) {
        Journal.i('SOCIAL', 'Discussion actualisée', {
          'ami': widget.nom,
          'messages': messages.length,
        });
      }
      // Les messages affichés sont lus : on marque côté serveur, mais seulement
      // quand quelque chose de neuf est arrivé (inutile de marteler le serveur
      // à chaque sondage). Le destinataire les marque « reçus » de son côté.
      if (nouveaux) unawaited(service.marquerMessagesLus(widget.amiId));
      if (!silencieux || nouveaux) _descendreEnBas();
    } finally {
      _chargementEnCours = false;
    }
  }

  /// Affiche d'abord la discussion depuis le cache local (instantané, même hors
  /// connexion), puis la rafraîchit depuis le serveur en arrière-plan.
  Future<void> _afficherCachePuisReseau() async {
    final cache = await SupabaseService().chargerMessagesCache(widget.amiId);
    if (!mounted) return;
    if (cache.isNotEmpty) {
      Journal.i('SOCIAL', 'Discussion affichée depuis le cache local', {
        'ami': widget.nom,
        'messages': cache.length,
      });
      setState(() {
        _messages = cache;
        _chargement = false;
      });
      _descendreEnBas();
    }
    await _charger();
  }

  void _descendreEnBas() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_defilement.hasClients) return;
      _defilement.animateTo(
        _defilement.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _envoyer() async {
    final texte = _saisie.text.trim();
    if (texte.isEmpty || _envoi) return;
    setState(() => _envoi = true);
    _saisie.clear();
    await _envoyerTexte(texte);
    if (mounted) setState(() => _envoi = false);
  }

  /// Envoie [texte] avec affichage optimiste : une bulle « en cours » apparaît
  /// aussitôt, puis passe à « envoyé » (simple coche) une fois le serveur
  /// confirmé. En cas d'échec, la bulle garde une icône d'erreur et peut être
  /// renvoyée en la touchant. [remplaceId] sert au renvoi d'un échec.
  Future<void> _envoyerTexte(String texte, {String? remplaceId}) async {
    final tempId =
        remplaceId ?? 'local_${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _messages.removeWhere((m) => m['id'] == tempId);
      _messages.add({
        'id': tempId,
        'contenu': texte,
        'cree_a': DateTime.now().toIso8601String(),
        'moi': true,
        'statut': 'en_cours',
      });
    });
    _descendreEnBas();

    final resultat = await SupabaseService().envoyerMessageAmi(
      amiId: widget.amiId,
      contenu: texte,
    );
    if (!mounted) return;
    if (resultat == 'envoye') {
      Journal.s('SOCIAL', 'Message texte envoyé', {
        'ami': widget.nom,
        'caracteres': texte.length,
      });
      setState(() => _messages.removeWhere((m) => m['id'] == tempId));
      await _charger(silencieux: true);
    } else {
      Journal.a('SOCIAL', 'Message texte non envoyé : $resultat',
          {'ami': widget.nom});
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _messages[index] = {..._messages[index], 'statut': 'echec'};
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageErreur(resultat))),
      );
    }
  }

  /// Statut d'un message : `en_cours` ou `echec` (local), sinon côté serveur
  /// `envoye`, `recu`, `lu`. Vide pour les messages reçus (pas d'indicateur).
  String _statutMessage(Map<String, dynamic> message) {
    final local = message['statut'] as String?;
    if (local != null) return local;
    if (message['moi'] != true) return '';
    if (message['lu'] == true) return 'lu';
    if (message['recu'] == true) return 'recu';
    return 'envoye';
  }

  // --- Messages vocaux -------------------------------------------------------

  /// Démarre l'enregistrement d'un message vocal (appui sur le micro).
  Future<void> _demarrerEnregistrement() async {
    if (_enregistrement || _envoiVocal) return;
    final autorise = await _enregistreur.demarrer();
    if (!mounted) return;
    if (!autorise) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Autorise l\'accès au micro pour envoyer un vocal.'),
        ),
      );
      return;
    }
    setState(() {
      _enregistrement = true;
      _secondesVocal = 0;
      _debutVocal = DateTime.now();
    });
    Journal.i('SOCIAL', 'Enregistrement vocal démarré', {'ami': widget.nom});
    _minuteurVocal = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondesVocal++);
      // Filet de sécurité : 5 minutes maximum par enregistrement.
      if (_secondesVocal >= 300) _arreterEnregistrement();
    });
  }

  /// Arrête l'enregistrement. [annuler] jette l'enregistrement sans l'envoyer.
  Future<void> _arreterEnregistrement({bool annuler = false}) async {
    if (!_enregistrement) return;
    _minuteurVocal?.cancel();
    _minuteurVocal = null;
    setState(() => _enregistrement = false);

    if (annuler) {
      Journal.i('SOCIAL', 'Enregistrement vocal annulé', {'ami': widget.nom});
      await _enregistreur.annuler();
      return;
    }

    final chemin = await _enregistreur.arreter();
    if (!mounted || chemin == null || chemin.isEmpty) return;
    final dureeMs = DateTime.now()
        .difference(_debutVocal ?? DateTime.now())
        .inMilliseconds;
    if (dureeMs < 600) {
      // Enregistrement trop court : on ne gaspille pas un envoi.
      Journal.i('SOCIAL', 'Enregistrement vocal trop court, ignoré',
          {'ami': widget.nom});
      try {
        await File(chemin).delete();
      } catch (_) {}
      return;
    }
    await _envoyerVocal(chemin, dureeMs);
  }

  /// Envoie un vocal : téléversement dans le bucket privé, puis création du
  /// message. La bulle optimiste apparaît immédiatement avec le fichier local.
  Future<void> _envoyerVocal(String chemin, int dureeMs) async {
    final tempId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _envoiVocal = true;
      _messages.add({
        'id': tempId,
        'contenu': '',
        'cree_a': DateTime.now().toIso8601String(),
        'moi': true,
        'statut': 'en_cours',
        'type_message': 'vocal',
        'audio_local': chemin,
        'audio_duree_ms': dureeMs,
      });
    });
    _descendreEnBas();
    await _pousserVocal(tempId, chemin, dureeMs);
  }

  /// Réessaie l'envoi d'un vocal en échec (bouton sur la bulle en erreur).
  Future<void> _reessayerVocal(Map<String, dynamic> message) async {
    final chemin = message['audio_local']?.toString();
    if (chemin == null || chemin.isEmpty) return;
    final dureeMs = (message['audio_duree_ms'] as num?)?.toInt() ?? 0;
    await _pousserVocal(
      message['id']?.toString() ?? '',
      chemin,
      dureeMs,
      bucketExistant: message['audio_bucket_local']?.toString(),
    );
  }

  /// Téléverse (si nécessaire) puis envoie le message vocal. [bucketExistant]
  /// évite de re-téléverser lors d'un renvoi après échec d'envoi.
  Future<void> _pousserVocal(
    String tempId,
    String chemin,
    int dureeMs, {
    String? bucketExistant,
  }) async {
    setState(() {
      _envoiVocal = true;
      final index = _messages.indexWhere((m) => m['id'] == tempId);
      if (index != -1) {
        _messages[index] = {..._messages[index], 'statut': 'en_cours'};
      }
    });

    String? bucket = (bucketExistant != null && bucketExistant.isNotEmpty)
        ? bucketExistant
        : null;
    if (bucket == null) {
      try {
        final octets = await File(chemin).readAsBytes();
        bucket = await SupabaseService().televerserVocal(
          amiId: widget.amiId,
          octets: octets,
          extension: 'm4a',
        );
      } catch (_) {
        bucket = null;
      }
      if (bucket != null && mounted) {
        // Mémorisé pour un renvoi possible sans re-téléversement.
        final index = _messages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _messages[index] = {..._messages[index], 'audio_bucket_local': bucket};
        }
      }
    }

    String? resultat;
    if (bucket != null) {
      resultat = await SupabaseService().envoyerMessageAmi(
        amiId: widget.amiId,
        contenu: '',
        audioChemin: bucket,
        audioDureeMs: dureeMs,
      );
    }

    if (!mounted) return;
    setState(() => _envoiVocal = false);
    if (resultat == 'envoye') {
      Journal.s('SOCIAL', 'Message vocal envoyé', {
        'ami': widget.nom,
        'duree_s': (dureeMs / 1000).round(),
      });
      setState(() => _messages.removeWhere((m) => m['id'] == tempId));
      await _charger(silencieux: true);
      try {
        await File(chemin).delete();
      } catch (_) {}
    } else {
      Journal.a('SOCIAL',
          'Message vocal non envoyé : ${resultat ?? 'téléversement échoué'}',
          {'ami': widget.nom});
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _messages[index] = {..._messages[index], 'statut': 'echec'};
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageErreur(resultat))),
      );
    }
  }

  String _messageErreur(String? resultat) {
    return switch (resultat) {
      'pas_ami' => 'Vous n\'êtes plus amis(es).',
      'contenu_vide' => 'Message vide.',
      _ => 'Envoi impossible. Vérifie ta connexion.',
    };
  }

  /// Charge l'état des autorisations de localisation avec l'ami(e).
  Future<void> _chargerAutorisations() async {
    final etat =
        await SupabaseService().etatAutorisationsLocalisation(widget.amiId);
    if (!mounted) return;
    setState(() => _autorisations = etat);
  }

  /// Lance une localisation ([mode] = 'simple' ou 'urgence'). En cas de succès,
  /// un message système est créé côté serveur et la carte s'ouvre centrée sur
  /// la position obtenue.
  Future<void> _localiserAvec(String mode) async {
    if (_localisationEnCours) return;
    setState(() => _localisationEnCours = true);
    Journal.i(
      'SOCIAL',
      mode == 'urgence'
          ? 'Localisation d\'urgence demandée'
          : 'Localisation simple demandée',
      {'ami': widget.nom},
    );
    final service = SupabaseService();
    final resultat = mode == 'urgence'
        ? await service.localiserUrgence(widget.amiId)
        : await service.localiserSimple(widget.amiId);
    if (!mounted) return;
    setState(() => _localisationEnCours = false);

    if (resultat == null || resultat['ok'] != true) {
      final erreur = resultat?['erreur']?.toString();
      Journal.a('SOCIAL', 'Localisation impossible : ${erreur ?? 'réseau'}', {
        'ami': widget.nom,
        'mode': mode,
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageErreurLocalisation(erreur))),
      );
      await _chargerAutorisations();
      return;
    }
    Journal.s('SOCIAL', 'Localisation réussie', {
      'ami': widget.nom,
      'mode': mode,
    });

    final latitude = _double(resultat['latitude']);
    final longitude = _double(resultat['longitude']);
    if (latitude == null || longitude == null) return;
    final position = AmiPosition(
      id: widget.amiId,
      nom: widget.nom,
      avatar: widget.avatar,
      position: LatLng(latitude, longitude),
      cap: _double(resultat['cap']),
      majA: DateTime.tryParse(resultat['maj_a']?.toString() ?? ''),
    );

    // Le message système vient d'être créé : on rafraîchit la discussion et
    // l'état des autorisations (l'urgence a pu être consommée).
    await _charger(silencieux: true);
    await _chargerAutorisations();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TrafficScreen(amiALocaliser: position),
      ),
    );
  }

  String _messageErreurLocalisation(String? erreur) {
    return switch (erreur) {
      'non_autorise' =>
        '${widget.nom} ne t\'autorise pas encore à le/la localiser.',
      'urgence_epuisee' =>
        'Localisation d\'urgence déjà utilisée. Demande à ${widget.nom} de la renouveler.',
      'pas_de_position' =>
        '${widget.nom} n\'a pas de position partagée pour le moment.',
      'pas_ami' => 'Vous n\'êtes plus amis(es).',
      _ => 'Localisation impossible. Vérifie ta connexion.',
    };
  }

  static double? _double(Object? valeur) {
    if (valeur == null) return null;
    if (valeur is num) return valeur.toDouble();
    return double.tryParse(valeur.toString());
  }

  /// Ouvre la feuille des autorisations : autoriser (ou révoquer) la
  /// localisation simple, et renouveler l'urgence laissée à l'ami(e).
  Future<void> _ouvrirAutorisations() async {
    Journal.i('SOCIAL', 'Ouverture des autorisations de localisation',
        {'ami': widget.nom});
    await _chargerAutorisations();
    if (!mounted) return;
    final etat = _autorisations;
    if (etat == null) {
      Journal.a('SOCIAL', 'Autorisations indisponibles', {'ami': widget.nom});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Autorisations indisponibles. Vérifie ta connexion.'),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final jeLAutorise = etat['moi_autorise_ami_loc_simple'] == true;
          final urgencePourLui =
              etat['urgence_dispo_pour_ami_localiser_moi'] == true;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Autorisations de localisation',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.my_location),
                  title: Text('Autoriser ${widget.nom} à me localiser'),
                  subtitle: const Text(
                    'Localisation simple, à tout moment. Révoquable.',
                  ),
                  value: jeLAutorise,
                  onChanged: (v) async {
                    final ok = await SupabaseService()
                        .definirAutorisationLocSimple(widget.amiId, v);
                    if (!ctx.mounted) return;
                    if (ok) {
                      Journal.i(
                        'SOCIAL',
                        'Autorisation de localisation '
                        '${v ? 'accordée' : 'retirée'} (feuille)',
                        {'ami': widget.nom},
                      );
                      setLocal(
                        () => etat['moi_autorise_ami_loc_simple'] = v,
                      );
                      if (mounted) setState(() => _autorisations = etat);
                    } else {
                      Journal.a(
                          'SOCIAL', 'Changement d\'autorisation non enregistré',
                          {'ami': widget.nom});
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Changement non enregistré.'),
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.emergency),
                  title: Text('Urgence pour ${widget.nom}'),
                  subtitle: Text(
                    urgencePourLui
                        ? 'Disponible : ${widget.nom} peut te localiser une fois en urgence.'
                        : 'Utilisée. Renouvelle pour l\'autoriser à nouveau.',
                  ),
                  trailing: urgencePourLui
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : TextButton(
                          onPressed: () async {
                            final ok = await SupabaseService()
                                .renouvelerUrgence(widget.amiId);
                            if (!ctx.mounted) return;
                            if (ok) {
                              Journal.i(
                                  'SOCIAL', 'Localisation d\'urgence renouvelée',
                                  {'ami': widget.nom});
                              setLocal(
                                () => etat['urgence_dispo_pour_ami_localiser_moi'] =
                                    true,
                              );
                              if (mounted) setState(() => _autorisations = etat);
                            } else {
                              Journal.a(
                                  'SOCIAL',
                                  'Renouvellement d\'urgence non enregistré',
                                  {'ami': widget.nom});
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('Renouvellement non enregistré.'),
                                ),
                              );
                            }
                          },
                          child: const Text('Renouveler'),
                        ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Demande confirmation puis retire l'ami(e) et ferme la discussion.
  Future<void> _confirmerRetrait() async {
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retirer cet ami(es) ?'),
        content: Text('${widget.nom} ne sera plus dans tes amis(es).'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirmer != true || !mounted) return;

    final ok = await SupabaseService().retirerAmi(widget.amiId);
    if (!mounted) return;
    if (!ok) {
      Journal.a('SOCIAL', 'Retrait de l\'ami(e) non enregistré',
          {'ami': widget.nom});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Retrait non enregistré. Vérifie ta connexion.'),
        ),
      );
      return;
    }
    Journal.i('SOCIAL', 'Ami(e) retiré(e)', {'ami': widget.nom});
    widget.onAmiSupprime?.call();
    Navigator.of(context).pop();
  }

  void _menuSelectionne(String valeur) {
    if (valeur == 'localiser_simple') {
      _localiserAvec('simple');
    } else if (valeur == 'localiser_urgence') {
      _localiserAvec('urgence');
    } else if (valeur == 'autorisations') {
      _ouvrirAutorisations();
    } else if (valeur == 'renommer') {
      _renommerAmi();
    } else if (valeur == 'retirer') {
      _confirmerRetrait();
    }
  }


  Future<void> _renommerAmi() async {
    final controller = TextEditingController(text: _nomLocal.isEmpty ? widget.nom : _nomLocal);
    final nom = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renommer cet ami(e)'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Nouveau nom',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (!mounted || nom == null || nom.isEmpty) return;
    Journal.i('SOCIAL', 'Ami(e) renommé localement', {
      'avant': _nomLocal.isEmpty ? widget.nom : _nomLocal,
      'apres': nom,
    });
    setState(() => _nomLocal = nom);
  }

  /// Vrai si la position de l'ami(e) a été vue très récemment : indique qu'il
  /// ou elle est probablement en ligne.
  bool get _amiEnLigne {
    final majA = widget.position?.majA;
    if (majA == null) return false;
    return DateTime.now().difference(majA.toLocal()).inMinutes < 5;
  }

  /// Sous-titre de l'en-tête : présence, ou état de la discussion.
  String _sousTitreEntete() {
    if (_amiEnLigne) return 'En ligne';
    final majA = widget.position?.majA;
    if (majA == null) return 'Discussion privée';
    return 'Position partagée ${tempsRelatif(majA.toLocal())}';
  }

  String _heure(Object? brut) {
    final d = brut == null ? null : DateTime.tryParse(brut.toString())?.toLocal();
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 0,
        title: Row(
          children: [
            Stack(
              children: [
                AvatarAnimalWidget(taille: 38, avatarId: widget.avatar),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: PastillePresence(active: _amiEnLigne, taille: 12),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _nomLocal.isEmpty ? widget.nom : _nomLocal,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      height: 1.15,
                    ),
                  ),
                  Text(
                    _sousTitreEntete(),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: _amiEnLigne
                          ? KinColors.vertArrivee
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Options',
            onSelected: _menuSelectionne,
            itemBuilder: (context) {
              final simpleAutorise =
                  _autorisations?['ami_autorise_moi_loc_simple'] == true;
              final urgenceDispo =
                  _autorisations?['urgence_dispo_pour_moi_localiser_ami'] ==
                      true;
              return [
                PopupMenuItem(
                  value: 'localiser_simple',
                  enabled: simpleAutorise && !_localisationEnCours,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.my_location),
                    title: const Text('Localiser (simple)'),
                    subtitle: Text(
                      simpleAutorise
                          ? '${widget.nom} t\'y a autorisé'
                          : 'Pas encore autorisé',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
                PopupMenuItem(
                  value: 'localiser_urgence',
                  enabled: urgenceDispo && !_localisationEnCours,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.emergency),
                    title: const Text('Localiser en urgence'),
                    subtitle: Text(
                      urgenceDispo
                          ? 'Une seule fois'
                          : 'Urgence déjà utilisée',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'autorisations',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Autorisations de localisation'),
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'renommer',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Renommer cet ami(e)'),
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'retirer',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.person_remove_outlined,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(
                      'Retirer cet ami(e)',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _chargement
                ? _squeletteDiscussion(theme)
                : ListView.builder(
                    controller: _defilement,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.isEmpty ? 2 : _messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) return _carteAmitie(theme);
                      if (_messages.isEmpty) return _vide(theme);
                      final message = _messages[index - 1];
                      // Clé stable par message : sans elle, Flutter réutilise
                      // l'état d'une bulle vocale pour un AUTRE message après un
                      // rechargement (mauvaise source, lecture cassée).
                      return KeyedSubtree(
                        key: ValueKey(
                          message['id']?.toString() ?? 'msg_$index',
                        ),
                        child: _bulle(message),
                      );
                    },
                  ),
          ),
          _barreEnvoi(theme),
        ],
      ),
    );
  }

  /// Squelette de chargement de la discussion : quelques bulles factices qui
  /// scintillent, à la place d'un simple rond qui tourne.
  Widget _squeletteDiscussion(ThemeData theme) {
    Widget bulle({required bool moi, double largeur = 180}) {
      return Align(
        alignment: moi ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: largeur,
          height: 46,
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(moi ? 18 : 4),
              bottomRight: Radius.circular(moi ? 4 : 18),
            ),
          ),
        ),
      );
    }

    return Scintillement(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        children: [
          bulle(moi: false, largeur: 170),
          bulle(moi: true, largeur: 210),
          bulle(moi: false, largeur: 130),
          bulle(moi: true, largeur: 150),
          bulle(moi: false, largeur: 220),
          bulle(moi: true, largeur: 120),
        ],
      ),
    );
  }

  Widget _vide(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Aucun message pour l\'instant.\nÉcris le premier !',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Carte d'amitié affichée en tête de discussion : les deux profils côte à
  /// côte, puis les réglages essentiels (localisation, renommer) et quelques
  /// suggestions de premier message.
  Widget _carteAmitie(ThemeData theme) {
    final nomAmi = _nomLocal.isEmpty ? widget.nom : _nomLocal;
    final connait = _autorisations != null;
    final jeLAutorise =
        _autorisations?['moi_autorise_ami_loc_simple'] == true;
    final amiAutorise =
        _autorisations?['ami_autorise_moi_loc_simple'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Card(
        elevation: 0,
        color: KinColors.primary.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: KinColors.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.handshake_outlined,
                    size: 18,
                    color: KinColors.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Vous êtes amis',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Bienvenue dans votre discussion privée.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _profilAmi(
                      _nomAffiche(_monCompte),
                      _monCompte?['avatar'],
                      'Vous',
                    ),
                  ),
                  _maillon(),
                  Expanded(
                    child: _profilAmi(nomAmi, widget.avatar, 'Votre ami(e)'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                secondary: const Icon(
                  Icons.my_location,
                  color: KinColors.primary,
                ),
                title: Text(
                  'Autoriser $nomAmi à me localiser',
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  !connait
                      ? 'Chargement…'
                      : (jeLAutorise
                          ? 'Autorisé — localisation simple'
                          : 'Non autorisé'),
                  style: const TextStyle(fontSize: 11.5),
                ),
                value: jeLAutorise,
                onChanged:
                    connait ? (v) => _basculerAutorisation(v) : null,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
                child: Row(
                  children: [
                    Icon(
                      amiAutorise
                          ? Icons.check_circle
                          : Icons.hourglass_empty,
                      size: 16,
                      color: amiAutorise
                          ? KinColors.vertArrivee
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        amiAutorise
                            ? '$nomAmi t\'autorise à le/la localiser'
                            : '$nomAmi ne t\'a pas encore autorisé à le/la '
                                'localiser',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _renommerAmi,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Renommer'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _ouvrirAutorisations,
                      icon: const Icon(Icons.lock_outline, size: 18),
                      label: const Text('Autorisations'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Suggestions',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _puceSuggestion('👋 Bonjour'),
                  _puceSuggestion('📍 Tu es où ?'),
                  _puceSuggestion('Ça va ?'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Un profil (avatar + nom + rôle) de la carte d'amitié.
  Widget _profilAmi(String nom, String? avatarId, String role) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AvatarAnimalWidget(taille: 56, avatarId: avatarId),
        const SizedBox(height: 8),
        Text(
          nom,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
        ),
        const SizedBox(height: 1),
        Text(
          role,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Petit cœur reliant les deux profils.
  Widget _maillon() {
    return Padding(
      padding: const EdgeInsets.only(top: 14, left: 4, right: 4),
      child: Container(
        width: 30,
        height: 30,
        decoration: const BoxDecoration(
          color: KinColors.primary,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.favorite, size: 16, color: Colors.white),
      ),
    );
  }

  /// Puce de suggestion : remplit le champ de saisie (sans envoyer).
  Widget _puceSuggestion(String texte) {
    return ActionChip(
      visualDensity: VisualDensity.compact,
      label: Text(texte),
      onPressed: () => _preRemplir(texte),
    );
  }

  void _preRemplir(String texte) {
    _saisie.text = texte;
    _saisie.selection = TextSelection.fromPosition(
      TextPosition(offset: texte.length),
    );
    _focusSaisie.requestFocus();
  }

  /// Active/désactive l'autorisation de localisation simple depuis la carte.
  Future<void> _basculerAutorisation(bool valeur) async {
    final ok = await SupabaseService()
        .definirAutorisationLocSimple(widget.amiId, valeur);
    if (!mounted) return;
    if (ok) {
      Journal.i(
        'SOCIAL',
        'Autorisation de localisation ${valeur ? 'accordée' : 'retirée'}',
        {'ami': widget.nom},
      );
      setState(() {
        _autorisations = {
          ...?_autorisations,
          'moi_autorise_ami_loc_simple': valeur,
        };
      });
    } else {
      Journal.a('SOCIAL', 'Changement d\'autorisation non enregistré',
          {'ami': widget.nom});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Changement non enregistré.')),
      );
    }
  }

  /// Nom à afficher pour moi : prénom, sinon nom, sinon « Vous ».
  String _nomAffiche(Map<String, String>? compte) {
    final prenom = (compte?['prenom'] ?? '').trim();
    final nom = (compte?['nom'] ?? '').trim();
    if (prenom.isNotEmpty) return prenom;
    if (nom.isNotEmpty) return nom;
    return 'Vous';
  }

  /// Couleur des bulles : vert pour les messages envoyés, bleu pour les reçus.
  static const Color _vertEnvoye = KinColors.vertArrivee;
  static const Color _bleuRecu = KinColors.bleu;

  /// Messages système de localisation : orange (simple), rouge (urgence).
  static const Color _orangeSimple = Color(0xFFE98B00);
  static const Color _rougeUrgence = Color(0xFFC62828);

  Widget _bulle(Map<String, dynamic> message) {
    if (message['est_systeme'] == true) return _bulleSysteme(message);
    if (_estVocal(message)) return _bulleVocale(message);

    final moi = message['moi'] == true;
    final texte = message['contenu'] as String? ?? '';
    final statut = _statutMessage(message);
    final echec = statut == 'echec';

    final bulle = Container(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      decoration: BoxDecoration(
        color: moi ? _vertEnvoye : _bleuRecu,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(moi ? 16 : 4),
          bottomRight: Radius.circular(moi ? 4 : 16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            texte,
            style: const TextStyle(color: Colors.white, height: 1.35, fontSize: 15),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _heure(message['cree_a']),
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
              if (moi) ...[
                const SizedBox(width: 4),
                _indicateurStatut(statut),
              ],
            ],
          ),
        ],
      ),
    );

    return Align(
      alignment: moi ? Alignment.centerRight : Alignment.centerLeft,
      child: echec
          ? GestureDetector(
              onTap: () =>
                  _envoyerTexte(texte, remplaceId: message['id']?.toString()),
              child: bulle,
            )
          : bulle,
    );
  }

  /// Un message est vocal s'il vient du serveur avec ce type, ou s'il s'agit
  /// d'un envoi local en cours (fichier déjà enregistré sur l'appareil).
  bool _estVocal(Map<String, dynamic> message) {
    if (message['type_message']?.toString() == 'vocal') return true;
    return (message['audio_local'] as String?)?.isNotEmpty ?? false;
  }

  /// Bulle d'un message vocal : lecture locale pour les envois optimistes,
  /// URL signée résolue à la volée pour les messages déjà reçus.
  Widget _bulleVocale(Map<String, dynamic> message) {
    final moi = message['moi'] == true;
    final statut = _statutMessage(message);
    final local = message['audio_local'] as String?;
    final bucket = message['audio_chemin'] as String?;
    final echec = statut == 'echec';

    final bulle = BulleVocale(
      cheminLocal: local,
      resoudreSource:
          (bucket == null || bucket.isEmpty)
              ? null
              : () => SupabaseService().urlVocalSignee(bucket),
      dureeMs: (message['audio_duree_ms'] as num?)?.toInt() ?? 0,
      moi: moi,
      heure: _heure(message['cree_a']),
      indicateur: moi ? _indicateurStatut(statut) : null,
    );

    // Un vocal en échec se renvoie d'un appui.
    if (echec) {
      return GestureDetector(
        onTap: () => _reessayerVocal(message),
        child: bulle,
      );
    }
    return bulle;
  }

  /// Texte d'un message système selon le point de vue de l'utilisateur :
  /// celui qui a localisé lit « Vous avez localisé … » ; celui qui a été
  /// localisé lit « Vous avez été localisé … ». Le nom n'est jamais répété,
  /// il figure déjà dans l'en-tête de la discussion.
  String _texteSysteme(Map<String, dynamic> message) {
    final type = message['type_systeme']?.toString() ?? '';
    final heure = _heure(message['cree_a']);
    final moi = message['moi'] == true;
    final suffixe = heure.isEmpty ? '.' : ' à $heure.';
    switch (type) {
      case 'loc_simple':
        return moi
            ? 'Vous avez localisé votre ami(e)$suffixe'
            : 'Vous avez été localisé(e)$suffixe';
      case 'loc_urgence':
        return moi
            ? 'Vous avez localisé votre ami(e) en urgence$suffixe'
            : 'Vous avez été localisé(e) en urgence$suffixe';
      case 'tag_info':
        return moi
            ? 'Vous avez tagué votre ami(e) sur cette information'
            : 'Vous avez été tagué(e) sur une information';
      default:
        // Autres messages système (ou anciens) : on garde le texte stocké.
        return message['contenu'] as String? ?? '';
    }
  }

  /// Message système : centré. Celui qui agit voit sa bulle en vert ; l'autre
  /// en bleu (tag) ou orange/rouge (localisation simple/urgence).
  Widget _bulleSysteme(Map<String, dynamic> message) {
    final type = message['type_systeme']?.toString() ?? '';
    final tag = type == 'tag_info';
    final urgence = type == 'loc_urgence';
    final moi = message['moi'] == true;
    final fond = moi
        ? _vertEnvoye
        : (tag
            ? _bleuRecu
            : (urgence ? _rougeUrgence : _orangeSimple));
    final icone = tag
        ? Icons.alternate_email
        : (urgence ? Icons.emergency : Icons.my_location);
    final texte = _texteSysteme(message);
    final infoId = message['info_id']?.toString();
    final snippet = (message['contenu'] as String? ?? '').trim();
    final nomAmi = _nomLocal.isEmpty ? widget.nom : _nomLocal;

    final bulle = Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icone, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  texte,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          if (tag && snippet.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '« $snippet »',
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 6),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.open_in_new, size: 12, color: Colors.white70),
                SizedBox(width: 4),
                Text(
                  'Touchez pour voir l\'information',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    decoration: TextDecoration.underline,
                    decorationColor: Colors.white54,
                  ),
                ),
              ],
            ),
          ],
          if (message['latitude'] != null &&
              message['longitude'] != null) ...[
            const SizedBox(height: 6),
            const Divider(height: 1, color: Colors.white30),
            const SizedBox(height: 6),
            _coordonneesSysteme(message),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
      child: Column(
        children: [
          if (tag && infoId != null && infoId.isNotEmpty)
            InkWell(
              onTap: () => _ouvrirInfoTaggee(infoId),
              borderRadius: BorderRadius.circular(12),
              child: bulle,
            )
          else
            bulle,
          const SizedBox(height: 2),
          Text(
            _heure(message['cree_a']),
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
          _inviteLocalisation(message, nomAmi),
        ],
      ),
    );
  }

  /// Ouvre l'information taguée : ferme la discussion et renvoie vers le fil.
  void _ouvrirInfoTaggee(String infoId) {
    Journal.i('SOCIAL', 'Ouverture de l\'information taguée',
        {'info': infoId, 'ami': widget.nom});
    final rappel = widget.onInfoTaggee;
    Navigator.of(context).pop();
    rappel?.call(infoId);
  }

  /// Coordonnées exactes du lieu localisé, affichées dans le message système
  /// et copiables d'un simple clic.
  Widget _coordonneesSysteme(Map<String, dynamic> message) {
    final lat = _double(message['latitude']);
    final lng = _double(message['longitude']);
    if (lat == null || lng == null) return const SizedBox.shrink();
    final latTxt = lat.toStringAsFixed(6);
    final lngTxt = lng.toStringAsFixed(6);
    return InkWell(
      onTap: () => _copierCoordonnees(latTxt, lngTxt),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.copy, size: 13, color: Colors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Lat $latTxt • Lon $lngTxt',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  height: 1.3,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white54,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Copie les coordonnées affichées dans le presse-papiers.
  Future<void> _copierCoordonnees(String lat, String lng) async {
    final texte = '$lat, $lng';
    await Clipboard.setData(ClipboardData(text: texte));
    Journal.i('SOCIAL', 'Coordonnées copiées', {'coordonnees': texte});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Coordonnées copiées : $texte')),
    );
  }

  /// Indicateur d'état, à la manière des messageries : horloge (en cours),
  /// coche simple (envoyé), double coche (reçu), double coche (lu). L'accusé de
  /// lecture reste TOUJOURS gris, même une fois le message lu (jamais bleu).
  /// En échec : point d'exclamation rouge (toucher la bulle pour réessayer).
  Widget _indicateurStatut(String statut) {
    switch (statut) {
      case 'en_cours':
        return const Icon(Icons.schedule, size: 13, color: Colors.white70);
      case 'envoye':
        return const Icon(Icons.check, size: 14, color: Colors.white70);
      case 'recu':
        return const Icon(Icons.done_all, size: 14, color: Colors.white70);
      case 'lu':
        return const Icon(Icons.done_all, size: 14, color: Colors.white70);
      case 'echec':
        return const Icon(
          Icons.error_outline,
          size: 14,
          color: Color(0xFFFFCDD2),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _barreEnvoi(ThemeData theme) {
    if (_enregistrement) return _barreEnregistrement();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _saisie,
                focusNode: _focusSaisie,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  hintText: 'Écrire un message…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _envoyer(),
              ),
            ),
            const SizedBox(width: 8),
            // Champ vide : micro (message vocal). Dès que l'utilisateur écrit,
            // le micro se change en avion en papier pour symboliser l'envoi.
            if (_champRempli)
              IconButton.filled(
                onPressed: _envoi ? null : _envoyer,
                icon: const Icon(Icons.send),
                tooltip: 'Envoyer',
              )
            else
              IconButton.filled(
                onPressed: _envoiVocal ? null : _demarrerEnregistrement,
                icon: const Icon(Icons.mic),
                tooltip: 'Message vocal',
              ),
          ],
        ),
      ),
    );
  }

  /// Barre affichée pendant l'enregistrement d'un vocal : minuteur en direct,
  /// bouton annuler (✕) et bouton envoyer (avion en papier).
  Widget _barreEnregistrement() {
    final texte = '${(_secondesVocal ~/ 60).toString().padLeft(2, '0')}:'
        '${(_secondesVocal % 60).toString().padLeft(2, '0')}';
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: KinColors.primary,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.mic, color: Colors.white, size: 20),
            ),
            Expanded(
              child: Text(
                'Enregistrement en cours  •  $texte',
                style: const TextStyle(color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              onPressed: () => _arreterEnregistrement(annuler: true),
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Annuler',
            ),
            IconButton.filled(
              onPressed: _arreterEnregistrement,
              icon: const Icon(Icons.send, color: Colors.white),
              tooltip: 'Envoyer le vocal',
            ),
          ],
        ),
      ),
    );
  }
}
