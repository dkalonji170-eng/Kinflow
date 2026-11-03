import 'package:flutter/material.dart';

import '../services/supabase_service.dart';

/// Motifs proposés lors d'un signalement.
const Map<String, String> _motifsSignalement = {
  'spam': 'Spam ou publicité',
  'harcelement': 'Harcèlement / menaces',
  'contenu_inapproprie': 'Contenu inapproprié',
  'usurpation': 'Usurpation d’identité',
  'autre': 'Autre',
};

/// Signale un utilisateur : choix du motif, description facultative, envoi.
///
/// Retourne `true` quand le signalement a bien été enregistré. Affiche
/// elle-même le message de résultat.
Future<bool> signalerUtilisateur(
  BuildContext context, {
  required String userId,
}) async {
  final motif = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Signaler cette personne'),
      children: [
        for (final e in _motifsSignalement.entries)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, e.key),
            child: Text(e.value),
          ),
      ],
    ),
  );
  if (motif == null || !context.mounted) return false;

  final descriptionController = TextEditingController();
  final confirme = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Détails du signalement'),
      content: TextField(
        controller: descriptionController,
        maxLines: 4,
        maxLength: 500,
        decoration: const InputDecoration(
          hintText: 'Décrivez le problème (facultatif)',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Envoyer'),
        ),
      ],
    ),
  );
  final description = descriptionController.text;
  descriptionController.dispose();
  if (confirme != true || !context.mounted) return false;

  final resultat = await SupabaseService().signalerUtilisateur(
    id: userId,
    motif: motif,
    description: description,
  );
  if (!context.mounted) return resultat == 'envoye';
  final message = switch (resultat) {
    'envoye' => 'Signalement envoyé. Merci.',
    'trop_de_signalements' =>
      'Trop de signalements récents. Réessayez plus tard.',
    _ =>
      SupabaseService().derniereErreur ??
          'Signalement impossible pour le moment.',
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  return resultat == 'envoye';
}

/// Demande confirmation puis bloque un utilisateur.
///
/// Retourne `true` quand le blocage a été enregistré. Affiche elle-même le
/// message de résultat.
Future<bool> bloquerUtilisateur(
  BuildContext context, {
  required String userId,
  String? nom,
}) async {
  final confirme = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Bloquer cette personne ?'),
      content: Text(
        nom == null || nom.isEmpty
            ? 'Elle ne pourra plus vous envoyer de demande, de message ni voir '
                  'votre position. Votre amitié sera supprimée.'
            : '$nom ne pourra plus vous envoyer de demande, de message ni voir '
                  'votre position. Votre amitié sera supprimée.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Bloquer'),
        ),
      ],
    ),
  );
  if (confirme != true || !context.mounted) return false;

  final resultat = await SupabaseService().bloquerUtilisateur(userId);
  final ok = resultat == 'bloque';
  if (!context.mounted) return ok;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        ok
            ? 'Utilisateur bloqué.'
            : SupabaseService().derniereErreur ??
                  'Blocage impossible pour le moment.',
      ),
    ),
  );
  return ok;
}

/// Débloque un utilisateur et affiche le résultat.
Future<bool> debloquerUtilisateur(
  BuildContext context, {
  required String userId,
}) async {
  final ok = await SupabaseService().debloquerUtilisateur(userId);
  if (!context.mounted) return ok;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(ok ? 'Utilisateur débloqué.' : 'Déblocage impossible.'),
    ),
  );
  return ok;
}
