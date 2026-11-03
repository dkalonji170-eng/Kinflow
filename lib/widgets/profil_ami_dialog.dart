import 'package:flutter/material.dart';

import '../services/supabase_service.dart';
import 'actions_ami.dart';
import 'avatar_animal.dart';

/// Ouvre la fiche d'un ami en grand : son avatar et les actions possibles
/// (signaler, bloquer). Utilisé quand on touche l'icône d'un ami.
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
  bool _bloque = false;
  bool _traitement = false;

  @override
  void initState() {
    super.initState();
    _chargerBlocage();
  }

  Future<void> _chargerBlocage() async {
    final bloque = await SupabaseService().estBloque(widget.userId);
    if (!mounted) return;
    setState(() => _bloque = bloque);
  }

  Future<void> _bloquer() async {
    setState(() => _traitement = true);
    final ok = await bloquerUtilisateur(
      context,
      userId: widget.userId,
      nom: widget.nom,
    );
    if (!mounted) return;
    setState(() {
      _traitement = false;
      if (ok) _bloque = true;
    });
  }

  Future<void> _debloquer() async {
    setState(() => _traitement = true);
    final ok = await debloquerUtilisateur(context, userId: widget.userId);
    if (!mounted) return;
    setState(() {
      _traitement = false;
      if (ok) _bloque = false;
    });
  }

  Future<void> _signaler() async {
    setState(() => _traitement = true);
    await signalerUtilisateur(context, userId: widget.userId);
    if (!mounted) return;
    setState(() => _traitement = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
              AvatarAnimalWidget(taille: 140, avatarId: widget.avatarId),
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
              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 6),
              if (_traitement)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton.icon(
                      onPressed: _signaler,
                      icon: const Icon(Icons.flag_outlined, size: 19),
                      label: const Text('Signaler'),
                    ),
                    TextButton.icon(
                      onPressed: _bloque ? _debloquer : _bloquer,
                      style: TextButton.styleFrom(
                        foregroundColor: _bloque
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                      icon: Icon(
                        _bloque ? Icons.lock_open : Icons.block,
                        size: 19,
                      ),
                      label: Text(_bloque ? 'Débloquer' : 'Bloquer'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
