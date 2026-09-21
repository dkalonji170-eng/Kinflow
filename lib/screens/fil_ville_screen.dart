import 'dart:async';

import 'package:flutter/material.dart';

import '../models/information_ville.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';

/// Le fil de la ville : la suite d'informations publiées par KinFlow.
/// Les utilisateurs ne publient rien : ils réagissent en VERT (info
/// confirmée/utile) ou en ROUGE (info fausse), une réaction par personne.
class FilVilleScreen extends StatefulWidget {
  const FilVilleScreen({super.key});

  @override
  State<FilVilleScreen> createState() => _FilVilleScreenState();
}

class _FilVilleScreenState extends State<FilVilleScreen> {
  static const Duration _rafraichissementAuto = Duration(seconds: 60);

  List<InformationVille> _informations = [];
  bool _chargement = true;
  Timer? _minuteur;

  @override
  void initState() {
    super.initState();
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
    if (_informations.isEmpty) {
      return RefreshIndicator(
        onRefresh: _chargerFil,
        child: ListView(
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
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _chargerFil,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: _informations.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) =>
            _carteInformation(_informations[index]),
      ),
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