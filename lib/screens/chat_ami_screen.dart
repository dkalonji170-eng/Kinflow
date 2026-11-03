import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ami_position.dart';
import '../services/diagnostics_service.dart';
import '../services/enregistreur_vocal.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';
import '../widgets/autorisations_localisation_sheet.dart';
import '../widgets/actions_ami.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/bulle_vocale.dart';
import '../widgets/citation_message.dart';
import '../widgets/profil_ami_dialog.dart';
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

  // --- Photos ----------------------------------------------------------------
  // Le bouton « + » de la barre basse permet de prendre une photo ou d'en
  // choisir une dans la galerie, puis de l'envoyer directement.
  final ImagePicker _selecteurImages = ImagePicker();
  bool _envoiImage = false;

  /// Photos des envois pas encore confirmés (clé = identifiant local). Gardées
  /// en mémoire seulement : elles servent d'aperçu immédiat et au renvoi après
  /// un échec, sans alourdir le cache JSON de la discussion.
  final Map<String, Uint8List> _photosLocales = {};

  /// URL signée déjà résolue par chemin de bucket : évite de re-signer l'URL à
  /// chaque rafraîchissement de la discussion (toutes les 8 s).
  final Map<String, Future<String?>> _urlsPhotos = {};

  // --- Réponse à un message (façon WhatsApp) ---------------------------------
  /// Message actuellement cité : il est affiché en aperçu au-dessus du clavier,
  /// et l'envoi l'emporte comme référence (`reply_to_message_id`).
  Map<String, dynamic>? _reponseA;

  /// Clé de chaque bulle, par identifiant de message : sert à faire défiler la
  /// discussion jusqu'au message cité quand on touche un aperçu.
  final Map<String, GlobalKey> _clesMessages = {};

  /// Message brièvement mis en évidence après une navigation vers lui.
  String? _messageSurligne;
  Timer? _minuteurSurligne;

  /// Une réponse ne peut citer qu'un message déjà présent sur le serveur : une
  /// bulle « en cours » n'a pas encore d'identifiant définitif.
  bool _peutCiter(Map<String, dynamic> message) {
    if (message['est_systeme'] == true) return false;
    return _coteServeur(message);
  }

  @override
  void initState() {
    super.initState();
    Journal.i('SOCIAL', 'Discussion ouverte', {'ami': widget.nom});
    _afficherCachePuisReseau();
    _chargerAutorisations();
    _chargerMonCompte();
    _chargerSurnom();
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
    _minuteurSurligne?.cancel();
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

  /// Récupère le surnom local de cet(te) ami(e), s'il y en a un : le nom
  /// choisi reste affiché même après avoir quitté la discussion.
  Future<void> _chargerSurnom() async {
    final surnom = await SupabaseService().surnomAmi(widget.amiId);
    if (!mounted || surnom == null) return;
    setState(() => _nomLocal = surnom);
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

  /// Question affichée SOUS un message de localisation reçue : « renouveler
  /// l'urgence ? » (rouge). La localisation simple est autorisée par défaut
  /// entre amis : elle n'a plus de questionnaire. Rien pour celui qui a lancé
  /// la localisation.
  Widget _inviteLocalisation(Map<String, dynamic> message, String nomAmi) {
    if (message['moi'] == true) return const SizedBox.shrink();
    final type = message['type_systeme']?.toString() ?? '';
    final id = message['id']?.toString() ?? '';
    if (id.isEmpty || _promptsTraites.contains(id)) {
      return const SizedBox.shrink();
    }
    if (type == 'loc_urgence') return _inviteLocUrgence(id, nomAmi);
    return const SizedBox.shrink();
  }

  Widget _inviteLocUrgence(String messageId, String nomAmi) {
    final theme = Theme.of(context);
    final couleur = theme.colorScheme;
    final dispo =
        _autorisations?['urgence_dispo_pour_ami_localiser_moi'] == true;
    final teinte = dispo
        ? KinColors.vertArrivee
        : (theme.brightness == Brightness.dark
              ? const Color(0xFFEF5350)
              : _rougeUrgence);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        decoration: BoxDecoration(
          color: teinte.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: teinte.withValues(alpha: 0.22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: teinte.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    dispo ? Icons.check_rounded : Icons.sos_outlined,
                    size: 16,
                    color: teinte,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dispo
                            ? 'Urgence de nouveau disponible'
                            : 'Urgence utilisée',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        dispo
                            ? '$nomAmi peut te localiser une fois de plus.'
                            : 'Autoriser $nomAmi à te localiser une fois '
                                  'de plus ?',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: couleur.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    Journal.i(
                      'SOCIAL',
                      'Question de localisation laissée de côté',
                      {'ami': nomAmi},
                    );
                    _marquerPromptTraite(messageId);
                  },
                  child: Text(dispo ? 'Compris' : 'Plus tard'),
                ),
                if (!dispo) ...[
                  const SizedBox(width: 6),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _renouvelerUrgence(messageId),
                    icon: const Icon(Icons.autorenew, size: 16),
                    label: const Text('Renouveler'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Renouvelle la localisation d'urgence offerte à l'ami(e).
  Future<void> _renouvelerUrgence(String messageId) async {
    final ok = await SupabaseService().renouvelerUrgence(widget.amiId);
    if (!mounted) return;
    if (!ok) {
      Journal.a('SOCIAL', 'Renouvellement d\'urgence non enregistré', {
        'ami': widget.nom,
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Renouvellement non enregistré. Vérifie ta connexion.'),
        ),
      );
      return;
    }
    Journal.i('SOCIAL', 'Localisation d\'urgence renouvelée', {
      'ami': widget.nom,
    });
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
      if (!mounted || !_defilement.hasClients) return;
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
    final cite = _reponseA;
    setState(() {
      _envoi = true;
      _reponseA = null;
    });
    _saisie.clear();
    await _envoyerTexte(
      texte,
      repondreA: cite?['id']?.toString(),
      apercu: cite == null ? null : _apercuDepuisMessage(cite),
    );
    if (mounted) setState(() => _envoi = false);
  }

  /// Aperçu d'un message au format renvoyé par le serveur (`reply_to`), pour
  /// que la bulle optimiste affiche la citation sans attendre le réseau.
  Map<String, dynamic> _apercuDepuisMessage(Map<String, dynamic> message) {
    return {
      'id': message['id'],
      'expediteur': message['expediteur'],
      'moi': message['moi'] == true,
      'contenu': message['contenu'] ?? '',
      'type_message': message['type_message'] ?? 'texte',
      'est_systeme': message['est_systeme'] == true,
      'modifie_a': message['modifie_a'],
    };
  }

  /// Envoie [texte] avec affichage optimiste : une bulle « en cours » apparaît
  /// aussitôt, puis passe à « envoyé » (simple coche) une fois le serveur
  /// confirmé. En cas d'échec, la bulle garde une icône d'erreur et peut être
  /// renvoyée en la touchant. [remplaceId] sert au renvoi d'un échec.
  /// [repondreA] est l'identifiant du message cité (facultatif) : il est
  /// enregistré comme RÉFÉRENCE, avec [apercu] pour l'affichage immédiat.
  Future<void> _envoyerTexte(
    String texte, {
    String? remplaceId,
    String? repondreA,
    Map<String, dynamic>? apercu,
  }) async {
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
        if (repondreA != null && repondreA.isNotEmpty) ...{
          'reply_to_message_id': repondreA,
          'reply_to': ?apercu,
        },
      });
    });
    _descendreEnBas();

    final resultat = await SupabaseService().envoyerMessageAmi(
      amiId: widget.amiId,
      contenu: texte,
      repondreA: repondreA,
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
      Journal.a('SOCIAL', 'Message texte non envoyé : $resultat', {
        'ami': widget.nom,
      });
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _messages[index] = {..._messages[index], 'statut': 'echec'};
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            resultat == null || resultat == 'non_connecte'
                ? "Envoi impossible. Vérifie ta connexion ou réessaie."
                : _messageErreur(resultat),
          ),
        ),
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
      Journal.i('SOCIAL', 'Enregistrement vocal trop court, ignoré', {
        'ami': widget.nom,
      });
      try {
        await File(chemin).delete();
      } catch (_) {}
      return;
    }
    // Forme d'onde relevée pendant l'enregistrement : elle sera dessinée dans
    // la bulle (barres suivant le volume de la voix).
    await _envoyerVocal(chemin, dureeMs, _enregistreur.formes);
  }

  /// Envoie un vocal : téléversement dans le bucket privé, puis création du
  /// message. La bulle optimiste apparaît immédiatement avec le fichier local.
  Future<void> _envoyerVocal(
    String chemin,
    int dureeMs,
    List<int> formes,
  ) async {
    final tempId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    // Un vocal peut lui aussi répondre à un message : on fige la référence
    // maintenant, puis on libère l'aperçu de saisie.
    final cite = _reponseA;
    final repondreA = cite?['id']?.toString();
    final apercu = cite == null ? null : _apercuDepuisMessage(cite);
    setState(() {
      _envoiVocal = true;
      _reponseA = null;
      _messages.add({
        'id': tempId,
        'contenu': '',
        'cree_a': DateTime.now().toIso8601String(),
        'moi': true,
        'statut': 'en_cours',
        'type_message': 'vocal',
        'audio_local': chemin,
        'audio_duree_ms': dureeMs,
        'audio_formes': formes,
        if (repondreA != null && repondreA.isNotEmpty) ...{
          'reply_to_message_id': repondreA,
          'reply_to': ?apercu,
        },
      });
    });
    _descendreEnBas();
    await _pousserVocal(
      tempId,
      chemin,
      dureeMs,
      formes,
      repondreA: repondreA,
      apercu: apercu,
    );
  }

  /// Réessaie l'envoi d'un vocal en échec (bouton sur la bulle en erreur).
  Future<void> _reessayerVocal(Map<String, dynamic> message) async {
    final chemin = message['audio_local']?.toString();
    if (chemin == null || chemin.isEmpty) return;
    final dureeMs = (message['audio_duree_ms'] as num?)?.toInt() ?? 0;
    final formes = message['audio_formes'];
    await _pousserVocal(
      message['id']?.toString() ?? '',
      chemin,
      dureeMs,
      formes is List
          ? [
              for (final v in formes)
                if (v is num) v.toInt(),
            ]
          : const [],
      bucketExistant: message['audio_bucket_local']?.toString(),
      repondreA: message['reply_to_message_id']?.toString(),
      apercu: (message['reply_to'] as Map?)?.cast<String, dynamic>(),
    );
  }

  /// Téléverse (si nécessaire) puis envoie le message vocal. [bucketExistant]
  /// évite de re-téléverser lors d'un renvoi après échec d'envoi.
  Future<void> _pousserVocal(
    String tempId,
    String chemin,
    int dureeMs,
    List<int> formes, {
    String? bucketExistant,
    String? repondreA,
    Map<String, dynamic>? apercu,
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
          _messages[index] = {
            ..._messages[index],
            'audio_bucket_local': bucket,
          };
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
        audioFormes: formes,
        repondreA: repondreA,
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
      Journal.a(
        'SOCIAL',
        'Message vocal non envoyé : ${resultat ?? 'téléversement échoué'}',
        {'ami': widget.nom},
      );
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _messages[index] = {..._messages[index], 'statut': 'echec'};
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            resultat == null
                ? 'Téléversement vocal impossible. Réessaie.'
                : _messageErreur(resultat),
          ),
        ),
      );
    }
  }

  String _messageErreur(String? resultat) {
    return switch (resultat) {
      'pas_ami' => 'Vous n\'êtes plus amis(es).',
      'contenu_vide' => 'Message vide.',
      'pas_autorise' => 'Action non autorisée sur ce message.',
      'message_introuvable' => 'Ce message n\'existe plus.',
      'message_invalide' => 'Ce message n\'existe plus.',
      'message_systeme' => 'Ce message système ne peut pas être modifié.',
      'vocal_non_modifiable' => 'Un message vocal ne peut pas être modifié.',
      'media_non_modifiable' =>
        'Une photo ou un vocal ne peut pas être modifié.',
      'contenu_trop_long' => 'Message trop long (4000 caractères max).',
      'non_connecte' => 'Connecte-toi pour effectuer cette action.',
      _ => 'Envoi impossible. Vérifie ta connexion.',
    };
  }

  // --- Photos ----------------------------------------------------------------

  /// Ouvre la petite feuille du bouton « + » : prendre une photo avec
  /// l'appareil, ou en choisir une dans la galerie. Dans les deux cas la photo
  /// part directement, sans étape de confirmation.
  Future<void> _ouvrirAttachement() async {
    if (_envoiImage || _enregistrement) return;
    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Prendre une photo'),
              subtitle: const Text('Ouvre l\'appareil photo et l\'envoie'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choisir dans la galerie'),
              subtitle: const Text('Choisis une photo, puis envoie-la'),
              onTap: () => Navigator.pop(context, 'galerie'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choix == null) return;
    await _choisirPhoto(
      choix == 'camera' ? ImageSource.camera : ImageSource.gallery,
    );
  }

  /// Ouvre l'appareil photo ou la galerie, puis envoie la photo choisie.
  Future<void> _choisirPhoto(ImageSource source) async {
    if (_envoiImage) return;
    XFile? fichier;
    try {
      fichier = await _selecteurImages.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
    } catch (e) {
      // Plateforme sans appareil photo / galerie (bureau Linux, droits
      // refusés…) : on prévient au lieu de planter.
      debugPrint('[KinFlow] Photo indisponible: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Appareil photo ou galerie indisponible sur cet appareil.',
          ),
        ),
      );
      return;
    }
    if (fichier == null || !mounted) return;
    final octets = await fichier.readAsBytes();
    if (!mounted || octets.isEmpty) return;
    Journal.i('SOCIAL', 'Photo choisie', {
      'ami': widget.nom,
      'octets': octets.length,
    });
    await _envoyerImage(octets, _extensionPhoto(fichier));
  }

  /// Extension du fichier, pour le type MIME envoyé au bucket.
  String _extensionPhoto(XFile fichier) {
    final nom = fichier.name.toLowerCase();
    for (final ext in const ['jpg', 'jpeg', 'png', 'webp', 'gif']) {
      if (nom.endsWith('.$ext')) return ext;
    }
    final mime = (fichier.mimeType ?? '').toLowerCase();
    if (mime.contains('png')) return 'png';
    if (mime.contains('webp')) return 'webp';
    return 'jpg';
  }

  /// Envoie une photo : la bulle apparaît aussitôt (aperçu depuis la mémoire),
  /// puis passe à « envoyé » une fois le téléversement et le message confirmés.
  Future<void> _envoyerImage(Uint8List octets, String extension) async {
    final tempId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    // Une photo peut aussi répondre à un message : la référence est figée ici.
    final cite = _reponseA;
    final repondreA = cite?['id']?.toString();
    final apercu = cite == null ? null : _apercuDepuisMessage(cite);
    setState(() {
      _envoiImage = true;
      _reponseA = null;
      _photosLocales[tempId] = octets;
      _messages.add({
        'id': tempId,
        'contenu': '',
        'cree_a': DateTime.now().toIso8601String(),
        'moi': true,
        'statut': 'en_cours',
        'type_message': 'image',
        'image_extension': extension,
        if (repondreA != null && repondreA.isNotEmpty) ...{
          'reply_to_message_id': repondreA,
          'reply_to': ?apercu,
        },
      });
    });
    _descendreEnBas();
    await _pousserImage(tempId, octets, extension, repondreA: repondreA);
  }

  /// Réessaie l'envoi d'une photo en échec (appui sur la bulle).
  Future<void> _reessayerImage(Map<String, dynamic> message) async {
    final id = message['id']?.toString() ?? '';
    final octets = _photosLocales[id];
    if (octets == null || octets.isEmpty) return;
    await _pousserImage(
      id,
      octets,
      message['image_extension']?.toString() ?? 'jpg',
      bucketExistant: message['image_bucket_local']?.toString(),
      repondreA: message['reply_to_message_id']?.toString(),
    );
  }

  /// Téléverse (si nécessaire) puis envoie le message photo. [bucketExistant]
  /// évite de re-téléverser lors d'un renvoi après échec d'envoi.
  Future<void> _pousserImage(
    String tempId,
    Uint8List octets,
    String extension, {
    String? bucketExistant,
    String? repondreA,
  }) async {
    setState(() {
      _envoiImage = true;
      final index = _messages.indexWhere((m) => m['id'] == tempId);
      if (index != -1) {
        _messages[index] = {..._messages[index], 'statut': 'en_cours'};
      }
    });

    String? bucket = (bucketExistant != null && bucketExistant.isNotEmpty)
        ? bucketExistant
        : null;
    if (bucket == null) {
      bucket = await SupabaseService().televerserImage(
        amiId: widget.amiId,
        octets: octets,
        extension: extension,
      );
      if (bucket != null && mounted) {
        final index = _messages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _messages[index] = {
            ..._messages[index],
            'image_bucket_local': bucket,
          };
        }
      }
    }

    String? resultat;
    if (bucket != null) {
      resultat = await SupabaseService().envoyerMessageAmi(
        amiId: widget.amiId,
        contenu: '',
        imageChemin: bucket,
        repondreA: repondreA,
      );
    }

    if (!mounted) return;
    setState(() => _envoiImage = false);
    if (resultat == 'envoye') {
      Journal.s('SOCIAL', 'Photo envoyée', {'ami': widget.nom});
      setState(() {
        _messages.removeWhere((m) => m['id'] == tempId);
        _photosLocales.remove(tempId);
      });
      await _charger(silencieux: true);
    } else {
      final televersementEchoue = bucket == null;
      final detail = SupabaseService().derniereErreur;
      Journal.a(
        'SOCIAL',
        televersementEchoue
            ? 'Photo non envoyée : téléversement échoué'
            : 'Photo non envoyée : enregistrement du message échoué',
        {
          'ami': widget.nom,
          if (detail != null && detail.isNotEmpty) 'erreur': detail,
          'resultat': ?resultat,
        },
      );
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == tempId);
        if (index != -1) {
          _messages[index] = {..._messages[index], 'statut': 'echec'};
        }
      });
      // On remonte le détail lisible (bucket manquant, droits, réseau…) au
      // lieu d'un « impossible » générique qui ne dit pas quoi corriger.
      final message = resultat == null
          ? (televersementEchoue
                ? (detail != null && detail.isNotEmpty
                      ? 'Photo non envoyée : $detail'
                      : 'Téléversement de la photo impossible. Réessaie.')
                : (detail != null && detail.isNotEmpty
                      ? 'Photo envoyée mais message non enregistré : $detail'
                      : 'Photo envoyée mais message non enregistré. Réessaie.'))
          : _messageErreur(resultat);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Un message est une photo s'il vient du serveur avec ce type, ou s'il
  /// s'agit d'un envoi local encore en mémoire.
  bool _estImage(Map<String, dynamic> message) {
    if (message['type_message']?.toString() == 'image') return true;
    final id = message['id']?.toString() ?? '';
    return _photosLocales.containsKey(id);
  }

  /// Bulle d'une photo : aperçu depuis la mémoire pour les envois optimistes,
  /// URL signée résolue à la volée pour les photos déjà reçues.
  Widget _bulleImage(Map<String, dynamic> message) {
    final moi = message['moi'] == true;
    final statut = _statutMessage(message);
    final echec = statut == 'echec';
    final largeur = MediaQuery.of(context).size.width * 0.66;

    final rayon = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(moi ? 16 : 4),
      bottomRight: Radius.circular(moi ? 4 : 16),
    );

    final photo = Stack(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: largeur,
            maxHeight: 320,
            minWidth: 120,
            minHeight: 90,
          ),
          child: _apercuPhoto(message),
        ),
        Positioned(
          right: 6,
          bottom: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _heure(message['cree_a']),
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
                if (moi) ...[
                  const SizedBox(width: 4),
                  _indicateurStatut(statut),
                ],
              ],
            ),
          ),
        ),
        if (echec)
          const Positioned(
            left: 6,
            top: 6,
            child: Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
          ),
      ],
    );

    // Une photo qui répond à un message porte la citation AU-DESSUS de l'image,
    // dans la même bulle arrondie.
    final avecCitation =
        (message['reply_to_message_id']?.toString() ?? '').isNotEmpty;

    final bulle = Container(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: rayon,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: rayon,
        child: avecCitation
            ? SizedBox(
                width: largeur,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: Colors.black.withValues(alpha: 0.45),
                      padding: const EdgeInsets.all(6),
                      child: _citationBulle(message),
                    ),
                    photo,
                  ],
                ),
              )
            : photo,
      ),
    );

    // Appui : plein écran (ou renvoi si l'envoi a échoué). Appui long : menu
    // Supprimer.
    return Align(
      alignment: moi ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: echec
            ? () => _reessayerImage(message)
            : () => _ouvrirPhoto(message),
        onLongPress: () => _menuAppuiLong(message),
        child: bulle,
      ),
    );
  }

  /// Aperçu de la photo d'un message : mémoire (envoi local), puis URL signée.
  Widget _apercuPhoto(
    Map<String, dynamic> message, {
    BoxFit ajustement = BoxFit.cover,
  }) {
    final id = message['id']?.toString() ?? '';
    final local = _photosLocales[id];
    if (local != null) {
      return Image.memory(local, fit: ajustement, gaplessPlayback: true);
    }
    final bucket = message['image_chemin']?.toString() ?? '';
    if (bucket.isEmpty) return _photoIndisponible();
    return FutureBuilder<String?>(
      future: _urlPhoto(bucket),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AttentePhoto();
        }
        final url = snapshot.data ?? '';
        if (url.isEmpty) return _photoIndisponible();
        return Image.network(
          url,
          fit: ajustement,
          loadingBuilder: (context, child, progression) =>
              progression == null ? child : const _AttentePhoto(),
          errorBuilder: (_, _, _) => _photoIndisponible(),
        );
      },
    );
  }

  /// URL signée d'une photo, mémorisée par chemin : la discussion se
  /// rafraîchit toutes les 8 s, inutile de re-signer à chaque fois.
  Future<String?> _urlPhoto(String chemin) {
    return _urlsPhotos.putIfAbsent(
      chemin,
      () => SupabaseService().urlImageSignee(chemin),
    );
  }

  Widget _photoIndisponible() {
    return Container(
      width: 200,
      height: 130,
      color: Colors.black26,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: Colors.white70),
          SizedBox(height: 4),
          Text(
            'Photo indisponible',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// Affiche la photo en plein écran (pincement pour zoomer).
  Future<void> _ouvrirPhoto(Map<String, dynamic> message) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(8),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 4,
                child: Center(
                  child: _apercuPhoto(message, ajustement: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                tooltip: 'Fermer',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Charge l'état des autorisations de localisation avec l'ami(e).
  Future<void> _chargerAutorisations() async {
    final etat = await SupabaseService().etatAutorisationsLocalisation(
      widget.amiId,
    );
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
    await ouvrirAutorisationsLocalisation(
      context,
      amiId: widget.amiId,
      nom: widget.nom,
      onChanged: (etat) {
        if (mounted) setState(() => _autorisations = etat);
      },
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
      Journal.a('SOCIAL', 'Retrait de l\'ami(e) non enregistré', {
        'ami': widget.nom,
      });
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

  Future<void> _menuSelectionne(String valeur) async {
    if (valeur == 'localiser_simple') {
      _localiserAvec('simple');
    } else if (valeur == 'localiser_urgence') {
      _localiserAvec('urgence');
    } else if (valeur == 'autorisations') {
      _ouvrirAutorisations();
    } else if (valeur == 'renommer') {
      _renommerAmi();
    } else if (valeur == 'signaler') {
      await signalerUtilisateur(context, userId: widget.amiId);
    } else if (valeur == 'bloquer') {
      final ok = await bloquerUtilisateur(
        context,
        userId: widget.amiId,
        nom: widget.nom,
      );
      if (!ok || !mounted) return;
      // Bloquer supprime l'amitié : la discussion n'a plus lieu d'être.
      widget.onAmiSupprime?.call();
      Navigator.of(context).pop();
    } else if (valeur == 'retirer') {
      _confirmerRetrait();
    }
  }

  Future<void> _renommerAmi() async {
    final controller = TextEditingController(
      text: _nomLocal.isEmpty ? widget.nom : _nomLocal,
    );
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
    if (!mounted || nom == null) return;
    // Enregistré sur l'appareil : le nom choisi survit à la fermeture de la
    // discussion. Un champ vidé rétablit le nom d'origine.
    await SupabaseService().definirSurnomAmi(widget.amiId, nom);
    if (!mounted) return;
    Journal.i('SOCIAL', 'Ami(e) renommé', {
      'avant': _nomLocal.isEmpty ? widget.nom : _nomLocal,
      'apres': nom.isEmpty ? '(nom d\'origine)' : nom,
    });
    setState(() => _nomLocal = nom);
  }

  /// Sous-titre de l'en-tête : état de la discussion.
  String _sousTitreEntete() {
    return 'Discussion privée';
  }

  String _heure(Object? brut) {
    final d = brut == null
        ? null
        : DateTime.tryParse(brut.toString())?.toLocal();
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  /// Date d'envoi d'un message (heure locale), ou null si elle est inconnue.
  DateTime? _dateMessage(Map<String, dynamic> message) {
    final brut = message['cree_a'];
    if (brut == null) return null;
    return DateTime.tryParse(brut.toString())?.toLocal();
  }

  bool _memeJour(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Libellé du séparateur de jour, façon WhatsApp : « Aujourd'hui », « Hier »,
  /// le nom du jour pour la semaine écoulée, puis la date.
  String _libelleJour(DateTime date) {
    final maintenant = DateTime.now();
    final aujourdHui = DateTime(
      maintenant.year,
      maintenant.month,
      maintenant.day,
    );
    final jour = DateTime(date.year, date.month, date.day);
    final difference = aujourdHui.difference(jour).inDays;

    if (difference == 0) return "Aujourd'hui";
    if (difference == 1) return 'Hier';

    const nomsJours = [
      'lundi',
      'mardi',
      'mercredi',
      'jeudi',
      'vendredi',
      'samedi',
      'dimanche',
    ];
    if (difference > 1 && difference < 7) {
      final nom = nomsJours[jour.weekday - 1];
      return '${nom[0].toUpperCase()}${nom.substring(1)}';
    }

    const nomsMois = [
      'janvier',
      'février',
      'mars',
      'avril',
      'mai',
      'juin',
      'juillet',
      'août',
      'septembre',
      'octobre',
      'novembre',
      'décembre',
    ];
    final texte = '${jour.day} ${nomsMois[jour.month - 1]}';
    return jour.year == maintenant.year ? texte : '$texte ${jour.year}';
  }

  /// Regroupe les messages par journée, dans l'ordre chronologique.
  List<_GroupeJour> _groupesParJour() {
    final groupes = <_GroupeJour>[];
    for (final message in _messages) {
      final date = _dateMessage(message);
      final jour = date == null
          ? null
          : DateTime(date.year, date.month, date.day);
      final dernier = groupes.isEmpty ? null : groupes.last;
      final memeJour =
          dernier != null &&
          ((jour == null && dernier.jour == null) ||
              (jour != null &&
                  dernier.jour != null &&
                  _memeJour(jour, dernier.jour!)));
      if (!memeJour) groupes.add(_GroupeJour(jour));
      groupes.last.messages.add(message);
    }
    return groupes;
  }

  /// Construit la liste des messages avec, pour chaque journée, un en-tête
  /// épinglé en haut : comme dans WhatsApp, le jour reste visible pendant
  /// tout le défilement sans avoir à le chercher.
  List<Widget> _sliversMessages(ThemeData theme) {
    // Fond opaque : l'en-tête reste lisible quand les messages défilent
    // derrière lui.
    final couleurFond = theme.colorScheme.surfaceContainerHighest;
    final couleurTexte = theme.colorScheme.onSurface.withValues(alpha: 0.75);

    final slivers = <Widget>[];
    for (final groupe in _groupesParJour()) {
      if (groupe.jour != null) {
        slivers.add(
          SliverPersistentHeader(
            pinned: true,
            delegate: _EnteteJourDelegate(
              libelle: _libelleJour(groupe.jour!),
              couleurFond: couleurFond,
              couleurTexte: couleurTexte,
            ),
          ),
        );
      }
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final message = groupe.messages[index];
            // Clé stable par message : sans elle, Flutter réutilise l'état
            // d'une bulle vocale pour un AUTRE message après un rechargement
            // (mauvaise source, lecture cassée).
            return _ligneMessage(message, groupe.jour, index);
          }, childCount: groupe.messages.length),
        ),
      );
    }
    return slivers;
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
            GestureDetector(
              onTap: () => ouvrirProfilAmi(
                context,
                userId: widget.amiId,
                nom: _nomLocal.isEmpty ? widget.nom : _nomLocal,
                avatarId: widget.avatar,
              ),
              child: AvatarAnimalWidget(taille: 38, avatarId: widget.avatar),
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
                      color: theme.colorScheme.onSurfaceVariant,
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
                    title: const Text('Localiser maintenant'),
                    subtitle: Text(
                      simpleAutorise
                          ? '${widget.nom} t\'a autorisé'
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
                    leading: const Icon(Icons.sos_outlined),
                    title: const Text('Localiser en urgence'),
                    subtitle: Text(
                      urgenceDispo ? 'Une seule fois' : 'Déjà utilisée',
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
                  value: 'signaler',
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.flag_outlined),
                    title: Text('Signaler'),
                  ),
                ),
                PopupMenuItem(
                  value: 'bloquer',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.block, color: theme.colorScheme.error),
                    title: Text(
                      'Bloquer',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
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
                : CustomScrollView(
                    controller: _defilement,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _carteAmitie(theme),
                        ),
                      ),
                      if (_messages.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _vide(theme),
                        )
                      else ...[
                        ..._sliversMessages(theme),
                        const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      ],
                    ],
                  ),
          ),
          _apercuReponseSaisie(theme),
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
        padding: const EdgeInsets.fromLTRB(40, 18, 40, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: KinColors.primary.withValues(alpha: 0.10),
              ),
              child: const Icon(
                Icons.forum_outlined,
                size: 32,
                color: KinColors.primary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Aucun message échangé',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Carte d'amitié affichée en tête de discussion : les deux profils côte à
  /// côte. Les réglages (localisation, renommer) restent dans le menu de la
  /// barre d'en haut.
  Widget _carteAmitie(ThemeData theme) {
    final nomAmi = _nomLocal.isEmpty ? widget.nom : _nomLocal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Card(
        elevation: 0,
        color: KinColors.primary.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: KinColors.primary.withValues(alpha: 0.18)),
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
                      userId: SupabaseService().userId,
                    ),
                  ),
                  _maillon(),
                  Expanded(
                    child: _profilAmi(
                      nomAmi,
                      widget.avatar,
                      'Votre ami(e)',
                      userId: widget.amiId,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Un profil (avatar + nom + rôle) de la carte d'amitié.
  Widget _profilAmi(
    String nom,
    String? avatarId,
    String role, {
    String? userId,
  }) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => ouvrirProfilAmi(
            context,
            userId: userId ?? '',
            nom: nom,
            avatarId: avatarId,
          ),
          child: AvatarAnimalWidget(taille: 56, avatarId: avatarId),
        ),
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

  /// Messages système de localisation : ORANGE quand on a été localisé (simple),
  /// rouge pour l'urgence. Le bleu est réservé aux tags et aux messages reçus.
  static const Color _orangeLocalisation = Color(0xFFEF6C00);

  /// Messages système de localisation d'urgence : rouge.
  static const Color _rougeUrgence = Color(0xFFC62828);

  Widget _bulle(Map<String, dynamic> message) {
    if (message['est_systeme'] == true) return _bulleSysteme(message);
    if (_estImage(message)) return _bulleImage(message);
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
      child: _contenuTexte(message, texte, statut, moi),
    );

    // Appui normal : copie le texte (un message en échec se renvoie au lieu
    // de se copier). Appui long : menu Modifier / Supprimer / Copier.
    return Align(
      alignment: moi ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: echec
            ? () => _envoyerTexte(
                texte,
                remplaceId: message['id']?.toString(),
                repondreA: message['reply_to_message_id']?.toString(),
                apercu: (message['reply_to'] as Map?)?.cast<String, dynamic>(),
              )
            : () => _copierMessage(message),
        onLongPress: () => _menuAppuiLong(message),
        child: bulle,
      ),
    );
  }

  /// Contenu d'une bulle texte. Quand le message répond à un autre, la citation
  /// occupe toute la largeur de la bulle (comme WhatsApp) ; sinon la bulle
  /// reste ajustée au texte.
  Widget _contenuTexte(
    Map<String, dynamic> message,
    String texte,
    String statut,
    bool moi,
  ) {
    final avecCitation =
        (message['reply_to_message_id']?.toString() ?? '').isNotEmpty;

    Widget colonne(CrossAxisAlignment align) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: align,
      children: [
        if (avecCitation) ...[
          _citationBulle(message),
          const SizedBox(height: 6),
        ],
        Text(
          texte,
          style: const TextStyle(
            color: Colors.white,
            height: 1.35,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              _heure(message['cree_a']),
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
            if (message['modifie_a'] != null)
              Text(
                ' • modifié',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white70,
                  fontStyle: FontStyle.italic,
                ),
              ),
            if (moi) ...[const SizedBox(width: 4), _indicateurStatut(statut)],
          ],
        ),
      ],
    );

    if (!avecCitation) return colonne(CrossAxisAlignment.end);
    // Largeur intrinsèque bornée par la largeur maximale de la bulle : la
    // citation et le texte partagent ainsi la même largeur.
    return IntrinsicWidth(child: colonne(CrossAxisAlignment.stretch));
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
      resoudreSource: (bucket == null || bucket.isEmpty)
          ? null
          : () => SupabaseService().urlVocalSignee(bucket),
      dureeMs: (message['audio_duree_ms'] as num?)?.toInt() ?? 0,
      moi: moi,
      heure: _heure(message['cree_a']),
      indicateur: moi ? _indicateurStatut(statut) : null,
      formes: _formesVocal(message),
      graine: message['audio_chemin']?.toString() ?? message['id']?.toString(),
      // Citation du message auquel ce vocal répond (aperçu dans la bulle).
      citation: (message['reply_to_message_id']?.toString() ?? '').isNotEmpty
          ? _citationBulle(message)
          : null,
      // Le rond de l'animal est DANS la bulle, à gauche du triangle : le mien
      // pour mes vocaux, celui de l'ami(e) pour les vocaux reçus.
      avatarId: moi ? (_monCompte?['avatar']) : widget.avatar,
      onAvatarTap: moi
          ? null
          : () => ouvrirProfilAmi(
              context,
              userId: widget.amiId,
              nom: widget.nom,
              avatarId: widget.avatar,
            ),
    );

    // Un vocal en échec se renvoie d'un appui. L'appui long ouvre le menu
    // (suppression) : l'appui normal reste réservé à la lecture du vocal,
    // gérée par la bulle elle-même.
    if (echec) {
      return GestureDetector(
        onTap: () => _reessayerVocal(message),
        onLongPress: () => _menuAppuiLong(message),
        child: bulle,
      );
    }
    return GestureDetector(
      onLongPress: () => _menuAppuiLong(message),
      child: bulle,
    );
  }

  /// Forme d'onde d'un vocal : `audio_formes` côté serveur est un tableau de
  /// pourcentages (0..100), converti ici en fractions 0..1 pour le dessin.
  /// Liste vide = message sans données (ancien vocal) : la bulle dessinera une
  /// forme d'onde stable à la place.
  List<double> _formesVocal(Map<String, dynamic> message) {
    final brut = message['audio_formes'];
    if (brut is! List || brut.isEmpty) return const [];
    return [
      for (final v in brut)
        if (v is num) (v / 100).clamp(0.0, 1.0),
    ];
  }

  // --- Réponse à un message (façon WhatsApp) ---------------------------------

  /// Une ligne de la discussion : la bulle, glissable vers la droite pour
  /// répondre, et brièvement surlignée quand on vient de naviguer jusqu'à elle.
  Widget _ligneMessage(Map<String, dynamic> message, Object? jour, int index) {
    final id = message['id']?.toString() ?? '';
    final cle = id.isEmpty
        ? null
        : _clesMessages.putIfAbsent(id, () => GlobalKey());
    final surligne = id.isNotEmpty && _messageSurligne == id;

    // Conteneur transparent en temps normal : la mise en évidence apparaît et
    // s'efface en douceur autour de la bulle.
    final bulle = AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: surligne
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
      ),
      child: KeyedSubtree(
        key: cle ?? ValueKey('msg_${jour}_$index'),
        child: _bulle(message),
      ),
    );

    if (!_peutCiter(message)) return bulle;

    // Glissement vers la droite → mode réponse. `confirmDismiss` renvoie false :
    // la bulle revient à sa place, seul l'aperçu de réponse est activé.
    return Dismissible(
      key: ValueKey('reponse_$id'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.22},
      confirmDismiss: (_) async {
        _preparerReponse(message);
        return false;
      },
      background: _fondGlissementReponse(),
      child: bulle,
    );
  }

  /// Fond révélé pendant le glissement d'un message : l'icône « répondre ».
  Widget _fondGlissementReponse() {
    final couleur = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: couleur.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.reply, size: 18, color: couleur),
        ),
      ),
    );
  }

  /// Passe en mode réponse : l'aperçu du message s'affiche au-dessus du
  /// clavier et le champ de saisie prend le focus.
  void _preparerReponse(Map<String, dynamic> message) {
    if (!_peutCiter(message)) return;
    HapticFeedback.selectionClick();
    Journal.i('SOCIAL', 'Message sélectionné pour une réponse', {
      'ami': widget.nom,
      'type': message['type_message'] ?? 'texte',
    });
    setState(() => _reponseA = message);
    _focusSaisie.requestFocus();
  }

  /// Annule la réponse en cours : retour à une saisie normale.
  void _annulerReponse() {
    if (_reponseA == null) return;
    setState(() => _reponseA = null);
    Journal.i('SOCIAL', 'Réponse annulée', {'ami': widget.nom});
  }

  /// Résumé d'un message pour l'aperçu d'une citation (jamais le message
  /// entier) : le texte s'il existe, sinon une étiquette selon le type.
  String _resumeMessage(Map<String, dynamic> message) {
    final type = message['type_message']?.toString() ?? 'texte';
    if (type == 'vocal') return '🎤 Message vocal';
    if (type == 'image') return '📷 Photo';
    if (type == 'texte' && message['est_systeme'] != true) {
      final texte = (message['contenu'] as String? ?? '').trim();
      if (texte.isNotEmpty) return texte;
    }
    final texte = (message['contenu'] as String? ?? '').trim();
    return texte.isEmpty ? 'Message' : texte;
  }

  /// Aperçu du message cité, juste au-dessus du clavier, avec la croix qui
  /// annule la réponse.
  Widget _apercuReponseSaisie(ThemeData theme) {
    final message = _reponseA;
    if (message == null) return const SizedBox.shrink();
    final couleur = theme.colorScheme.primary;
    final moi = message['moi'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 2, 5),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Réponse à ${moi ? 'vous' : _nomAmiCourant()}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: couleur,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          _resumeMessage(message),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _annulerReponse,
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Annuler la réponse',
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 3, color: couleur),
            ),
          ],
        ),
      ),
    );
  }

  /// Citation affichée DANS une bulle : barre colorée, nom de l'expéditeur du
  /// message cité et résumé. Un appui ramène au message d'origine.
  Widget _citationBulle(Map<String, dynamic> message) {
    final id = message['reply_to_message_id']?.toString() ?? '';
    if (id.isEmpty) return const SizedBox.shrink();
    final brut = message['reply_to'];
    final apercu = brut is Map ? brut.cast<String, dynamic>() : null;
    final moi = apercu?['moi'] == true;
    return CitationMessage(
      nom: apercu == null ? 'Message' : (moi ? 'Vous' : _nomAmiCourant()),
      resume: apercu == null
          ? "Message d'origine indisponible"
          : _resumeMessage(apercu),
      onTap: () => _allerAuMessage(id),
    );
  }

  /// Retrouve le message cité et fait défiler la conversation jusqu'à lui.
  /// Les messages hors écran ne sont pas construits : on avance par paliers
  /// dans la bonne direction jusqu'à ce que sa bulle existe, puis on la centre.
  Future<void> _allerAuMessage(String id) async {
    if (id.isEmpty) return;
    Journal.i('SOCIAL', 'Navigation vers le message cité', {'ami': widget.nom});

    var index = _messages.indexWhere((m) => m['id']?.toString() == id);
    if (index == -1) {
      // Peut-être arrivé après le dernier rafraîchissement : on recharge une
      // fois avant de renoncer.
      await _charger(silencieux: true);
      if (!mounted) return;
      index = _messages.indexWhere((m) => m['id']?.toString() == id);
    }
    if (index == -1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Le message d'origine n'est plus disponible dans la conversation.",
          ),
        ),
      );
      return;
    }

    final cle = _clesMessages.putIfAbsent(id, () => GlobalKey());
    for (var essai = 0; essai < 60; essai++) {
      final contexte = cle.currentContext;
      if (contexte != null) {
        if (!contexte.mounted) return;
        await Scrollable.ensureVisible(
          contexte,
          alignment: 0.35,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
        );
        _surlignerMessage(id);
        return;
      }
      if (!mounted || !_defilement.hasClients) return;
      final position = _defilement.position;

      // Sens du déplacement : on se cale sur le message construit le plus
      // proche, pour savoir si la cible est au-dessus ou en dessous.
      var sens = 0;
      for (var i = 0; i < _messages.length; i++) {
        if (i == index) continue;
        final idAutre = _messages[i]['id']?.toString() ?? '';
        if (idAutre.isEmpty) continue;
        if (_clesMessages[idAutre]?.currentContext == null) continue;
        sens = i < index ? 1 : -1;
        break;
      }
      if (sens == 0) break;

      final pas = position.viewportDimension * 0.7;
      final cible = (position.pixels + sens * pas)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((cible - position.pixels).abs() < 1) break;
      _defilement.jumpTo(cible);
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Impossible de retrouver ce message dans la discussion.'),
      ),
    );
  }

  /// Met brièvement le message en évidence, le temps de le repérer.
  void _surlignerMessage(String id) {
    _minuteurSurligne?.cancel();
    if (!mounted) return;
    setState(() => _messageSurligne = id);
    _minuteurSurligne = Timer(const Duration(milliseconds: 1800), () {
      if (!mounted || _messageSurligne != id) return;
      setState(() => _messageSurligne = null);
    });
  }

  // --- Appui sur un message : copier, modifier, supprimer --------------------

  /// Une bulle d'identifiant `local_` n'existe pas encore côté serveur (envoi
  /// en cours ou échec) : aucune RPC possible, seulement une action locale.
  bool _coteServeur(Map<String, dynamic> message) {
    final id = message['id']?.toString() ?? '';
    return id.isNotEmpty && !id.startsWith('local_');
  }

  /// Appui normal sur un message texte : copie son contenu dans le
  /// presse-papiers. (Sur un vocal, l'appui normal sert à la lecture : c'est
  /// la bulle elle-même qui le gère.)
  Future<void> _copierMessage(Map<String, dynamic> message) async {
    final texte = (message['contenu'] as String? ?? '').trim();
    if (texte.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: texte));
    Journal.i('SOCIAL', 'Message copié', {'ami': widget.nom});
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message copié')));
  }

  /// Appui long sur une bulle : feuille d'actions.
  /// Message texte → Copier / Modifier (si c'est le mien) / Supprimer.
  /// Message vocal ou photo → Supprimer uniquement (rien à copier ni à éditer).
  Future<void> _menuAppuiLong(Map<String, dynamic> message) async {
    HapticFeedback.mediumImpact();
    final theme = Theme.of(context);
    final moi = message['moi'] == true;
    final vocal = _estVocal(message);
    final image = _estImage(message);
    final texte = (message['contenu'] as String? ?? '').trim();
    final modifiable =
        moi &&
        !vocal &&
        !image &&
        texte.isNotEmpty &&
        _coteServeur(message) &&
        _statutMessage(message) != 'echec';

    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_peutCiter(message))
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Répondre'),
                subtitle: const Text('Citer ce message dans ta réponse'),
                onTap: () => Navigator.pop(context, 'repondre'),
              ),
            if (!vocal && !image && texte.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copier'),
                onTap: () => Navigator.pop(context, 'copier'),
              ),
            if (modifiable)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Modifier'),
                subtitle: const Text('Corrige le texte de ce message'),
                onTap: () => Navigator.pop(context, 'modifier'),
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(
                moi ? 'Supprimer' : 'Supprimer de mon côté',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: moi
                  ? null
                  : const Text('Ton ami(e) le gardera dans sa discussion'),
              onTap: () => Navigator.pop(context, 'supprimer'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted || choix == null) return;
    if (choix == 'repondre') {
      _preparerReponse(message);
    } else if (choix == 'copier') {
      await _copierMessage(message);
    } else if (choix == 'modifier') {
      await _modifierMessage(message);
    } else if (choix == 'supprimer') {
      await _supprimerMessage(message);
    }
  }

  /// Édition d'un message texte envoyé : dialogue pré-rempli, appel du serveur,
  /// puis mise à jour optimiste de la bulle (et du cache local).
  Future<void> _modifierMessage(Map<String, dynamic> message) async {
    final id = message['id']?.toString() ?? '';
    if (id.isEmpty || !mounted) return;
    final controleur = TextEditingController(
      text: message['contenu'] as String? ?? '',
    );
    final nouveau = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier le message'),
        content: TextField(
          controller: controleur,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          maxLength: 4000,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Écrire un message…',
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controleur.text.trim()),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (nouveau == null || nouveau.isEmpty || !mounted) return;
    final ancien = (message['contenu'] as String? ?? '').trim();
    if (nouveau == ancien) return;

    final resultat = await SupabaseService().modifierMessageAmi(
      messageId: id,
      contenu: nouveau,
    );
    if (!mounted) return;
    if (resultat == 'modifie') {
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == id);
        if (index != -1) {
          _messages[index] = {
            ..._messages[index],
            'contenu': nouveau,
            'modifie_a': DateTime.now().toIso8601String(),
          };
        }
      });
      await SupabaseService().sauverMessagesCache(widget.amiId, _messages);
      Journal.s('SOCIAL', 'Message modifié', {
        'ami': widget.nom,
        'caracteres': nouveau.length,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message modifié')));
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_messageErreur(resultat))));
    }
  }

  /// Suppression d'un message : confirmation, puis serveur (définitif pour
  /// l'expéditeur, masquage côté destinataire) ou simple retrait local pour
  /// une bulle pas encore envoyée.
  Future<void> _supprimerMessage(Map<String, dynamic> message) async {
    final id = message['id']?.toString() ?? '';
    if (id.isEmpty || !mounted) return;
    final theme = Theme.of(context);
    final moi = message['moi'] == true;
    final vocal = _estVocal(message);
    final image = _estImage(message);

    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          image
              ? 'Supprimer cette photo ?'
              : vocal
              ? 'Supprimer ce vocal ?'
              : 'Supprimer ce message ?',
        ),
        content: Text(
          moi
              ? 'Il sera supprimé pour toi et pour ton ami(e).'
              : 'Il sera retiré de ton fil de discussion ; ton ami(e) le '
                    'gardera dans le sien.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirme != true || !mounted) return;

    if (!_coteServeur(message)) {
      // Bulle locale : rien côté serveur, on retire la bulle (et le fichier
      // audio s'il existe encore sur l'appareil).
      final local = message['audio_local'] as String?;
      setState(() {
        _messages.removeWhere((m) => m['id'] == id);
        _photosLocales.remove(id);
      });
      if (local != null && local.isNotEmpty) {
        try {
          await File(local).delete();
        } catch (_) {}
      }
      await SupabaseService().sauverMessagesCache(widget.amiId, _messages);
      return;
    }

    final resultat = await SupabaseService().supprimerMessageAmi(
      id,
      // Seul l'expéditeur retire les fichiers du bucket (la politique Storage
      // l'exige de toute façon) ; le destinataire ne masque que son fil.
      audioChemin: moi ? message['audio_chemin']?.toString() : null,
      imageChemin: moi ? message['image_chemin']?.toString() : null,
    );
    if (!mounted) return;
    if (resultat == 'supprime') {
      setState(() => _messages.removeWhere((m) => m['id'] == id));
      await SupabaseService().sauverMessagesCache(widget.amiId, _messages);
      Journal.s('SOCIAL', 'Message supprimé', {
        'ami': widget.nom,
        'vocal': vocal,
        'masque_cote_destinataire': !moi,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            moi ? 'Message supprimé' : 'Message retiré de votre fil',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_messageErreur(resultat))));
    }
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
  /// en ORANGE s'il a été localisé, en bleu s'il a été tagué, en rouge pour
  /// une localisation d'urgence.
  Widget _bulleSysteme(Map<String, dynamic> message) {
    final type = message['type_systeme']?.toString() ?? '';
    final tag = type == 'tag_info';
    final urgence = type == 'loc_urgence';
    final moi = message['moi'] == true;
    // Couleur par point de vue : vert si c'est moi qui ai agi, rouge en
    // urgence, ORANGE si l'on vient de me localiser, bleu sinon (tag, ou
    // message système ancien).
    final Color fond;
    if (moi) {
      fond = _vertEnvoye;
    } else if (urgence) {
      fond = _rougeUrgence;
    } else if (type == 'loc_simple') {
      fond = _orangeLocalisation;
    } else {
      fond = _bleuRecu;
    }
    final icone = tag
        ? Icons.alternate_email
        : (urgence ? Icons.sos : Icons.my_location);
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
          if (message['latitude'] != null && message['longitude'] != null) ...[
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
    Journal.i('SOCIAL', 'Ouverture de l\'information taguée', {
      'info': infoId,
      'ami': widget.nom,
    });
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Coordonnées copiées : $texte')));
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
            // Petit « + » : prendre une photo ou en choisir une dans la
            // galerie, puis l'envoyer aussitôt.
            IconButton(
              onPressed: (_envoiImage || _envoiVocal)
                  ? null
                  : _ouvrirAttachement,
              icon: const Icon(Icons.add),
              iconSize: 26,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 44),
              tooltip: 'Envoyer une photo',
            ),
            const SizedBox(width: 2),
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
    final minutes = (_secondesVocal ~/ 60).toString().padLeft(2, '0');
    final secondes = (_secondesVocal % 60).toString().padLeft(2, '0');
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
              padding: EdgeInsets.only(left: 8, right: 8),
              child: Icon(Icons.mic, color: Colors.white, size: 20),
            ),
            // Le libellé peut être raccourci sur les petits écrans, mais le
            // minuteur garde toujours sa place entière, à droite.
            const Expanded(
              child: Text(
                'Enregistrement',
                style: TextStyle(color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Chiffres tabulaires : chaque seconde a exactement la même
            // largeur, le compteur ne « saute » plus d'un chiffre à l'autre.
            Text(
              '$minutes:$secondes',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 2),
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

/// Messages d'une même journée, avec l'en-tête de date qui les précède.
class _GroupeJour {
  _GroupeJour(this.jour);

  /// Jour concerné, ou null si la date est inconnue.
  final DateTime? jour;

  final List<Map<String, dynamic>> messages = [];
}

/// En-tête de jour épinglé en haut de la discussion (façon WhatsApp).
class _EnteteJourDelegate extends SliverPersistentHeaderDelegate {
  _EnteteJourDelegate({
    required this.libelle,
    required this.couleurFond,
    required this.couleurTexte,
  });

  final String libelle;
  final Color couleurFond;
  final Color couleurTexte;

  static const double _hauteur = 34;

  @override
  double get minExtent => _hauteur;

  @override
  double get maxExtent => _hauteur;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: couleurFond,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          libelle,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: couleurTexte,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _EnteteJourDelegate oldDelegate) {
    return oldDelegate.libelle != libelle ||
        oldDelegate.couleurFond != couleurFond ||
        oldDelegate.couleurTexte != couleurTexte;
  }
}

/// Petit indicateur affiché pendant le chargement d'une photo.
class _AttentePhoto extends StatelessWidget {
  const _AttentePhoto();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 200,
      height: 150,
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white70,
          ),
        ),
      ),
    );
  }
}
