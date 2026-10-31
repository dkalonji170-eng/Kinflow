import 'package:flutter/material.dart';

import '../services/rang_service.dart';
import 'avatar_animal.dart';
import 'grade_rang.dart';
import 'rang_signalements_badge.dart';

/// Ouvre la fiche d'un ami en grand : son avatar (avec le grade dans le rond)
/// et le détail de son rang. Utilisé quand on touche l'icône d'un ami.
Future<void> ouvrirProfilAmi(
  BuildContext context, {
  required String userId,
  required String nom,
  String? avatarId,
}) {
  if (userId.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _ProfilAmiDialog(userId: userId, nom: nom, avatarId: avatarId),
  );
}

class _ProfilAmiDialog extends StatefulWidget {
  const _ProfilAmiDialog({
    required this.userId,
    required this.nom,
    this.avatarId,
  });

  final String userId;
  final String nom;
  final String? avatarId;

  @override
  State<_ProfilAmiDialog> createState() => _ProfilAmiDialogState();
}

class _ProfilAmiDialogState extends State<_ProfilAmiDialog> {
  Map<String, dynamic>? _rang;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _rang = RangService.instance.rang(widget.userId);
    _chargement = _rang == null;
    if (_chargement) _charger();
  }

  Future<void> _charger() async {
    final rang = await RangService.instance.chargerRang(widget.userId);
    if (!mounted) return;
    setState(() {
      _rang = rang;
      _chargement = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final niveau = RangService.instance.niveau(widget.userId);
    final rang = _rang;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Fermer',
                  icon: const Icon(Icons.close),
                ),
              ),
              AvatarAnimalWidget(
                taille: 140,
                avatarId: widget.avatarId,
                userId: widget.userId,
              ),
              const SizedBox(height: 14),
              Text(
                widget.nom,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              if (_chargement)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              else if (rang != null)
                _detailsRang(rang)
              else
                Text(
                  niveau == null
                      ? 'Grade indisponible'
                      : 'Grade : ${GradeRang.noms[niveau - 1]}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailsRang(Map<String, dynamic> rang) {
    final niveau = (rang['niveau'] as num?)?.toInt() ?? 1;
    final nom = rang['rang_nom'] as String? ??
        GradeRang.noms[niveau.clamp(1, GradeRang.noms.length) - 1];
    final couleur = rang['rang_couleur'] as String? ?? '#9E9E9E';

    return RangSignalementsBadge(
      rangNom: nom,
      rangCouleur: couleur,
      niveau: niveau,
    );
  }
}
