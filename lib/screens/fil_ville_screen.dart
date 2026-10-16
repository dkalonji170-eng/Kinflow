import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ami_position.dart';
import '../models/information_ville.dart';
import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';
import '../utils/autorisation_loc.dart';
import '../utils/temps_relatif.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/social_ui.dart';
import 'chat_ami_screen.dart';
import 'scan_qr_ami_screen.dart';

/// Le fil de la ville : la suite d'informations publiées par KinFlow.
/// Les utilisateurs ne publient rien : ils réagissent en VERT (info
/// confirmée/utile) ou en ROUGE (info fausse), une réaction par personne,
/// et peuvent déposer un SEUL émoji chacun. Une petite pastille rouge signale
/// chaque information « nouvelle » depuis la dernière visite.
class FilVilleScreen extends StatefulWidget {
  const FilVilleScreen({super.key});

  @override
  State<FilVilleScreen> createState() => _FilVilleScreenState();
}

class _FilVilleScreenState extends State<FilVilleScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _rafraichissementAuto = Duration(seconds: 60);
  // Valeur spéciale renvoyée par la palette pour demander le retrait de
  // l'émoji déjà posé (il existe un bouton dédié dans la palette).
  static const String _retirerEmoji = '__retirer_mon_emoji__';
  // Palette de réaction : volontairement large mais choisie (le serveur
  // accepte n'importe quel émoji de 1 à 16 caractères). Les plus courants
  // sont placés d'abord pour être visibles sans faire défiler.
  static const List<String> _paletteEmojis = [
    // Réactions courantes d'abord
    '❤️', '😂', '👍', '😮', '😢', '😡', '🔥', '👏', '🎉', '💯', '🙏', '😍',
    // Smileys
    '😀', '😁', '😄', '😆', '😅', '🤣', '😊', '🥰', '😘', '😎', '🤔', '😴',
    '🤗', '🥳', '🥺', '😭', '😤', '🤯', '😱', '🤩', '🙃', '😉', '😋', '🤪',
    // Mains et gestes
    '👌', '✌️', '🤞', '🤝', '🙌', '💪', '👋', '🤙', '👊', '🫶',
    // Cœurs, symboles et divers
    '💔', '💖', '💘', '💕', '✨', '⭐', '🌟', '💡', '📢', '🚀', '🏆', '⚽',
    '🏀', '🍕', '☕', '🎂', '🎮', '🎵', '📣', '🌍', '☀️', '🌧️',
  ];

  late final TabController _tabController;
  List<InformationVille> _informations = [];
  bool _chargement = true;
  Timer? _minuteur;
  final ScrollController _defilementInfos = ScrollController();

  /// Information à mettre en évidence (retour depuis un tag) et clés de
  /// défilement par information.
  String? _infoEnEvidence;
  final Map<String, GlobalKey> _clesInfos = {};
  GlobalKey _cleInfo(String id) =>
      _clesInfos.putIfAbsent(id, () => GlobalKey());

  /// Dernière ouverture du fil : les infos publiées après cette date sont
  /// signalées par un petit point rouge (« nouvelle notification »).
  DateTime? _dernierVu;
  bool _premiereCharge = true;

  /// Filtre actif du fil d'actualité.
  String _filtre = 'tout';
  /// Filtre texte de la liste d'amis(es).
  final TextEditingController _rechercheAmis = TextEditingController();
  /// Prénom de l'utilisateur, pour le message d'accueil de l'en-tête.
  String _prenom = '';

  // --- Amis(es) -------------------------------------------------------------
  List<Map<String, dynamic>> _amis = [];
  List<Map<String, dynamic>> _demandes = [];
  /// Messages non lus par ami(e) : ami_id -> nombre.
  Map<String, int> _nonLus = {};
  /// Dernier message échangé par ami(e) : ami_id -> {contenu, moi, cree_a}.
  Map<String, Map<String, dynamic>> _apercus = {};
  bool _chargementAmis = true;
  /// Mon code AMI public (partageable), distinct du code de compte (secret).
  String _monCodeAmi = '';
  /// Vrai dès que la liste a été chargée une première fois : évite de
  /// recharger à chaque aller-retour sur l'onglet.
  bool _amisChargees = false;

  @override
  void initState() {
    super.initState();
    Journal.i('SOCIAL', 'Écran Social ouvert');
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_surChangementOnglet);
    _lireDernierVu();
    _chargerPrenom();
    SupabaseService().assurerPartagePosition();
    // On affiche d'abord ce qui est en cache local (visible même hors
    // connexion), puis on rafraîchit depuis le réseau.
    _chargerFilCache();
    _chargerAmisCache();
    _chargerFil();
    // Charge aussi les amis(es) dès l'ouverture : le point rouge de l'onglet
    // « Amis(es) » doit être visible même avant d'ouvrir cet onglet.
    _chargerAmis(silencieux: true);
    _minuteur = Timer.periodic(_rafraichissementAuto, (_) => _chargerFil());
  }

  @override
  void dispose() {
    Journal.i('SOCIAL', 'Écran Social fermé');
    _tabController.removeListener(_surChangementOnglet);
    _tabController.dispose();
    _minuteur?.cancel();
    _defilementInfos.dispose();
    _rechercheAmis.dispose();
    super.dispose();
  }

  /// À l'ouverture de l'onglet « Amis(es) », on charge (ou rafraîchit) la
  /// liste — jamais pendant l'animation de glissement.
  void _surChangementOnglet() {
    if (_tabController.indexIsChanging) return;
    Journal.i(
      'SOCIAL',
      'Onglet ${_tabController.index == 1 ? 'Amis(es)' : 'Information'} ouvert',
    );
    if (_tabController.index == 1) _chargerAmis(silencieux: _amisChargees);
  }

  Future<void> _chargerFil() async {
    final service = SupabaseService();
    final informations = await service.chargerFilInformations();
    if (!mounted) return;
    // Succès réseau : on met à jour l'affichage et le cache. Sinon (hors
    // ligne), on garde ce qui est déjà affiché (cache local).
    if (informations.isNotEmpty) {
      Journal.i('SOCIAL', 'Fil actualisé', {'infos': informations.length});
      setState(() {
        _informations = informations;
        _chargement = false;
      });
      await service.sauverInfosCache(informations);
    } else {
      // Serveur vide (tout a « disparu ») ou injoignable : on conserve
      // l'affichage, mais on retire les informations hors fenêtre (plus de
      // 48 h et non épinglées), puis on met le cache à jour. Une info déjà
      // lue reste donc visible jusqu'à sa disparition, pas au-delà.
      final actives = [
        for (final info in _informations)
          if (SupabaseService.informationActive(info)) info,
      ];
      Journal.a('SOCIAL',
          'Fil vide ou injoignable : ${_informations.length - actives.length} '
          'info(s) hors fenêtre retirée(s)');
      setState(() {
        _informations = actives;
        _chargement = false;
      });
      await service.sauverInfosCache(actives);
    }
    // Première charge réussie : on note « tout est vu » pour la prochaine
    // visite. Les infos arrivées après auront le point rouge.
    if (_premiereCharge && informations.isNotEmpty) {
      _premiereCharge = false;
      _marquerToutVu();
    }
  }

  /// Affiche tout de suite le fil depuis le cache local, avant le réseau.
  Future<void> _chargerFilCache() async {
    final cache = await SupabaseService().chargerInfosCache();
    if (!mounted || cache.isEmpty) return;
    Journal.i('SOCIAL', 'Fil affiché depuis le cache local',
        {'infos': cache.length});
    setState(() {
      _informations = cache;
      _chargement = false;
    });
  }

  Future<void> _lireDernierVu() async {
    final vu = await SupabaseService().lireDernierVuFil();
    if (!mounted) return;
    setState(() => _dernierVu = vu);
  }

  /// Charge le prénom de l'utilisateur pour personnaliser l'accueil.
  Future<void> _chargerPrenom() async {
    try {
      final profil = await SupabaseService().loadProfile();
      if (!mounted) return;
      final prenom = (profil?['prenom'] as String? ?? '').trim();
      if (prenom.isNotEmpty && prenom != _prenom) {
        setState(() => _prenom = prenom);
      }
    } catch (_) {}
  }

  /// Nombre d'informations nouvelles depuis la dernière visite.
  int get _nombreNouvelles => _informations.where(_estNouvelle).length;

  /// Total des messages non lus, toutes conversations confondues.
  int get _totalNonLus =>
      _nonLus.values.fold<int>(0, (somme, n) => somme + n);

  /// Le fil, épinglées d'abord puis du plus récent au plus ancien.
  List<InformationVille> get _filTrie {
    final liste = [..._informations];
    liste.sort((a, b) {
      if (a.epinglee != b.epinglee) return a.epinglee ? -1 : 1;
      return b.creeA.compareTo(a.creeA);
    });
    return liste;
  }

  /// Le fil après application du filtre choisi.
  List<InformationVille> get _filFiltre {
    final liste = _filTrie;
    switch (_filtre) {
      case 'neuf':
        return liste.where(_estNouvelle).toList();
      case 'epingle':
        return liste.where((i) => i.epinglee).toList();
      case 'confirme':
        return liste
            .where((i) => i.nbVerts > 0 && i.nbVerts >= i.nbRouges)
            .toList();
      case 'verifier':
        return liste
            .where((i) => i.nbRouges > 0 && i.nbRouges > i.nbVerts)
            .toList();
      case 'populaire':
        final liste2 = [...liste];
        liste2.sort((a, b) => _scoreInfo(b).compareTo(_scoreInfo(a)));
        return liste2;
      default:
        return liste;
    }
  }

  /// Score d'engagement d'une information (réactions + émojis), pour le tri
  /// « Populaires ».
  static int _scoreInfo(InformationVille info) {
    final emojis = info.emojis.fold<int>(0, (s, e) => s + e.$2);
    return info.nbVerts + info.nbRouges + emojis;
  }

  /// Les amis(es) filtrés par la recherche texte.
  List<Map<String, dynamic>> get _amisFiltres {
    final requete = _rechercheAmis.text.trim().toLowerCase();
    if (requete.isEmpty) return _amis;
    return _amis.where((a) {
      return _nomComplet(a).toLowerCase().contains(requete);
    }).toList();
  }

  /// Les amis(es) qui partagent actuellement une position (bandeau « Qui est
  /// où ? »).
  List<Map<String, dynamic>> get _amisPositionnes {
    return _amis.where((a) {
      return _doubleOuNull(a['latitude']) != null &&
          _doubleOuNull(a['longitude']) != null;
    }).toList();
  }

  /// Vrai si la position de l'ami(e) a été mise à jour très récemment
  /// (moins de 5 minutes) : sert de pastille « en ligne ».
  bool _positionRecente(Map<String, dynamic> ami) {
    final brut = ami['maj_a'];
    final majA = brut == null ? null : DateTime.tryParse(brut.toString());
    if (majA == null) return false;
    return DateTime.now().difference(majA.toLocal()).inMinutes < 5;
  }

  Future<void> _marquerToutVu() async {
    await SupabaseService().marquerFilVu();
  }

  bool _estNouvelle(InformationVille info) {
    final vu = _dernierVu;
    return vu != null && info.creeA.isAfter(vu);
  }

  /// Vrai si au moins une information est arrivée depuis la dernière visite :
  /// affiche le point rouge de l'onglet « Information ».
  bool get _aDesNouvellesInfos => _informations.any(_estNouvelle);

  /// Vrai si au moins un ami(e) a un message non lu : affiche le point rouge
  /// de l'onglet « Amis(es) ».
  bool get _aDesMessagesNonLus => _nonLus.values.any((n) => n > 0);

  // --- Tri du fil -----------------------------------------------------------

  // (Le tri est assuré par `_filTrie`, épinglées d'abord puis date.)

  // --- Amis(es) -------------------------------------------------------------

  /// Charge mes amis(es), les demandes reçues et mon code ami.
  /// [silencieux] garde l'écran affiché pendant une actualisation discrète.
  Future<void> _chargerAmis({bool silencieux = false}) async {
    if (!silencieux && mounted) {
      setState(() => _chargementAmis = true);
    }
    final service = SupabaseService();
    final resultats = await Future.wait<Object?>([
      service.mesAmis(),
      service.mesDemandesAmis(),
      service.monCodeAmi(),
      service.nbMessagesNonLusAmis(),
      service.marquerMessagesRecus(),
      service.apercusMessagesAmis(),
    ]);
    if (!mounted) return;
    final amis = resultats[0] as List<Map<String, dynamic>>;
    final demandes = resultats[1] as List<Map<String, dynamic>>;
    final codeAmi = (resultats[2] as String?) ?? '';
    final nonLus = resultats[3] as Map<String, int>;
    final apercus = resultats[5] as Map<String, Map<String, dynamic>>;
    // Réseau indisponible : on garde la liste déjà affichée (cache local).
    final succes = amis.isNotEmpty || demandes.isNotEmpty || codeAmi.isNotEmpty;
    if (succes) {
      Journal.i('SOCIAL', 'Amis(es) actualisés', {
        'amis': amis.length,
        'demandes': demandes.length,
        'non_lus': nonLus.values.fold<int>(0, (s, v) => s + v),
      });
    } else {
      Journal.a('SOCIAL', 'Amis(es) injoignables, cache local conservé');
    }
    setState(() {
      if (succes || _amis.isEmpty) {
        _amis = amis;
        _demandes = demandes;
        _monCodeAmi = codeAmi;
        _nonLus = nonLus;
        _apercus = apercus;
      }
      _chargementAmis = false;
      _amisChargees = true;
    });
    if (succes) {
      await service.sauverAmisCache(
        amis: amis,
        demandes: demandes,
        codeAmi: codeAmi,
        nonLus: nonLus,
        apercus: apercus,
      );
    }
  }

  /// Affiche tout de suite la liste d'amis depuis le cache local, avant le
  /// réseau : elle reste visible même sans connexion.
  Future<void> _chargerAmisCache() async {
    final cache = await SupabaseService().chargerAmisCache();
    if (!mounted || cache == null) return;
    final amis = (cache['amis'] as List?) ?? const [];
    final demandes = (cache['demandes'] as List?) ?? const [];
    Journal.i('SOCIAL', 'Amis(es) affichés depuis le cache local', {
      'amis': amis.length,
      'demandes': demandes.length,
    });
    setState(() {
      _amis = [
        for (final e in amis)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
      _demandes = [
        for (final e in demandes)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
      _monCodeAmi = cache['code_ami'] as String? ?? '';
      final nonLus = cache['non_lus'];
      if (nonLus is Map) {
        _nonLus = {
          for (final e in nonLus.entries)
            e.key.toString(): (e.value as num?)?.toInt() ?? 0,
        };
      }
      final apercus = cache['apercus'];
      if (apercus is Map) {
        _apercus = {
          for (final e in apercus.entries)
            if (e.value is Map)
              e.key.toString(): Map<String, dynamic>.from(e.value as Map),
        };
      }
      _chargementAmis = false;
      _amisChargees = true;
    });
  }

  /// Menu ⋮ de l'AppBar : toutes les actions d'ajout / de partage d'amis(es).
  Widget _menuAmis() {
    final pret = _monCodeAmi.isNotEmpty;
    return PopupMenuButton<String>(
      tooltip: 'Amis(es)',
      iconColor: Colors.white,
      onSelected: (valeur) {
        if (valeur == 'ajouter') {
          _ouvrirAjoutAmi();
        } else if (valeur == 'qr') {
          _afficherQrAmi();
        } else if (valeur == 'copier') {
          _copierCodeAmi();
        } else if (valeur == 'envoyer') {
          _partagerCodeAmi();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'ajouter',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_add_alt_1),
            title: Text('Ajouter un ami(e)'),
          ),
        ),
        PopupMenuItem(
          value: 'qr',
          enabled: pret,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.qr_code_2),
            title: Text('Afficher mon QR ami'),
          ),
        ),
        PopupMenuItem(
          value: 'copier',
          enabled: pret,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy),
            title: Text('Copier mon code ami'),
          ),
        ),
        PopupMenuItem(
          value: 'envoyer',
          enabled: pret,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.share),
            title: Text('Envoyer mon code ami'),
          ),
        ),
      ],
    );
  }

  /// Vue « Amis(es) » : ma carte ami, les demandes, les positions partagées et
  /// la liste des amis(es) avec recherche.
  Widget _vueAmis() {
    if (_chargementAmis) return _squeletteAmis();
    final theme = Theme.of(context);
    final filtres = _amisFiltres;
    final positionnes = _amisPositionnes;
    return RefreshIndicator(
      onRefresh: () => _chargerAmis(silencieux: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          if (_demandes.isNotEmpty) ...[
            TitreSection(
              icone: Icons.person_add_alt_1,
              titre: 'Demandes reçues',
              sousTitre: _demandes.length > 1
                  ? '${_demandes.length} personnes souhaitent t\'ajouter'
                  : '1 personne souhaite t\'ajouter',
            ),
            const SizedBox(height: 10),
            for (final demande in _demandes) ...[
              _carteDemande(demande),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 10),
          ],
          _carteMonCode(theme),
          if (_amis.isNotEmpty) ...[
            const SizedBox(height: 16),
            _barreRechercheAmis(theme),
          ],
          if (positionnes.isNotEmpty) ...[
            const SizedBox(height: 20),
            const TitreSection(
              icone: Icons.location_on,
              titre: 'Qui est où ?',
              sousTitre: 'La position partagée par tes amis(es)',
            ),
            const SizedBox(height: 10),
            _bandePositions(theme, positionnes),
          ],
          const SizedBox(height: 20),
          TitreSection(
            icone: Icons.people_alt,
            titre: 'Mes amis(es)',
            sousTitre: _amis.isEmpty ? null : '${_amis.length} au total',
            trailing: TextButton.icon(
              onPressed: _ouvrirAjoutAmi,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Ajouter'),
            ),
          ),
          const SizedBox(height: 10),
          if (_amis.isEmpty)
            EspaceVideSocial(
              icone: Icons.group_add_outlined,
              titre: 'Ta tribu commence ici',
              message:
                  'Ajoute tes amis(es) pour échanger, partager ta position et '
                  'te prévenir en cas de besoin sur la route.',
              action: FilledButton.icon(
                onPressed: _ouvrirAjoutAmi,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Ajouter un ami(e)'),
              ),
            )
          else if (filtres.isEmpty)
            const EspaceVideSocial(
              icone: Icons.search_off,
              titre: 'Aucun résultat',
              message: 'Aucun ami(e) ne correspond à ta recherche.',
            )
          else
            for (final ami in filtres) _carteAmi(ami),
        ],
      ),
    );
  }

  /// Carte « Mon code ami » bien visible : on la partage d'un geste.
  Widget _carteMonCode(ThemeData theme) {
    final pret = _monCodeAmi.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        gradient: SocialUI.degradeEntete,
        borderRadius: BorderRadius.circular(SocialUI.rayonCarte),
        boxShadow: SocialUI.ombreDouce(teinte: KinColors.primaryFonce, opacite: 0.25),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.qr_code_2, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Mon code ami',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              Icon(Icons.lock_outline,
                  size: 15, color: Colors.white.withValues(alpha: 0.8)),
              const SizedBox(width: 4),
              Text(
                'Privé',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            pret ? _formaterCodeAmi(_monCodeAmi) : '••••-••••',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Fais scanner ce code ou partage-le pour qu\'on t\'ajoute.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _boutonCode(theme, Icons.qr_code_2, 'Afficher', _afficherQrAmi,
                  actif: pret),
              const SizedBox(width: 8),
              _boutonCode(theme, Icons.copy, 'Copier', _copierCodeAmi,
                  actif: pret),
              const SizedBox(width: 8),
              _boutonCode(theme, Icons.ios_share, 'Partager', _partagerCodeAmi,
                  actif: pret),
            ],
          ),
        ],
      ),
    );
  }

  Widget _boutonCode(
    ThemeData theme,
    IconData icone,
    String libelle,
    VoidCallback action, {
    bool actif = true,
  }) {
    return Expanded(
      child: Opacity(
        opacity: actif ? 1 : 0.5,
        child: Material(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: actif ? action : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icone, color: Colors.white, size: 19),
                  const SizedBox(height: 3),
                  Text(
                    libelle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Champ de recherche d'ami(e).
  Widget _barreRechercheAmis(ThemeData theme) {
    return TextField(
      controller: _rechercheAmis,
      onChanged: (_) => setState(() {}),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Rechercher un ami(e)…',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _rechercheAmis.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Effacer',
                onPressed: () {
                  _rechercheAmis.clear();
                  setState(() {});
                },
              ),
        isDense: true,
      ),
    );
  }

  /// Bandeau horizontal « Qui est où ? » : un avatar par ami(e) qui partage sa
  /// position, avec une pastille verte si la position est récente.
  Widget _bandePositions(
    ThemeData theme,
    List<Map<String, dynamic>> positionnes,
  ) {
    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: positionnes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final ami = positionnes[index];
          final recent = _positionRecente(ami);
          return SizedBox(
            width: 76,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _ouvrirDiscussionAmi(ami),
              child: Column(
                children: [
                  Stack(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2.5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: recent
                              ? const LinearGradient(
                                  colors: [
                                    KinColors.vertArrivee,
                                    KinColors.fluideFonce,
                                  ],
                                )
                              : null,
                          color: recent
                              ? null
                              : theme.colorScheme.outlineVariant,
                        ),
                        child: AvatarAnimalWidget(
                          taille: 56,
                          avatarId: ami['avatar'] as String?,
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: PastillePresence(active: recent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _prenomDe(ami),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _agePositionCourt(ami),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Prénom d'un profil (repli : nom complet, puis libellé générique).
  static String _prenomDe(Map<String, dynamic> profil) {
    final prenom = (profil['prenom'] as String? ?? '').trim();
    if (prenom.isNotEmpty) return prenom;
    return _nomComplet(profil);
  }

  /// Âge de la position, très court (« 2 min »).
  String _agePositionCourt(Map<String, dynamic> ami) {
    final brut = ami['maj_a'];
    final majA = brut == null ? null : DateTime.tryParse(brut.toString());
    if (majA == null) return '';
    return tempsRelatif(majA.toLocal());
  }

  /// Affiche un code sous la forme `XXXX-XXXX` (8 caractères).
  String _formaterCodeAmi(String code) {
    final propre = code.trim();
    if (propre.length == 8) {
      return '${propre.substring(0, 4)}-${propre.substring(4)}';
    }
    return propre;
  }

  /// Boîte de dialogue avec le QR code de mon code ami.
  Future<void> _afficherQrAmi() async {
    final code = _monCodeAmi;
    if (code.isEmpty) return;
    Journal.i('SOCIAL', 'Affichage du QR code ami');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mon QR ami'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: code,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              _formaterCodeAmi(code),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Fais scanner ce QR code pour qu\'on t\'ajoute.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  Future<void> _copierCodeAmi() async {
    await Clipboard.setData(ClipboardData(text: _monCodeAmi));
    Journal.i('SOCIAL', 'Code ami copié');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code ami copié.')),
    );
  }

  /// Partager mon code ami : l'utilisateur choisit la messagerie
  /// (WhatsApp, Facebook, Snapchat, Instagram).
  Future<void> _partagerCodeAmi() async {
    final code = _monCodeAmi;
    if (code.isEmpty) return;
    Journal.i('SOCIAL', 'Partage du code ami lancé');
    final texte =
        'Ajoute-moi sur KinFlow avec mon code ami : ${_formaterCodeAmi(code)}';
    final cle = await _choisirPartageExterne(
      texte: texte,
      titre: 'Envoyer mon code ami',
      apercu: _formaterCodeAmi(code),
    );
    if (!mounted || cle == null) return;
    await _appliquerPartageExterne(cle, texte);
  }

  /// Feuille de choix : quel appli utiliser pour partager [texte] hors de
  /// l'app. Renvoie la clé ('whatsapp', 'facebook', 'snapchat',
  /// 'instagram') ou null si fermée.
  Future<String?> _choisirPartageExterne({
    required String texte,
    String? titre,
    String? apercu,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  titre ?? 'Partager',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                if (apercu != null && apercu.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    apercu,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Center(
                  child: _listeAppsPartage(
                    ctx,
                    (cle) => Navigator.pop(ctx, cle),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Les 4 messageries externes proposées pour le partage.
  Widget _listeAppsPartage(
    BuildContext context,
    ValueChanged<String> onChoisi,
  ) {
    final apps = <(IconData, String, String, Color)>[
      (MdiIcons.whatsapp, 'WhatsApp', 'whatsapp', Color(0xFF25D366)),
      (MdiIcons.facebook, 'Facebook', 'facebook', Color(0xFF1877F2)),
      (MdiIcons.snapchat, 'Snapchat', 'snapchat', Color(0xFFFFFC00)),
      (MdiIcons.instagram, 'Instagram', 'instagram', Color(0xFFE1306C)),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        for (final (icone, label, cle, couleur) in apps)
          _carteAppPartage(
            icone: icone,
            label: label,
            couleur: couleur,
            onTap: () => onChoisi(cle),
          ),
      ],
    );
  }

  /// Une carte d'app de messagerie : icône ronde + nom dessous.
  Widget _carteAppPartage({
    required IconData icone,
    required String label,
    required Color couleur,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final iconeClaire = ThemeData.estimateBrightnessForColor(couleur) ==
        Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: couleur,
              child: Icon(
                icone,
                color: iconeClaire ? Colors.white : Colors.black,
                size: 26,
              ),
            ),
            const SizedBox(height: 6),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  /// Tente d'ouvrir [uriBrut] dans une application externe. Retourne true si
  /// une application a accepté le lien.
  Future<bool> _essayerOuvrir(String uriBrut) async {
    try {
      final uri = Uri.parse(uriBrut);
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[KinFlow] Ouverture impossible ($uriBrut): $e');
      return false;
    }
  }

  /// Partage [texte] hors de l'app via la messagerie choisie. On tente
  /// d'abord d'ouvrir directement l'application (schéma natif), puis son site
  /// de partage. En dernier recours : copie dans le presse-papiers.
  ///
  /// [url] : lien de l'information à partager (utile à Facebook).
  Future<void> _appliquerPartageExterne(
    String cle,
    String texte, {
    String? url,
  }) async {
    Journal.i('SOCIAL', 'Partage vers une autre application', {'app': cle});
    final encode = Uri.encodeComponent(texte);
    final urlEncode = Uri.encodeComponent(url ?? '');

    // Snapchat et Instagram n'ont pas de lien de composition : on copie le
    // texte (prêt à coller) puis on ouvre l'application si elle est là.
    if (cle == 'snapchat' || cle == 'instagram') {
      await Clipboard.setData(ClipboardData(text: texte));
      final app = cle == 'snapchat' ? 'Snapchat' : 'Instagram';
      await _essayerOuvrir(cle == 'snapchat' ? 'snapchat://' : 'instagram://app');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Texte copié : colle-le dans $app.')),
      );
      return;
    }

    final candidats = <String>[];
    switch (cle) {
      case 'whatsapp':
        candidats.addAll([
          'whatsapp://send?text=$encode',
          'https://wa.me/?text=$encode',
        ]);
      case 'facebook':
        if (url != null && url.isNotEmpty) {
          candidats.add(
            'https://www.facebook.com/sharer/sharer.php'
            '?u=$urlEncode&quote=$encode',
          );
        }
        candidats.add('fb://');
    }
    for (final brut in candidats) {
      if (await _essayerOuvrir(brut)) return;
    }

    // Aucun lien n'a fonctionné : on copie, prêt à coller dans l'app.
    await Clipboard.setData(ClipboardData(text: texte));
    if (!mounted) return;
    final app = switch (cle) {
      'whatsapp' => 'WhatsApp',
      'facebook' => 'Facebook',
      _ => 'l\'application',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Texte copié. Colle-le dans $app.')),
    );
  }

  /// Ajout d'un ami(e) : propose de scanner un QR code ou de saisir un code
  /// ami à la main, puis envoie la demande.
  Future<void> _ouvrirAjoutAmi() async {
    Journal.i('SOCIAL', 'Ajout d\'un ami(e) : ouverture des options');
    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ajouter un ami(e)',
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'Utilise le code ami (jamais le code de compte).',
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, 'scanner'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scanner un QR code'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(ctx, 'saisir'),
                icon: const Icon(Icons.keyboard),
                label: const Text('Saisir un code ami'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || choix == null) return;
    Journal.i('SOCIAL',
        'Ajout d\'un ami(e) : ${choix == 'scanner' ? 'scan du QR' : 'saisie du code'}');

    String? code;
    if (choix == 'scanner') {
      code = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (context) => const ScanQrAmiScreen()),
      );
    } else {
      code = await _demanderCodeAmi();
    }
    if (!mounted || code == null || code.trim().isEmpty) return;
    await _envoyerDemande(code);
  }

  /// Boîte de dialogue de saisie manuelle d'un code ami.
  Future<String?> _demanderCodeAmi() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Saisir un code ami'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Saisis le code ami de la personne (visible sur son écran '
              'Amis(es), ou dans son QR code).',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Code ami',
                hintText: 'EX : AB12CD34',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (valeur) => Navigator.pop(ctx, valeur),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );
    return code;
  }

  /// Envoie une demande d'ami à partir d'un code ami et affiche le résultat.
  Future<void> _envoyerDemande(String code) async {
    final resultat = await SupabaseService().envoyerDemandeAmi(code.trim());
    if (!mounted) return;
    Journal.i('SOCIAL', 'Demande d\'ami : $resultat', {'code': code.trim()});

    final message = switch (resultat) {
      'envoye' => 'Demande envoyée.',
      'accepte' => 'Vous êtes maintenant amis(es) !',
      'deja_ami' => 'Vous êtes déjà amis(es).',
      'deja_envoye' => 'Demande déjà envoyée, en attente.',
      'introuvable' => 'Aucun profil ne porte ce code ami.',
      'soi_meme' => 'C\'est ton propre code.',
      'code_invalide' => 'Code invalide.',
      'non_connecte' => 'Compte non connecté.',
      _ => 'Envoi impossible. Vérifie ta connexion.',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

    if (resultat == 'envoye' || resultat == 'accepte') {
      await _chargerAmis(silencieux: true);
    }
  }

  Widget _carteDemande(Map<String, dynamic> demande) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: KinColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KinColors.accent.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          AvatarAnimalWidget(
            taille: 48,
            avatarId: demande['avatar'] as String?,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nomComplet(demande),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Souhaite t\'ajouter',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filledTonal(
            onPressed: () => _repondreDemande(demande, false),
            tooltip: 'Refuser',
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: () => _repondreDemande(demande, true),
            style: FilledButton.styleFrom(
              backgroundColor: KinColors.primary,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: const Text('Accepter'),
          ),
        ],
      ),
    );
  }

  Future<void> _repondreDemande(
    Map<String, dynamic> demande,
    bool accepter,
  ) async {
    final id = demande['id']?.toString() ?? '';
    final ok = await SupabaseService().repondreDemandeAmi(id, accepter);
    if (!mounted) return;
    Journal.i(
      'SOCIAL',
      'Demande d\'ami ${accepter ? 'acceptée' : 'refusée'}'
      '${ok ? '' : ' (échec)'}',
      {'ami': _nomComplet(demande)},
    );
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Action non enregistrée. Vérifie ta connexion.'),
        ),
      );
      return;
    }
    await _chargerAmis(silencieux: true);
    // Nouvelle amitié : je dois, moi aussi, dire si j'autorise la localisation
    // simple (l'autre personne a été invitée de son côté).
    if (accepter) {
      final amiId = demande['demandeur']?.toString() ?? '';
      if (amiId.isNotEmpty) {
        await _demanderAutorisationLoc(amiId, _nomComplet(demande));
      }
    }
  }

  /// Pose la question de localisation simple (une seule fois) puis enregistre
  /// le choix.
  Future<void> _demanderAutorisationLoc(String amiId, String nom) async {
    if (await questionLocDejaPosee(amiId)) return;
    await marquerQuestionLocPosee(amiId);
    if (!mounted) return;
    final choix = await demanderAutorisationLocSimple(context, nom);
    if (choix == null) return;
    Journal.i('SOCIAL', 'Autorisation de localisation simple enregistrée',
        {'ami': nom, 'autorise': choix});
    await SupabaseService().definirAutorisationLocSimple(amiId, choix);
  }

  Widget _carteAmi(Map<String, dynamic> ami) {
    final theme = Theme.of(context);
    final nonLus = _nonLus[ami['ami_id']] ?? 0;
    final apercu = _apercuMessageAmi(ami);
    final positionLine = _libellePositionAmi(ami);
    final recent = _positionRecente(ami);
    final sousTitre = apercu.isNotEmpty ? apercu : positionLine;
    final texteSousTitre =
        sousTitre.isEmpty ? 'Démarrer la discussion' : sousTitre;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        boxShadow: SocialUI.ombreDouce(opacite: 0.04),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _ouvrirDiscussionAmi(ami),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Stack(
                  children: [
                    AvatarAnimalWidget(
                      taille: 52,
                      avatarId: ami['avatar'] as String?,
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: PastillePresence(active: recent),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _nomComplet(ami),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        texteSousTitre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              nonLus > 0 ? FontWeight.w600 : FontWeight.w400,
                          color: nonLus > 0
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (nonLus > 0)
                  Container(
                    constraints: const BoxConstraints(minWidth: 26),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: KinColors.vertArrivee,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      nonLus > 99 ? '99+' : '$nonLus',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                else
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 19,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.7),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Le dernier message de la discussion (fenêtre 7 jours), préfixé de
  /// « Vous : » si c'est moi qui l'ai envoyé. Vide si aucun message.
  String _apercuMessageAmi(Map<String, dynamic> ami) {
    final apercu = _apercus[ami['ami_id']];
    if (apercu == null) return '';
    final contenu = (apercu['contenu'] as String? ?? '').trim();
    if (contenu.isEmpty) return '';
    return apercu['moi'] == true ? 'Vous : $contenu' : contenu;
  }

  /// Ouvre directement la discussion avec l'ami(e). Les actions (localiser,
  /// tracer l'itinéraire, retirer) sont regroupées dans le menu ⋮ de l'écran
  /// de discussion.
  Future<void> _ouvrirDiscussionAmi(Map<String, dynamic> ami) async {
    Journal.i('SOCIAL', 'Discussion ouverte', {'ami': _nomComplet(ami)});
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatAmiScreen(
          amiId: ami['ami_id'] as String? ?? '',
          nom: _nomComplet(ami),
          avatar: ami['avatar'] as String?,
          position: AmiPosition.depuisJson(ami),
          onAmiSupprime: () {
            if (mounted) _chargerAmis(silencieux: true);
          },
          onInfoTaggee: _allerVersInformation,
        ),
      ),
    );
    // Au retour : les messages ont été lus, on rafraîchit le compteur de
    // non-lus (le point rouge de l'onglet « Amis(es) » peut disparaître).
    Journal.i('SOCIAL', 'Discussion fermée', {'ami': _nomComplet(ami)});
    if (mounted) await _chargerAmis(silencieux: true);
  }

  /// « Position partagée · il y a 2 min » ou « Position non partagée ».
  String _libellePositionAmi(Map<String, dynamic> ami) {
    final latitude = _doubleOuNull(ami['latitude']);
    final longitude = _doubleOuNull(ami['longitude']);
    if (latitude == null || longitude == null) return 'Position non partagée';
    final brut = ami['maj_a'];
    final majA = brut == null ? null : DateTime.tryParse(brut.toString());
    if (majA == null) return 'Position partagée';
    return 'Position partagée · ${tempsRelatif(majA.toLocal())}';
  }


  /// Prénom + nom, ou un libellé de repli si le profil est vide.
  static String _nomComplet(Map<String, dynamic> profil) {
    final prenom = (profil['prenom'] as String? ?? '').trim();
    final nom = (profil['nom'] as String? ?? '').trim();
    final complet = [prenom, nom].where((s) => s.isNotEmpty).join(' ');
    return complet.isEmpty ? 'Un utilisateur' : complet;
  }

  static double? _doubleOuNull(Object? valeur) {
    if (valeur == null) return null;
    if (valeur is num) return valeur.toDouble();
    return double.tryParse(valeur.toString());
  }
  /// Vert : pose une réaction VERT, ou l'enlève si déjà posée.
  /// Rouge idem avec ROUGE. Changer de couleur remplace la réaction.
  Future<void> _reagir(InformationVille info, String sens) async {
    final avant = info.maReaction;
    final retrait = avant == sens; // retaper la même couleur = retrait
    final attendu = retrait ? null : sens;
    Journal.i(
      'SOCIAL',
      retrait
          ? 'Réaction retirée (${sens == 'VERT' ? 'vert' : 'rouge'})'
          : 'Réaction posée (${sens == 'VERT' ? 'vert' : 'rouge'})',
      {'info': info.id},
    );

    // Mise à jour optimiste : l'interface réagit immédiatement.
    setState(() {
      final index = _informations.indexWhere((i) => i.id == info.id);
      if (index == -1) return;
      final i = _informations[index];
      var (verts, rouges) = _retirerCompteur(i.nbVerts, i.nbRouges, avant);
      if (!retrait) {
        final r = _ajouterCompteur(verts, rouges, sens);
        verts = r.$1;
        rouges = r.$2;
      }
      _informations[index] = InformationVille(
        id: i.id,
        contenu: i.contenu,
        sourceUrl: i.sourceUrl,
        latitude: i.latitude,
        longitude: i.longitude,
        nbVerts: verts,
        nbRouges: rouges,
        maReaction: attendu,
        emojis: i.emojis,
        mesEmojis: i.mesEmojis,
        creeA: i.creeA,
      );
    });

    final resultat = await SupabaseService().reagirInformation(info.id, sens);
    if (!mounted) return;

    // Le serveur contredit l'attendu (échec réseau/refus) : on remet
    // l'état d'origine. Sinon l'optimiste était juste, on ne touche à rien.
    if ((resultat == null) != retrait) {
      setState(() {
        final index = _informations.indexWhere((i) => i.id == info.id);
        if (index != -1) _informations[index] = info;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Réaction non enregistrée. Vérifie ta connexion.'),
        ),
      );
      Journal.a('SOCIAL', 'Réaction non enregistrée (réseau)',
          {'info': info.id});
    }
  }

  static (int, int) _retirerCompteur(
    int verts,
    int rouges,
    String? reaction,
  ) {
    if (reaction == 'VERT') verts = verts > 0 ? verts - 1 : 0;
    if (reaction == 'ROUGE') rouges = rouges > 0 ? rouges - 1 : 0;
    return (verts, rouges);
  }

  static (int, int) _ajouterCompteur(int verts, int rouges, String reaction) {
    if (reaction == 'VERT') verts++;
    if (reaction == 'ROUGE') rouges++;
    return (verts, rouges);
  }

  /// Onglet personnalisé : icône + libellé, et un petit point rouge (pastille
  /// blanche translucide) quand il y a du nouveau. Pensé pour être lisible sur
  /// le fond dégradé de l'en-tête.
  Widget _onglet({required IconData icone, required String texte, required bool aUnPoint}) {
    return Tab(
      height: 50,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icone, size: 19),
          const SizedBox(width: 8),
          Text(
            texte,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          if (aUnPoint) ...[
            const SizedBox(width: 7),
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: Color(0xFFFF5252),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// En-tête dégradé : salutation personnalisée, actions rapides, statistiques
  /// vivantes et les deux onglets.
  Widget _entete(BuildContext context) {
    final haut = MediaQuery.paddingOf(context).top;
    return Container(
      decoration: const BoxDecoration(
        gradient: SocialUI.degradeEntete,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Color(0x33075238),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: EdgeInsets.only(top: haut),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _prenom.isEmpty
                            ? 'KinFlow Social'
                            : 'Bonjour $_prenom 👋',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Ta ville en direct, tes amis(es) à portée de main',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.88),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _ouvrirAjoutAmi,
                  tooltip: 'Ajouter un ami(e)',
                  icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
                ),
                _menuAmis(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                PastilleStat(
                  icone: Icons.bolt,
                  valeur: '$_nombreNouvelles',
                  libelle: _nombreNouvelles > 1 ? 'nouvelles' : 'nouvelle',
                ),
                PastilleStat(
                  icone: Icons.people_alt,
                  valeur: '${_amis.length}',
                  libelle: _amis.length > 1 ? 'amis(es)' : 'ami(e)',
                ),
                PastilleStat(
                  icone: Icons.chat_bubble,
                  valeur: '$_totalNonLus',
                  libelle: _totalNonLus > 1 ? 'messages' : 'message',
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabController,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white.withValues(alpha: 0.72),
            tabs: [
              _onglet(
                icone: Icons.dynamic_feed,
                texte: 'Fil d\'actu',
                aUnPoint: _aDesNouvellesInfos,
              ),
              _onglet(
                icone: Icons.forum,
                texte: 'Amis(es)',
                aUnPoint: _aDesMessagesNonLus || _demandes.isNotEmpty,
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      // L'en-tête est placé dans le corps (et non dans l'AppBar) : il prend
      // exactement la hauteur de son contenu, donc aucun risque de débordement
      // même avec une police agrandie.
      body: Column(
        children: [
          _entete(context),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _vueInformation(),
                _vueAmis(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Vue « Fil d'actu » : les publications KinFlow, filtrables.
  Widget _vueInformation() {
    if (_chargement) return _squeletteFil();
    final fil = _filFiltre;
    return Column(
      children: [
        _barreFiltres(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _chargerFil,
            child: fil.isEmpty
                ? ListView(
                    controller: _defilementInfos,
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(height: MediaQuery.sizeOf(context).height * 0.08),
                      EspaceVideSocial(
                        icone: _informations.isEmpty
                            ? Icons.campaign_outlined
                            : Icons.filter_alt_off_outlined,
                        titre: _informations.isEmpty
                            ? 'Rien à signaler… pour l\'instant'
                            : 'Aucune info dans ce filtre',
                        message: _informations.isEmpty
                            ? 'KinFlow te tiendra au courant dès qu\'il y a du neuf à Kinshasa.'
                            : 'Choisis « Tout » pour revoir toutes les informations.',
                        action: _informations.isEmpty
                            ? null
                            : OutlinedButton.icon(
                                onPressed: () =>
                                    setState(() => _filtre = 'tout'),
                                icon: const Icon(Icons.restart_alt, size: 18),
                                label: const Text('Voir tout'),
                              ),
                      ),
                    ],
                  )
                : ListView.separated(
                    controller: _defilementInfos,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                    itemCount: fil.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final info = fil[index];
                      return Container(
                        key: _cleInfo(info.id),
                        child: _carteInformation(info),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// Barre de filtres du fil : des puces claires, défilables horizontalement.
  Widget _barreFiltres() {
    const filtres = <(String, String, IconData)>[
      ('tout', 'Tout', Icons.apps),
      ('neuf', 'Nouveau', Icons.bolt),
      ('confirme', 'Confirmé', Icons.verified_outlined),
      ('verifier', 'À vérifier', Icons.report_gmailerrorred_outlined),
      ('populaire', 'Populaire', Icons.local_fire_department),
      ('epingle', 'Épinglé', Icons.push_pin),
    ];
    final theme = Theme.of(context);
    return SizedBox(
      height: 50,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        itemCount: filtres.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (cle, libelle, icone) = filtres[index];
          final actif = _filtre == cle;
          return ChoiceChip(
            selected: actif,
            onSelected: (_) {
              HapticFeedback.selectionClick();
              setState(() => _filtre = cle);
            },
            avatar: Icon(
              icone,
              size: 17,
              color: actif ? Colors.white : theme.colorScheme.onSurfaceVariant,
            ),
            label: Text(libelle),
            labelStyle: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: actif ? Colors.white : theme.colorScheme.onSurface,
            ),
            showCheckmark: false,
            selectedColor: KinColors.primary,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(
                color: actif
                    ? KinColors.primary
                    : theme.colorScheme.outlineVariant,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Squelette animé affiché pendant le premier chargement du fil.
  Widget _squeletteFil() {
    return Scintillement(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, _) => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(SocialUI.rayonCarte),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  BlocSquelette(largeur: 40, hauteur: 40, rayon: 14),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        BlocSquelette(largeur: 90, hauteur: 12),
                        SizedBox(height: 8),
                        BlocSquelette(largeur: 60, hauteur: 10),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 16),
              BlocSquelette(hauteur: 12),
              SizedBox(height: 8),
              BlocSquelette(hauteur: 12),
              SizedBox(height: 8),
              BlocSquelette(largeur: 180, hauteur: 12),
              SizedBox(height: 16),
              BlocSquelette(hauteur: 36, rayon: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// Squelette animé pendant le chargement de la liste d'amis(es).
  Widget _squeletteAmis() {
    return Scintillement(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: 6,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, _) => Row(
          children: [
            const BlocSquelette(largeur: 52, hauteur: 52, forme: BoxShape.circle),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  BlocSquelette(largeur: 140, hauteur: 13),
                  SizedBox(height: 8),
                  BlocSquelette(largeur: 200, hauteur: 11),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Renvoie vers l'information taguée : bascule sur l'onglet « Information »,
  /// la met en évidence et défile jusqu'à elle.
  Future<void> _allerVersInformation(String infoId) async {
    if (!mounted) return;
    Journal.i('SOCIAL', 'Retour vers une information taguée',
        {'info': infoId});
    setState(() => _infoEnEvidence = infoId);
    _tabController.index = 0;
    // Laisse l'onglet et la liste se construire avant de défiler.
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    if (_defilementInfos.hasClients) _defilementInfos.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rechercherInfo(infoId, 0);
    });
    // La mise en évidence s'estompe après quelques secondes.
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _infoEnEvidence == infoId) {
        setState(() => _infoEnEvidence = null);
      }
    });
  }

  /// Défile progressivement jusqu'à ce que la carte [infoId] soit construite,
  /// puis la centre à l'écran.
  void _rechercherInfo(String infoId, int essais) {
    if (!mounted) return;
    final ctx = _clesInfos[infoId]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.15,
      );
      return;
    }
    if (essais > 50 || !_defilementInfos.hasClients) return;
    final pos = _defilementInfos.position;
    if (pos.pixels >= pos.maxScrollExtent) return; // fin atteinte
    final cible = (pos.pixels + pos.viewportDimension)
        .clamp(0.0, pos.maxScrollExtent);
    _defilementInfos.jumpTo(cible);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _rechercherInfo(infoId, essais + 1),
    );
  }

  Widget _carteInformation(InformationVille info) {
    final theme = Theme.of(context);
    final enEvidence = _infoEnEvidence == info.id;
    final nouvelle = _estNouvelle(info);
    final carte = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: enEvidence
            ? KinColors.accent.withValues(alpha: 0.12)
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(SocialUI.rayonCarte),
        border: Border.all(
          color: enEvidence
              ? KinColors.accent
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: enEvidence ? 2 : 1,
        ),
        boxShadow: SocialUI.ombreDouce(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: SocialUI.degradeEntete,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.campaign, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Flexible(
                            child: Text(
                              'KinFlow',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.verified,
                            size: 15,
                            color: KinColors.bleu,
                          ),
                        ],
                      ),
                      Text(
                        _tempsRelatifCourt(info.creeA),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (nouvelle)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      gradient: SocialUI.degradeAccent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Nouveau',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                else if (info.epinglee)
                  const Tooltip(
                    message: 'Information épinglée',
                    child: Icon(Icons.push_pin, size: 18, color: Colors.amber),
                  ),
                _menuInfo(info),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (info.imageUrl != null &&
                    info.imageUrl!.trim().isNotEmpty) ...[
                  _imageInformation(info.imageUrl!.trim()),
                  const SizedBox(height: 12),
                ],
                Text(
                  info.contenu,
                  style: const TextStyle(fontSize: 15.5, height: 1.4),
                ),
                if (info.sourceUrl != null &&
                    info.sourceUrl!.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _lignePlusInfo(info.sourceUrl!),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _boutonReaction(
                      info: info,
                      sens: 'VERT',
                      icon: Icons.thumb_up_alt,
                      couleur: Colors.green.shade700,
                      couleurFondee: KinColors.vertArrivee,
                    ),
                    const SizedBox(width: 8),
                    _boutonReaction(
                      info: info,
                      sens: 'ROUGE',
                      icon: Icons.thumb_down_alt,
                      couleur: Colors.red.shade700,
                      couleurFondee: KinColors.grosEmbouteillages,
                    ),
                    const SizedBox(width: 4),
                    _actionInfo(
                      icone: Icons.ios_share,
                      libelle: 'Partager',
                      onTap: () => _proposerEnvoiInfo(info),
                    ),
                    _actionInfo(
                      icone: Icons.alternate_email,
                      libelle: 'Taguer un ami',
                      onTap: () => _choisirAmiATaguer(info),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _barreProportion(info),
                const SizedBox(height: 12),
                _boutonsEmojis(info),
              ],
            ),
          ),
        ],
      ),
    );
    return GestureDetector(
      onLongPress: () => _proposerEnvoiInfo(info),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        builder: (context, t, enfant) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 14),
            child: enfant,
          ),
        ),
        child: carte,
      ),
    );
  }

  /// Bouton d'action compact (icône seule) affiché à droite des réactions.
  Widget _actionInfo({
    required IconData icone,
    required String libelle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Tooltip(
      message: libelle,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icone,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Menu ⋮ d'une information (partager / taguer), pour rendre ces actions
  /// plus visibles que l'appui long seul.
  Widget _menuInfo(InformationVille info) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_horiz,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      tooltip: 'Plus d\'options',
      onSelected: (valeur) {
        if (valeur == 'partager') {
          _proposerEnvoiInfo(info);
        } else if (valeur == 'taguer') {
          _choisirAmiATaguer(info);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'partager',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.ios_share, size: 20),
            title: Text('Partager'),
          ),
        ),
        PopupMenuItem(
          value: 'taguer',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.alternate_email, size: 20),
            title: Text('Taguer un ami(e)'),
          ),
        ),
      ],
    );
  }

  /// Image d'une information (article d'origine), affichée au-dessus du texte.
  Widget _imageInformation(String url) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, progression) {
            if (progression == null) return child;
            return ColoredBox(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
          errorBuilder: (_, _, _) => ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.image_not_supported_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// Appui long sur une information : proposer de la partager (« taguer un
  /// ami » dans KinFlow, ou sur une autre app).
  Future<void> _proposerEnvoiInfo(InformationVille info) async {
    Journal.i('SOCIAL', 'Appui long : partage d\'une information proposé',
        {'info': info.id});
    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Partager cette information',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  info.contenu.trim(),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    child: Icon(Icons.alternate_email, size: 20),
                  ),
                  title: const Text('Taguer un ami'),
                  subtitle: const Text(
                    'Envoyer dans une discussion KinFlow',
                  ),
                  onTap: () => Navigator.pop(ctx, 'taguer'),
                ),
                const Divider(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Sur une autre app',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: _listeAppsPartage(
                    ctx,
                    (cle) => Navigator.pop(ctx, cle),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || choix == null) return;
    if (choix == 'taguer') {
      await _choisirAmiATaguer(info);
      return;
    }
    await _appliquerPartageExterne(choix, _texteInfo(info), url: info.sourceUrl);
  }

  /// Texte partageable d'une information KinFlow (contenu + lien éventuel).
  String _texteInfo(InformationVille info) {
    final buffer = StringBuffer('Info KinFlow :\n');
    buffer.write(info.contenu.trim());
    final url = info.sourceUrl?.trim();
    if (url != null && url.isNotEmpty) {
      buffer.write('\n$url');
    }
    return buffer.toString();
  }

  /// Choisit l'ami(e) à taguer sur l'information.
  Future<void> _choisirAmiATaguer(InformationVille info) async {
    if (_amis.isEmpty) {
      Journal.a('SOCIAL', 'Tag impossible : aucun ami(e) dans la liste');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ajoute d\'abord des amis(es) pour les taguer.'),
        ),
      );
      return;
    }
    Journal.i('SOCIAL', 'Choix de l\'ami(e) à taguer', {'info': info.id});
    final ami = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Taguer un ami',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final a in _amis)
                      ListTile(
                        leading: AvatarAnimalWidget(
                          taille: 44,
                          avatarId: a['avatar'] as String?,
                        ),
                        title: Text(_nomComplet(a)),
                        subtitle: Text(_libellePositionAmi(a)),
                        trailing: const Icon(Icons.alternate_email, size: 18),
                        onTap: () => Navigator.pop(ctx, a),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
    if (!mounted || ami == null) return;
    await _taguerAmi(info, ami);
  }

  /// Tague l'information sur un(e) ami(e) : crée un message système dans la
  /// discussion, pointant vers l'information (ouvrable d'un toucher).
  Future<void> _taguerAmi(
    InformationVille info,
    Map<String, dynamic> ami,
  ) async {
    final amiId = ami['ami_id'] as String?;
    if (amiId == null) return;
    final resultat = await SupabaseService().taguerInformationAmi(
      amiId: amiId,
      infoId: info.id,
    );
    if (!mounted) return;
    final nom = _nomComplet(ami);
    Journal.i('SOCIAL', 'Tag d\'une information à un ami(e) : $resultat', {
      'info': info.id,
      'ami': nom,
    });
    if (resultat != 'envoye') {
      final message = switch (resultat) {
        'pas_ami' => 'Vous n\'êtes plus amis(es).',
        'info_introuvable' => 'Information indisponible.',
        _ => 'Tag impossible. Vérifie ta connexion.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Information taguée à $nom.')),
    );
  }

  Widget _boutonReaction({
    required InformationVille info,
    required String sens,
    required IconData icon,
    required Color couleur,
    required Color couleurFondee,
  }) {
    final actif = info.maReaction == sens;
    final compteur = sens == 'VERT' ? info.nbVerts : info.nbRouges;
    return Expanded(
      child: Material(
        color: actif
            ? couleurFondee.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            HapticFeedback.selectionClick();
            _reagir(info, sens);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: actif
                    ? couleurFondee.withValues(alpha: 0.6)
                    : Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: actif ? couleurFondee : couleur,
                ),
                const SizedBox(width: 6),
                Text(
                  '$compteur',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: actif ? couleurFondee : couleur,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Juste sous le message de l'information : la phrase « Plus de détails »
  /// à gauche, puis le lien (URL raccourcie) à sa droite — sans couleur
  /// propre, il reprend la couleur de la fenêtre. Appuyer sur le lien ouvre
  /// l'article d'origine.
  Widget _lignePlusInfo(String url) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          'Plus de détails',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: _boutonLien(url)),
      ],
    );
  }

  /// Lien cliquable sans couleur propre : le fond reste transparent (il
  /// reprend la couleur de la fenêtre, aucun dégradé). Seuls les caractères
  /// changent de couleur : les 13 premiers sont en bleu (`KinColors.bleu`),
  /// puis les suivants en vert (`KinColors.vertArrivee`) — y compris les
  /// pointillés « … » — pour montrer à l'utilisateur que le lien continue
  /// (la partie invisible, au-delà des 25 caractères, est elle aussi
  /// « verte »). L'URL n'affiche que ses 25 premiers caractères suivis de
  /// « … » pour ne pas s'étendre (esthétique).
  Widget _boutonLien(String url) {
    const int maxCaracteres = 25;
    const int bleuCaracteres = 13;
    final affichage = url.length > maxCaracteres
        ? '${url.substring(0, maxCaracteres)}…'
        : url;
    final tailleBleue =
        bleuCaracteres < affichage.length ? bleuCaracteres : affichage.length;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _ouvrirLien(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.public, size: 15, color: KinColors.bleu),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    children: [
                      TextSpan(
                        text: affichage.substring(0, tailleBleue),
                        style: const TextStyle(color: KinColors.bleu),
                      ),
                      TextSpan(
                        text: affichage.substring(tailleBleue),
                        style: const TextStyle(color: KinColors.vertArrivee),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.open_in_new, size: 14, color: KinColors.bleu),
            ],
          ),
        ),
      ),
    );
  }

  /// Ouvre l'article d'origine dans le navigateur du téléphone.
  Future<void> _ouvrirLien(String url) async {
    var uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      uri = Uri.parse('https://${url.trim()}');
    }
    Journal.i('SOCIAL', 'Ouverture de l\'article d\'origine', {'url': url.trim()});
    final ouvert = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ouvert && mounted) {
      Journal.a('SOCIAL', 'Impossible d\'ouvrir le lien', {'url': url.trim()});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'ouvrir le lien.')),
      );
    }
  }

  /// Barre de proportion VERT/ROUGE : plus l'info est confirmée, plus la
  /// barre est verte. Apparaît dès qu'il y a au moins une réaction.
  Widget _barreProportion(InformationVille info) {
    final total = info.nbVerts + info.nbRouges;
    if (total <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        width: double.infinity,
        child: Row(
          children: [
            Expanded(
              flex: info.nbVerts,
              child: ColoredBox(color: Colors.green.shade600),
            ),
            Expanded(
              flex: info.nbRouges,
              child: ColoredBox(color: Colors.red.shade600),
            ),
          ],
        ),
      ),
    );
  }

  /// Les émojis à afficher sous le post : les plus populaires d'abord
  /// (3-4 maximum), puis les émojis du visiteur s'ils ne sont pas déjà là.
  List<(String, int)> _emojisAffiches(InformationVille info) {
    final affiches = <(String, int)>[];
    for (final e in info.emojis) {
      affiches.add(e);
      if (affiches.length >= 4) break;
    }
    for (final monEmoji in info.mesEmojis) {
      if (!affiches.any((a) => a.$1 == monEmoji)) {
        final compte =
            info.emojis.where((x) => x.$1 == monEmoji).map((x) => x.$2);
        affiches.add((monEmoji, compte.isEmpty ? 0 : compte.first));
      }
      if (affiches.length >= 5) break;
    }
    return affiches;
  }

  Widget _boutonsEmojis(InformationVille info) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (emoji, compte) in _emojisAffiches(info))
          _boutonEmoji(info: info, emoji: emoji, compte: compte),
        // Le bouton « Émoji » disparaît dès qu'on a déjà posé le sien :
        // pour le changer (ou le retirer), on appuie sur son émoji.
        if (info.mesEmojis.isEmpty) _boutonAjouterEmoji(info),
      ],
    );
  }

  Widget _boutonEmoji({
    required InformationVille info,
    required String emoji,
    required int compte,
  }) {
    final theme = Theme.of(context);
    final actif = info.mesEmojis.contains(emoji);
    return Material(
      color: actif ? Colors.amber.withValues(alpha: 0.18) : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        // Son propre émoji → la liste réapparaît pour le changer (ou le
        // retirer). Un émoji des autres → on réagit avec, tout simplement.
        onTap: () => actif
            ? _ouvrirPaletteEmojis(info)
            : _reagirEmoji(info, emoji),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: actif
                  ? Colors.amber.shade600
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Text(
                '$compte',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _boutonAjouterEmoji(InformationVille info) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _ouvrirPaletteEmojis(info),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_reaction_outlined, size: 16),
              SizedBox(width: 4),
              Text('Émoji', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _ouvrirPaletteEmojis(InformationVille info) async {
    final aUnEmoji = info.mesEmojis.isNotEmpty;
    final choisi = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        // Hauteur plafonnée : la palette défile si elle ne tient pas.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  aUnEmoji ? 'Changer (ou retirer) ton émoji' : 'Choisis ton émoji',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final e in _paletteEmojis)
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => Navigator.pop(context, e),
                        child: Text(
                          e,
                          style: const TextStyle(fontSize: 26),
                        ),
                      ),
                  ],
                ),
                if (aUnEmoji) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () =>
                        Navigator.pop(context, _retirerEmoji),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Retirer mon émoji'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (choisi == null || !mounted) return;
    if (choisi == _retirerEmoji) {
      // Retirer : on renvoie son propre émoji à la bascule (retaper le même
      // émoji le retire, côté app comme côté serveur).
      if (info.mesEmojis.isNotEmpty) {
        await _reagirEmoji(info, info.mesEmojis.first);
      }
      return;
    }
    await _reagirEmoji(info, choisi);
  }

  /// Ajoute, remplace ou retire l'émoji du visiteur (bascule optimiste, comme
  /// les pouces). Un seul émoji par personne : en poser un autre remplace le
  /// précédent, retaper le même le retire.
  Future<void> _reagirEmoji(InformationVille info, String emoji) async {
    final retrait = info.mesEmojis.contains(emoji);
    Journal.i(
      'SOCIAL',
      retrait ? 'Émoji retiré' : 'Émoji posé ($emoji)',
      {'info': info.id},
    );
    setState(() {
      final index = _informations.indexWhere((i) => i.id == info.id);
      if (index == -1) return;
      final i = _informations[index];
      final (emojis, mesEmojis) = InformationVille.appliquerEmoji(
        i.emojis,
        i.mesEmojis,
        emoji,
      );
      _informations[index] = InformationVille(
        id: i.id,
        contenu: i.contenu,
        sourceUrl: i.sourceUrl,
        latitude: i.latitude,
        longitude: i.longitude,
        nbVerts: i.nbVerts,
        nbRouges: i.nbRouges,
        maReaction: i.maReaction,
        emojis: emojis,
        mesEmojis: mesEmojis,
        creeA: i.creeA,
      );
    });

    final resultat = await SupabaseService().reagirEmoji(info.id, emoji);
    if (!mounted) return;
    if (resultat == null) {
      setState(() {
        final index = _informations.indexWhere((i) => i.id == info.id);
        if (index != -1) _informations[index] = info;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Émoji non enregistré. Vérifie ta connexion.'),
        ),
      );
      Journal.a('SOCIAL', 'Émoji non enregistré (réseau)', {'info': info.id});
    }
  }

  /// Transforme une date en libellé relatif français (infos < 7j). Pour les
  /// positions d'amis (plus anciennes), on utilise `tempsRelatif` commun.
  static String _tempsRelatifCourt(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return "à l'instant";
    if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
    if (diff.inDays < 7) return 'il y a ${diff.inDays} j';
    final j = t.day.toString().padLeft(2, '0');
    final m = t.month.toString().padLeft(2, '0');
    return '$j/$m/${t.year}';
  }
}