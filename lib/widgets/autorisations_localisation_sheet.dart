import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import '../theme/kinflow_theme.dart';

const Color _rougeUrgence = Color(0xFFC62828);

/// Ouvre la feuille des autorisations de localisation avec un(e) ami(e).
///
/// Utilisée depuis la discussion et depuis la liste d'amis (appui long), pour
/// que les deux endroits proposent exactement les mêmes réglages.
Future<void> ouvrirAutorisationsLocalisation(
  BuildContext context, {
  required String amiId,
  required String nom,
  ValueChanged<Map<String, dynamic>>? onChanged,
}) async {
  Journal.i('SOCIAL', 'Ouverture des autorisations de localisation', {
    'ami': nom,
  });
  final etat = await SupabaseService().etatAutorisationsLocalisation(amiId);
  if (!context.mounted) return;
  if (etat == null) {
    Journal.a('SOCIAL', 'Autorisations indisponibles', {'ami': nom});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Autorisations indisponibles. Vérifie ta connexion.'),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _AutorisationsLocalisationSheet(
      amiId: amiId,
      nom: nom,
      etat: etat,
      onChanged: onChanged,
    ),
  );
}

class _AutorisationsLocalisationSheet extends StatefulWidget {
  const _AutorisationsLocalisationSheet({
    required this.amiId,
    required this.nom,
    required this.etat,
    this.onChanged,
  });

  final String amiId;
  final String nom;
  final Map<String, dynamic> etat;
  final ValueChanged<Map<String, dynamic>>? onChanged;

  @override
  State<_AutorisationsLocalisationSheet> createState() =>
      _AutorisationsLocalisationSheetState();
}

class _AutorisationsLocalisationSheetState
    extends State<_AutorisationsLocalisationSheet> {
  Map<String, dynamic> get _etat => widget.etat;

  void _notifier() => widget.onChanged?.call(_etat);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final couleur = theme.colorScheme;
    final jeLAutorise = _etat['moi_autorise_ami_loc_simple'] == true;
    final urgencePourLui =
        _etat['urgence_dispo_pour_ami_localiser_moi'] == true;
    final nom = widget.nom;
    final rouge = theme.brightness == Brightness.dark
        ? const Color(0xFFEF5350)
        : _rougeUrgence;

    // Une autorisation = une carte : icône teintée, libellé clair et
    // l'action à droite. Rien d'autre, pour rester lisible d'un coup d'œil.
    Widget carte({
      required IconData icone,
      required String titre,
      required String sousTitre,
      required Color teinte,
      required bool actif,
      Widget? accessoire,
    }) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: teinte.withValues(alpha: actif ? 0.07 : 0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: teinte.withValues(alpha: actif ? 0.30 : 0.14),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: teinte.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icone, size: 20, color: teinte),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    titre,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sousTitre,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: couleur.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            if (accessoire != null) ...[const SizedBox(width: 8), accessoire],
          ],
        ),
      );
    }

    Widget pastille(String texte, Color teinte) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: teinte.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          texte,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: teinte,
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Autorisations de localisation',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'Avec $nom',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: couleur.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            carte(
              icone: Icons.my_location,
              titre: 'Localisation simple',
              sousTitre: 'À tout moment, tant que tu l\'autorises.',
              teinte: KinColors.primary,
              actif: jeLAutorise,
              accessoire: Switch(
                value: jeLAutorise,
                thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
                  if (states.contains(WidgetState.selected)) {
                    return couleur.onPrimary;
                  }
                  return couleur.onSurfaceVariant;
                }),
                trackColor: WidgetStateProperty.resolveWith<Color>((states) {
                  if (states.contains(WidgetState.selected)) {
                    return couleur.primary;
                  }
                  return couleur.surfaceContainerHighest;
                }),
                onChanged: (v) async {
                  final ok = await SupabaseService()
                      .definirAutorisationLocSimple(widget.amiId, v);
                  if (!context.mounted) return;
                  if (ok) {
                    Journal.i(
                      'SOCIAL',
                      'Autorisation de localisation '
                          '${v ? 'accordée' : 'retirée'} (feuille)',
                      {'ami': nom},
                    );
                    setState(() => _etat['moi_autorise_ami_loc_simple'] = v);
                    _notifier();
                  } else {
                    Journal.a(
                      'SOCIAL',
                      'Changement d\'autorisation non enregistré',
                      {'ami': nom},
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Changement non enregistré.'),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 10),
            carte(
              icone: Icons.sos_outlined,
              titre: 'Localisation d\'urgence',
              sousTitre: 'Une seule fois, en cas de besoin.',
              teinte: rouge,
              actif: urgencePourLui,
              accessoire: pastille(
                urgencePourLui ? 'Disponible' : 'Utilisée',
                urgencePourLui ? KinColors.vertArrivee : rouge,
              ),
            ),
            if (!urgencePourLui) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () async {
                    final ok = await SupabaseService().renouvelerUrgence(
                      widget.amiId,
                    );
                    if (!context.mounted) return;
                    if (ok) {
                      Journal.i(
                        'SOCIAL',
                        'Localisation d\'urgence renouvelée',
                        {'ami': nom},
                      );
                      setState(
                        () => _etat['urgence_dispo_pour_ami_localiser_moi'] =
                            true,
                      );
                      _notifier();
                    } else {
                      Journal.a(
                        'SOCIAL',
                        'Renouvellement d\'urgence non enregistré',
                        {'ami': nom},
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Renouvellement non enregistré.'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.autorenew, size: 16),
                  label: const Text('Renouveler'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 15,
                  color: couleur.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Personne ne te localise sans ton accord. '
                    'Tu peux changer d\'avis à tout moment.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: couleur.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
