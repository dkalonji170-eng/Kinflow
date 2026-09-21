import 'dart:async';

import 'package:flutter/material.dart';

import '../models/information_ville.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';

/// Les trois façons de trier le fil.
enum _TriFil { recent, populaires, confirmees }

/// Le fil de la ville : la suite d'informations publiées par KinFlow.
/// Les utilisateurs ne publient rien : ils réagissent en VERT (info
/// confirmée/utile) ou en ROUGE (info fausse), une réaction par personne,
/// et peuvent déposer un émoji. Une petite pastille rouge signale chaque
/// information « nouvelle » depuis la dernière visite.
class FilVilleScreen extends StatefulWidget {
  const FilVilleScreen({super.key});

  @override
  State<FilVilleScreen> createState() => _FilVilleScreenState();
}

class _FilVilleScreenState extends State<FilVilleScreen> {
  static const Duration _rafraichissementAuto = Duration(seconds: 60);
  static const List<String> _paletteEmojis = [
    '❤️', '😂', '👍', '😮', '😢', '😡', '🔥', '👏', '🎉', '💯', '🙏', '😍',
  ];

  List<InformationVille> _informations = [];
  bool _chargement = true;
  Timer? _minuteur;

  /// Dernière ouverture du fil : les infos publiées après cette date sont
  /// signalées par un petit point rouge (« nouvelle notification »).
  DateTime? _dernierVu;
  bool _premiereCharge = true;

  @override
  void initState() {
    super.initState();
    _lireDernierVu();
    _chargerFil();
    _minuteur = Timer.periodic(_rafraichissementAuto, (_) => _chargerFil());
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    super.dispose();
  }

  Future<void> _chargerFil() async {
    final informations = await SupabaseService().chargerFilInformations();
    if (!mounted) return;
    setState(() {
      _informations = informations;
      _chargement = false;
    });
    // Première charge réussie : on note « tout est vu » pour la prochaine
    // visite. Les infos arrivées après auront le point rouge.
    if (_premiereCharge) {
      _premiereCharge = false;
      _marquerToutVu();
    }
  }

  Future<void> _lireDernierVu() async {
    final vu = await SupabaseService().lireDernierVuFil();
    if (!mounted) return;
    setState(() => _dernierVu = vu);
  }

  Future<void> _marquerToutVu() async {
    await SupabaseService().marquerFilVu();
  }

  bool _estNouvelle(InformationVille info) {
    final vu = _dernierVu;
    return vu != null && info.creeA.isAfter(vu);
  }

  // --- Tri du fil -----------------------------------------------------------

  _TriFil _tri = _TriFil.recent;

  List<InformationVille> get _informationsTriees {
    final liste = [..._informations];
    switch (_tri) {
      case _TriFil.recent:
        liste.sort((a, b) => b.creeA.compareTo(a.creeA));
      case _TriFil.populaires:
        liste.sort((a, b) => b.nbReactionsTotal.compareTo(a.nbReactionsTotal));
      case _TriFil.confirmees:
        liste.sort((a, b) => b.nbVerts.compareTo(a.nbVerts));
    }
    return liste;
  }

  Widget _barreTri() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          _chipTri('Récent', _TriFil.recent),
          const SizedBox(width: 8),
          _chipTri('Populaires', _TriFil.populaires),
          const SizedBox(width: 8),
          _chipTri('Confirmées', _TriFil.confirmees),
        ],
      ),
    );
  }

  Widget _chipTri(String libelle, _TriFil valeur) {
    final theme = Theme.of(context);
    return ChoiceChip(
      label: Text(libelle),
      selected: _tri == valeur,
      selectedColor: theme.colorScheme.primaryContainer,
      onSelected: (_) => setState(() => _tri = valeur),
    );
  }

  /// Vert : pose une réaction VERT, ou l'enlève si déjà posée.
  /// Rouge idem avec ROUGE. Changer de couleur remplace la réaction.
  Future<void> _reagir(InformationVille info, String sens) async {
    final avant = info.maReaction;
    final retrait = avant == sens; // retaper la même couleur = retrait
    final attendu = retrait ? null : sens;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Social')),
      body: _buildCorps(),
    );
  }

  Widget _buildCorps() {
    if (_chargement) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        _barreTri(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _chargerFil,
            child: _informations.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 120),
                      Icon(
                        Icons.campaign_outlined,
                        size: 72,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Aucune information pour le moment.\nKinFlow vous tiendra au courant !',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: _informationsTriees.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _carteInformation(_informationsTriees[index]),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _carteInformation(InformationVille info) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: KinColors.primary.withValues(alpha: 0.14),
                  foregroundColor: KinColors.primary,
                  child: const Icon(Icons.campaign, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'KinFlow',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        _tempsRelatif(info.creeA),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (info.epinglee) ...[
                  const SizedBox(width: 8),
                  const Tooltip(
                    message: 'Information épinglée',
                    child: Icon(Icons.push_pin, size: 16, color: Colors.amber),
                  ),
                ],
                if (_estNouvelle(info)) ...[
                  const SizedBox(width: 10),
                  const Tooltip(
                    message: 'Nouvelle information',
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(width: 10, height: 10),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              info.contenu,
              style: const TextStyle(fontSize: 15, height: 1.35),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _boutonReaction(
                  info: info,
                  sens: 'VERT',
                  icon: Icons.thumb_up,
                  couleur: Colors.green.shade600,
                  couleurFondee: KinColors.fluideFonce,
                  libelle: 'Info confirmée',
                ),
                const SizedBox(width: 8),
                _boutonReaction(
                  info: info,
                  sens: 'ROUGE',
                  icon: Icons.thumb_down,
                  couleur: Colors.red.shade600,
                  couleurFondee: KinColors.grosEmbouteillages,
                  libelle: 'Info fausse',
                ),
              ],
            ),
            const SizedBox(height: 10),
            _barreProportion(info),
            const SizedBox(height: 10),
            _boutonsEmojis(info),
          ],
        ),
      ),
    );
  }

  Widget _boutonReaction({
    required InformationVille info,
    required String sens,
    required IconData icon,
    required Color couleur,
    required Color couleurFondee,
    required String libelle,
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
          onTap: () => _reagir(info, sens),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
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
                    fontWeight: FontWeight.w700,
                    color: actif ? couleurFondee : couleur,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    actif ? 'Vous : $libelle' : libelle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: actif ? FontWeight.w700 : FontWeight.w500,
                      color: actif ? couleurFondee : couleur,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
        _boutonAjouterEmoji(info),
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
        onTap: () => _reagirEmoji(info, emoji),
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
    final choisi = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Réagir avec un émoji',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (choisi == null || !mounted) return;
    await _reagirEmoji(info, choisi);
  }

  /// Ajoute ou retire un émoji (bascule optimiste, comme les pouces).
  Future<void> _reagirEmoji(InformationVille info, String emoji) async {
    final etaitActif = info.mesEmojis.contains(emoji);
    setState(() {
      final index = _informations.indexWhere((i) => i.id == info.id);
      if (index == -1) return;
      final i = _informations[index];
      var emojis = [...i.emojis];
      final trouve = emojis.indexWhere((x) => x.$1 == emoji);
      final mesEmojis = {...i.mesEmojis};
      if (etaitActif) {
        mesEmojis.remove(emoji);
        if (trouve != -1) {
          final (e, c) = emojis[trouve];
          if (c <= 1) {
            emojis.removeAt(trouve);
          } else {
            emojis[trouve] = (e, c - 1);
          }
        }
      } else {
        mesEmojis.add(emoji);
        if (trouve != -1) {
          final (e, c) = emojis[trouve];
          emojis[trouve] = (e, c + 1);
        } else {
          emojis.add((emoji, 1));
        }
      }
      emojis.sort((a, b) => b.$2.compareTo(a.$2));
      _informations[index] = InformationVille(
        id: i.id,
        contenu: i.contenu,
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
    }
  }

  /// Transforme une date en libellé relatif français.
  static String _tempsRelatif(DateTime t) {
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