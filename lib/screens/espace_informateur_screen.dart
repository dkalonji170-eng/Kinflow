import 'package:flutter/material.dart';

import '../models/publication.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';
import '../widgets/actions_ami.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/carte_publication.dart';
import '../widgets/social_ui.dart';
import 'publication_screen.dart';
import 'publier_publication_screen.dart';

/// L'espace d'un informateur, ouvert par son lien (jeton).
///
/// Rien n'est public : cet écran n'affiche que ce que le jeton autorise. Si le
/// lien a été révoqué ou mal recopié, on le dit clairement au lieu de montrer
/// une page vide.
class EspaceInformateurScreen extends StatefulWidget {
  const EspaceInformateurScreen({super.key, required this.jeton});

  /// Jeton extrait du lien (ou code collé par l'utilisateur).
  final String jeton;

  @override
  State<EspaceInformateurScreen> createState() =>
      _EspaceInformateurScreenState();
}

class _EspaceInformateurScreenState extends State<EspaceInformateurScreen> {
  final SupabaseService _service = SupabaseService();

  bool _chargement = true;
  Map<String, dynamic>? _espace;
  List<Publication> _publications = const [];
  bool _jeSuis = false;
  bool _basculeEnCours = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final espace = await _service.espaceParJeton(widget.jeton);
    if (espace != null) {
      // Ouvrir l'espace vaut abonnement : nécessaire pour lire les photos
      // privées du bucket.
      await _service.suivreEspace(widget.jeton);
    }
    final publications = espace == null
        ? const <Publication>[]
        : await _service.publicationsEspace(widget.jeton);
    if (!mounted) return;
    setState(() {
      _espace = espace;
      _publications = publications;
      _jeSuis = espace?['je_suis'] == true;
      _chargement = false;
    });
  }

  String get _nom {
    final brut = (_espace?['pseudo'] ?? '').toString().trim();
    return brut.isEmpty ? 'Informateur KinFlow' : brut;
  }

  String get _bio => (_espace?['bio'] ?? '').toString().trim();

  String? get _avatar {
    final brut = (_espace?['avatar'] as String?)?.trim();
    return (brut == null || brut.isEmpty) ? null : brut;
  }

  String? get _informateurId {
    final brut = (_espace?['informateur'] ?? '').toString().trim();
    return brut.isEmpty ? null : brut;
  }

  bool get _jePeuxPublier => _espace?['je_peux_publier'] == true;

  bool get _estMonEspace => _espace?['mon_role'] == 'proprietaire';

  int get _nbAbonnes => (_espace?['nb_abonnes'] as num?)?.toInt() ?? 0;

  Future<void> _basculerSuivi() async {
    if (_basculeEnCours) return;
    final nouveau = !_jeSuis;
    setState(() => _basculeEnCours = true);
    final resultat = await _service.basculerSuiviEspace(widget.jeton, nouveau);
    if (!mounted) return;
    if (resultat == null) {
      setState(() => _basculeEnCours = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Suivi non enregistré. Réessaie.')),
      );
      return;
    }
    setState(() {
      _jeSuis = resultat;
      _basculeEnCours = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          resultat
              ? 'Espace suivi : retrouve-le dans « Suivis ».'
              : 'Tu ne suis plus cet espace.',
        ),
      ),
    );
  }

  Future<void> _signaler() async {
    final id = _informateurId;
    if (id == null) return;
    await signalerUtilisateur(context, userId: id);
  }

  Future<void> _publier() async {
    final dossier = _informateurId;
    if (dossier == null || !_jePeuxPublier) return;
    final cree = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PublierPublicationScreen(jeton: widget.jeton, dossier: dossier),
      ),
    );
    if (cree == true) {
      await _charger();
    }
  }

  Future<void> _ouvrir(Publication publication) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PublicationScreen(publication: publication, onModifiee: _remplacer),
      ),
    );
  }

  void _remplacer(Publication publication) {
    if (!mounted) return;
    setState(() {
      _publications = _publications
          .map((p) => p.id == publication.id ? publication : p)
          .toList(growable: false);
    });
  }

  Future<void> _liker(Publication publication) async {
    final nouvelEtat = await _service.likerPublication(publication.id);
    if (!mounted || nouvelEtat == null) return;
    _remplacer(
      publication.copyWith(
        jaiLike: nouvelEtat,
        nbLikes: publication.nbLikes + (nouvelEtat ? 1 : -1),
      ),
    );
  }

  Future<void> _supprimer(Publication publication) async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce reportage ?'),
        content: Text('« ${publication.titre} » sera définitivement retiré.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirme != true) return;
    final ok = await _service.supprimerPublication(publication.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Suppression impossible.')));
      return;
    }
    setState(() {
      _publications = _publications
          .where((p) => p.id != publication.id)
          .toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_chargement ? 'Espace informateur' : _nom),
        actions: [
          if (!_chargement && _espace != null && !_estMonEspace)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _boutonSuivre(),
            ),
          if (!_chargement && _informateurId != null)
            PopupMenuButton<String>(
              tooltip: 'Plus d\'options',
              onSelected: (valeur) {
                if (valeur == 'signaler') _signaler();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'signaler',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.flag_outlined),
                    title: Text('Signaler'),
                  ),
                ),
              ],
            ),
        ],
      ),
      floatingActionButton: !_chargement && _jePeuxPublier
          ? FloatingActionButton.extended(
              onPressed: _publier,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Publier'),
            )
          : null,
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : _espace == null
          ? _lienInvalide()
          : RefreshIndicator(
              onRefresh: _charger,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  _entete(),
                  const SizedBox(height: 18),
                  if (_publications.isEmpty)
                    _espaceVide()
                  else
                    for (final p in _publications)
                      CartePublication(
                        publication: p,
                        onAppui: () => _ouvrir(p),
                        onLike: () => _liker(p),
                        onCommentaires: () => _ouvrir(p),
                        onSupprimer: p.jePeuxSupprimer
                            ? () => _supprimer(p)
                            : null,
                      ),
                ],
              ),
            ),
    );
  }

  /// Bouton « Suivre » / « Suivi » de la barre du haut.
  Widget _boutonSuivre() {
    final theme = Theme.of(context);
    if (_basculeEnCours) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return TextButton.icon(
      onPressed: _basculerSuivi,
      icon: Icon(
        _jeSuis ? Icons.check : Icons.add,
        size: 18,
        color: _jeSuis ? theme.colorScheme.primary : null,
      ),
      label: Text(
        _jeSuis ? 'Suivi' : 'Suivre',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: _jeSuis ? theme.colorScheme.primary : null,
        ),
      ),
    );
  }

  Widget _entete() {
    final role = (_espace?['mon_role'] ?? 'lecteur').toString();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [KinColors.primary, KinColors.primaryClair],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarAnimalWidget(taille: 60, avatarId: _avatar),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _nom,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      role == 'proprietaire'
                          ? 'Mon espace informateur'
                          : role == 'membre'
                          ? 'Membre de cet espace'
                          : 'Espace informateur privé',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_bio.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _bio,
              style: const TextStyle(color: Colors.white, height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _stat('${_publications.length}', 'reportages'),
              const SizedBox(width: 20),
              _stat('$_nbAbonnes', 'abonnés'),
              const Spacer(),
              if (_jePeuxPublier)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Tu peux publier',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String valeur, String libelle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          valeur,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          libelle,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }

  Widget _espaceVide() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: EspaceVideSocial(
        icone: Icons.article_outlined,
        titre: 'Aucun reportage pour le moment',
        message:
            'Cet informateur n\'a encore rien publié. Reviens plus tard, ou '
            'demande-lui son lien à jour.',
      ),
    );
  }

  Widget _lienInvalide() {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_off,
              size: 52,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              'Lien invalide ou révoqué',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Cet espace n\'existe plus avec ce lien. Demande à ton ami(e) '
              'de te renvoyer son lien à jour.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
