import 'package:flutter/material.dart';

import '../services/position_partage_service.dart';
import '../services/supabase_service.dart';

/// Consentement explicite au partage de position avec les amis(es).
///
/// Le partage est désactivé par défaut. L'utilisateur choisit une durée et
/// peut l'arrêter à tout moment ; l'arrêt efface immédiatement les coordonnées
/// côté serveur.
class PartagePositionScreen extends StatefulWidget {
  const PartagePositionScreen({super.key});

  @override
  State<PartagePositionScreen> createState() => _PartagePositionScreenState();
}

class _PartagePositionScreenState extends State<PartagePositionScreen> {
  bool _actif = false;
  bool _chargement = true;
  bool _traitement = false;
  DateTime? _expiration;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final details = await SupabaseService().monPartagePositionDetails();
    if (!mounted) return;
    setState(() {
      _actif = details['actif'] == true;
      _expiration = DateTime.tryParse('${details['expire_a'] ?? ''}');
      _chargement = false;
    });
  }

  Future<void> _activer() async {
    final choix = await showModalBottomSheet<int?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Pendant combien de temps ?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.timer),
              title: const Text('1 heure'),
              onTap: () => Navigator.pop(ctx, 60),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('8 heures'),
              onTap: () => Navigator.pop(ctx, 480),
            ),
            ListTile(
              leading: const Icon(Icons.today),
              title: const Text('24 heures'),
              onTap: () => Navigator.pop(ctx, 1440),
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: const Text("Jusqu'à désactivation"),
              subtitle: const Text('Vous pourrez arrêter à tout moment.'),
              onTap: () => Navigator.pop(ctx, 0),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choix == null || !mounted) return;

    setState(() => _traitement = true);
    final ok = await PositionPartageService.instance.activer(
      dureeMinutes: choix == 0 ? null : choix,
    );
    if (!mounted) return;
    setState(() {
      _traitement = false;
      _actif = ok;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Impossible d’activer le partage. Vérifiez la localisation.',
          ),
        ),
      );
    } else {
      await _charger();
    }
  }

  Future<void> _desactiver() async {
    setState(() => _traitement = true);
    await PositionPartageService.instance.desactiver();
    if (!mounted) return;
    setState(() {
      _traitement = false;
      _actif = false;
      _expiration = null;
    });
  }

  String get _expirationTexte {
    final d = _expiration;
    if (d == null) return 'Aucune date de fin';
    return 'Expire le ${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')} à '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Partage de position'),
        centerTitle: true,
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Icon(
                  _actif ? Icons.share_location : Icons.location_off,
                  size: 56,
                  color: _actif
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  _actif ? 'Partage actif' : 'Partage désactivé',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _actif
                      ? 'Vos amis(es) confirmé(es) peuvent voir votre '
                            'position récente sur la carte. $_expirationTexte.'
                      : 'Personne ne voit votre position. Vous pouvez '
                            'l’activer pour une durée limitée.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                if (_traitement)
                  const Center(child: CircularProgressIndicator())
                else
                  FilledButton.icon(
                    onPressed: _actif ? _desactiver : _activer,
                    icon: Icon(
                      _actif ? Icons.stop_circle : Icons.share_location,
                    ),
                    label: Text(
                      _actif ? 'Arrêter le partage' : 'Partager ma position',
                    ),
                  ),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Ce que KinFlow partage',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 8),
                        Text(
                          '• Uniquement avec vos amis(es) confirmé(es).\n'
                          '• Une position de moins de 60 minutes au maximum.\n'
                          '• La position est effacée dès que vous arrêtez le '
                          'partage ou vous déconnectez.\n'
                          '• Aucune position n’est partagée avec les comptes '
                          'que vous avez bloqués.',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Conseil : la localisation doit être autorisée dans les '
                  'réglages du téléphone. Le partage s’arrête aussi quand '
                  'l’application passe en arrière-plan.',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }
}
