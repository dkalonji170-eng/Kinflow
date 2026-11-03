import 'package:flutter/material.dart';

import '../models/commentaire.dart';
import '../models/publication.dart';
import '../services/supabase_service.dart';
import '../widgets/avatar_anonyme.dart';
import '../widgets/avatar_animal.dart';
import '../widgets/carte_publication.dart';

/// Détail d'un reportage : texte complet, photos, likes et commentaires.
///
/// Les commentaires sont ouverts à tous les lecteurs de l'espace. On peut
/// répondre à un commentaire, y réagir avec un emoji, et commenter ou publier
/// anonymement (cercle noir barré + « Anonyme »).
class PublicationScreen extends StatefulWidget {
  const PublicationScreen({
    super.key,
    required this.publication,
    this.onModifiee,
  });

  final Publication publication;

  /// Prévient l'écran précédent qu'un like ou une suppression a changé la
  /// carte.
  final ValueChanged<Publication>? onModifiee;

  @override
  State<PublicationScreen> createState() => _PublicationScreenState();
}

class _PublicationScreenState extends State<PublicationScreen> {
  static const List<String> _emojis = [
    '👍',
    '❤️',
    '😂',
    '😮',
    '😢',
    '🔥',
    '👏',
    '🙏',
  ];

  final SupabaseService _service = SupabaseService();
  final TextEditingController _saisie = TextEditingController();
  final FocusNode _focus = FocusNode();

  late Publication _publication = widget.publication;
  List<Commentaire> _commentaires = const [];
  bool _chargement = true;
  bool _envoi = false;
  bool _anonyme = false;
  Commentaire? _reponseA;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  @override
  void dispose() {
    _saisie.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    final commentaires = await _service.commentairesPublication(
      _publication.id,
    );
    if (!mounted) return;
    setState(() {
      _commentaires = commentaires;
      _chargement = false;
    });
  }

  void _notifier() => widget.onModifiee?.call(_publication);

  Future<void> _liker() async {
    final nouvelEtat = await _service.likerPublication(_publication.id);
    if (!mounted || nouvelEtat == null) return;
    setState(() {
      _publication = _publication.copyWith(
        jaiLike: nouvelEtat,
        nbLikes: _publication.nbLikes + (nouvelEtat ? 1 : -1),
      );
    });
    _notifier();
  }

  Future<void> _envoyer() async {
    final texte = _saisie.text.trim();
    if (texte.isEmpty || _envoi) return;
    setState(() => _envoi = true);
    final id = await _service.commenterPublication(
      publication: _publication.id,
      contenu: texte,
      parent: _reponseA?.id,
      anonyme: _anonyme,
    );
    if (!mounted) return;
    if (id == null) {
      setState(() => _envoi = false);
      _snack(
        'Commentaire non envoyé : ${_service.derniereErreur ?? 'réessaie.'}',
      );
      return;
    }
    _saisie.clear();
    setState(() {
      _envoi = false;
      _reponseA = null;
      _publication = _publication.copyWith(
        nbCommentaires: _publication.nbCommentaires + 1,
      );
    });
    _notifier();
    await _charger();
  }

  Future<void> _supprimerCommentaire(Commentaire commentaire) async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce commentaire ?'),
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
    final ok = await _service.supprimerCommentaire(commentaire.id);
    if (!mounted) return;
    if (!ok) {
      _snack('Suppression impossible.');
      return;
    }
    setState(() {
      _publication = _publication.copyWith(
        nbCommentaires: (_publication.nbCommentaires - 1).clamp(0, 1 << 30),
      );
    });
    _notifier();
    await _charger();
  }

  Future<void> _choisirEmoji(Commentaire commentaire) async {
    final choisi = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final emoji in _emojis)
                InkWell(
                  onTap: () => Navigator.pop(ctx, emoji),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: commentaire.monEmoji == emoji
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.14)
                          : null,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (choisi == null) return;
    final resultat = await _service.reagirCommentaire(commentaire.id, choisi);
    if (!mounted) return;
    setState(() {
      _commentaires = _commentaires
          .map(
            (c) => c.id == commentaire.id
                ? c.copyWith(
                    monEmoji: resultat,
                    retirerEmoji: resultat == null,
                    nbReactions:
                        c.nbReactions +
                        (resultat == null
                            ? (c.monEmoji == null ? 0 : -1)
                            : (c.monEmoji == null ? 1 : 0)),
                  )
                : c,
          )
          .toList(growable: false);
    });
  }

  void _repondre(Commentaire commentaire) {
    // On répond toujours au commentaire racine : l'affichage ne gère qu'un
    // seul niveau de réponses.
    var racine = commentaire;
    while (racine.estReponse) {
      final parentId = racine.parent;
      final parent = _commentaires.firstWhere(
        (c) => c.id == parentId,
        orElse: () => racine,
      );
      if (parent.id == racine.id) break;
      racine = parent;
    }
    setState(() => _reponseA = racine);
    _focus.requestFocus();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reportage')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                CartePublication(
                  publication: _publication,
                  onLike: _liker,
                  onCommentaires: () => _focus.requestFocus(),
                ),
                const SizedBox(height: 6),
                Text(
                  'Commentaires',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                if (_chargement)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (_commentaires.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Aucun commentaire. Sois le premier.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ..._construireFil(theme),
              ],
            ),
          ),
          _barreSaisie(theme),
        ],
      ),
    );
  }

  List<Widget> _construireFil(ThemeData theme) {
    final racines = _commentaires
        .where((c) => !c.estReponse)
        .toList(growable: false);
    final enfants = <String, List<Commentaire>>{};
    for (final c in _commentaires.where((c) => c.estReponse)) {
      enfants.putIfAbsent(c.parent!, () => []).add(c);
    }
    final widgets = <Widget>[];
    for (final racine in racines) {
      widgets.add(_ligneCommentaire(theme, racine, estReponse: false));
      for (final enfant in enfants[racine.id] ?? const <Commentaire>[]) {
        widgets.add(_ligneCommentaire(theme, enfant, estReponse: true));
      }
    }
    return widgets;
  }

  Widget _ligneCommentaire(
    ThemeData theme,
    Commentaire commentaire, {
    required bool estReponse,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: estReponse ? 36 : 0, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (commentaire.anonyme)
            AvatarAnonyme(taille: estReponse ? 26 : 32)
          else
            AvatarAnimalWidget(
              taille: estReponse ? 26 : 32,
              avatarId: commentaire.auteurAvatar,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        commentaire.nomAffiche,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      dateCourte(commentaire.creeA),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  commentaire.contenu,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => _repondre(commentaire),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Répondre'),
                    ),
                    InkWell(
                      onTap: () => _choisirEmoji(commentaire),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              commentaire.monEmoji ?? '😊',
                              style: TextStyle(
                                fontSize: 15,
                                color: commentaire.monEmoji == null
                                    ? theme.colorScheme.onSurfaceVariant
                                    : null,
                              ),
                            ),
                            if (commentaire.nbReactions > 0) ...[
                              const SizedBox(width: 3),
                              Text(
                                '${commentaire.nbReactions}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (commentaire.jePeuxSupprimer)
                      IconButton(
                        onPressed: () => _supprimerCommentaire(commentaire),
                        tooltip: 'Supprimer',
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        icon: const Icon(Icons.delete_outline),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _barreSaisie(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_reponseA != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Réponse à ${_reponseA!.nomAffiche}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _reponseA = null),
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _anonyme = !_anonyme),
                  tooltip: _anonyme
                      ? 'Commenter avec mon nom'
                      : 'Commenter anonymement',
                  icon: Icon(
                    _anonyme ? Icons.visibility_off : Icons.visibility,
                    color: _anonyme ? theme.colorScheme.primary : null,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _saisie,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: _anonyme
                          ? 'Commenter en anonyme…'
                          : 'Écrire un commentaire…',
                      counterText: '',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _envoi ? null : _envoyer,
                  icon: _envoi
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
