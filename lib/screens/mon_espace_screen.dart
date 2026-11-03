import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../config/partage_config.dart';
import '../models/publication.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/carte_publication.dart';
import 'publication_screen.dart';
import 'publier_publication_screen.dart';

/// Mon espace d'informateur : ma bio, mon lien secret, mes reportages.
///
/// Rien n'est public : l'espace n'est accessible que par le lien, et je peux
/// le révoquer à tout moment (l'ancien lien meurt).
class MonEspaceScreen extends StatefulWidget {
  const MonEspaceScreen({super.key});

  @override
  State<MonEspaceScreen> createState() => _MonEspaceScreenState();
}

class _MonEspaceScreenState extends State<MonEspaceScreen> {
  final SupabaseService _service = SupabaseService();

  bool _chargement = true;
  List<Publication> _publications = const [];
  List<Map<String, dynamic>> _membres = const [];
  String _monId = '';
  String _jeton = '';
  String _bio = '';
  String _prenom = '';
  String _nom = '';
  String? _avatar;
  int _nbAbonnes = 0;
  String _ouverture = 'proprietaire';

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final espace = await _service.monEspace();
    final publications = await _service.mesPublications();
    final membres = await _service.mesMembresEspace();
    if (!mounted) return;
    setState(() {
      _publications = publications;
      _membres = membres;
      _monId = (espace?['id'] ?? '').toString();
      _jeton = (espace?['jeton'] ?? '').toString();
      _bio = (espace?['bio'] ?? '').toString();
      _prenom = (espace?['prenom'] ?? '').toString();
      _nom = (espace?['nom'] ?? '').toString();
      _avatar = (espace?['avatar'] as String?)?.trim();
      _nbAbonnes = (espace?['nb_abonnes'] as num?)?.toInt() ?? 0;
      _ouverture = (espace?['ouverture_publication'] ?? 'proprietaire')
          .toString();
      _chargement = false;
    });
  }

  String get _lien => PartageConfig.lienEspace(_jeton);

  Future<void> _copierLien() async {
    if (_jeton.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _lien));
    if (!mounted) return;
    _snack('Lien copié.');
  }

  Future<void> _partagerLien() async {
    if (_jeton.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text:
              'Suis mon espace informateur sur KinFlow : $_lien\n'
              '(ou colle le code $_jeton dans KinFlow > Informateurs)',
          subject: 'Mon espace KinFlow',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _snack('Partage indisponible : $e');
    }
  }

  Future<void> _revoquerLien() async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Révoquer mon lien ?'),
        content: const Text(
          'L\'ancien lien ne fonctionnera plus. Les personnes qui l\'avaient '
          'enregistré ne pourront plus ouvrir ton espace. Tu pourras '
          'partager le nouveau lien.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Révoquer'),
          ),
        ],
      ),
    );
    if (confirme != true) return;
    final nouveau = await _service.regenererJetonEspace();
    if (!mounted) return;
    if (nouveau == null || nouveau.isEmpty) {
      _snack('Impossible de régénérer le lien pour le moment.');
      return;
    }
    setState(() => _jeton = nouveau);
    _snack('Nouveau lien généré.');
  }

  Future<void> _modifierBio() async {
    final controleur = TextEditingController(text: _bio);
    final texte = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ma bio d\'informateur'),
        content: TextField(
          controller: controleur,
          autofocus: true,
          maxLength: 160,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Ce que tu couvres, ton quartier…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controleur.text.trim()),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (texte == null) return;
    final ok = await _service.modifierBioEspace(texte);
    if (!mounted) return;
    if (!ok) {
      _snack('Bio non enregistrée. Réessaie.');
      return;
    }
    setState(() => _bio = texte);
    _snack('Bio enregistrée.');
  }

  Future<void> _publier() async {
    if (_jeton.isEmpty || _monId.isEmpty) return;
    final cree = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PublierPublicationScreen(jeton: _jeton, dossier: _monId),
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
      _snack('Suppression impossible. Réessaie.');
      return;
    }
    setState(() {
      _publications = _publications
          .where((p) => p.id != publication.id)
          .toList(growable: false);
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mon espace')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _publier,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Publier'),
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _charger,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  _carteIdentite(),
                  const SizedBox(height: 14),
                  _carteLien(),
                  const SizedBox(height: 14),
                  _carteQuiPublie(),
                  const SizedBox(height: 22),
                  Text(
                    'Mes reportages',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
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

  Widget _carteIdentite() {
    final nomComplet = '$_prenom $_nom'.trim();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [KinColors.primary, KinColors.primaryClair],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarAnimalWidget(taille: 56, avatarId: _avatar),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nomComplet.isEmpty ? 'Mon espace' : nomComplet,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Informateur KinFlow',
                      style: TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _modifierBio,
                tooltip: 'Modifier ma bio',
                icon: const Icon(Icons.edit_outlined, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _bio.isEmpty ? 'Ajoute une bio pour dire ce que tu couvres.' : _bio,
            style: const TextStyle(color: Colors.white, height: 1.4),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _stat('${_publications.length}', 'reportages'),
              const SizedBox(width: 22),
              _stat('$_nbAbonnes', 'abonnés'),
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
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          libelle,
          style: const TextStyle(color: Colors.white70, fontSize: 12.5),
        ),
      ],
    );
  }

  /// Réglage « qui peut publier » + équipe de co-publication.
  Widget _carteQuiPublie() {
    final theme = Theme.of(context);
    final libelle = switch (_ouverture) {
      'tous' => 'Tous les lecteurs',
      'membres' => 'Mes membres',
      _ => 'Moi seulement',
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.group_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Qui peut publier ?',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(onPressed: _choisirOuverture, child: Text(libelle)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            switch (_ouverture) {
              'tous' => 'Toute personne qui ouvre ton lien peut publier.',
              'membres' =>
                'Seules les personnes de ta liste peuvent publier avec toi.',
              _ => 'Toi seul peux publier dans ton espace.',
            },
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_ouverture == 'membres') ...[
            const SizedBox(height: 12),
            if (_membres.isEmpty)
              Text(
                'Aucun membre pour le moment.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final membre in _membres)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: AvatarAnimalWidget(
                    taille: 34,
                    avatarId: (membre['avatar'] as String?)?.trim(),
                  ),
                  title: Text(
                    (membre['nom'] ?? 'Membre').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    onPressed: () =>
                        _retirerMembre((membre['membre'] ?? '').toString()),
                    tooltip: 'Retirer',
                    icon: const Icon(Icons.person_remove_outlined, size: 20),
                  ),
                ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _ajouterMembre,
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text('Ajouter un membre'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _choisirOuverture() async {
    final choix = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (mode, titre, detail) in const [
              ('proprietaire', 'Moi seulement', 'Je suis le seul à publier.'),
              (
                'membres',
                'Mes membres',
                'Les personnes que je désigne publient avec moi.',
              ),
              (
                'tous',
                'Tous les lecteurs',
                'Toute personne qui a le lien peut publier.',
              ),
            ])
              ListTile(
                leading: Icon(
                  mode == _ouverture
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(titre),
                subtitle: Text(detail),
                onTap: () => Navigator.pop(ctx, mode),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choix == null || choix == _ouverture) return;
    final ok = await _service.modifierOuverturePublication(choix);
    if (!mounted) return;
    if (!ok) {
      _snack('Réglage non enregistré. Réessaie.');
      return;
    }
    setState(() => _ouverture = choix);
  }

  Future<void> _ajouterMembre() async {
    final controleur = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ajouter un membre'),
        content: TextField(
          controller: controleur,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Code AMI',
            hintText: 'Ex. : KF-1234',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controleur.text.trim()),
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    final ok = await _service.ajouterMembreEspace(code);
    if (!mounted) return;
    if (!ok) {
      _snack('Membre non ajouté. Vérifie le code AMI.');
      return;
    }
    await _charger();
    _snack('Membre ajouté.');
  }

  Future<void> _retirerMembre(String membre) async {
    if (membre.isEmpty) return;
    final ok = await _service.retirerMembreEspace(membre);
    if (!mounted) return;
    if (!ok) {
      _snack('Retrait impossible.');
      return;
    }
    await _charger();
  }

  Widget _carteLien() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.link, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                'Mon lien d\'informateur',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            _lien,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Seules les personnes qui ont ce lien peuvent ouvrir ton espace.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _jeton.isEmpty ? null : _copierLien,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copier'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _jeton.isEmpty ? null : _partagerLien,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Partager'),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _jeton.isEmpty ? null : _revoquerLien,
              icon: const Icon(Icons.autorenew, size: 16),
              label: const Text('Révoquer et régénérer'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _espaceVide() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.article_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            'Aucun reportage pour le moment.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Publie ton premier : une info, une photo, ton quartier.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
