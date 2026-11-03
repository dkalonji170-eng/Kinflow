import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/ami_position.dart';
import '../screens/traffic_screen.dart';
import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import 'actions_ami.dart';
import 'autorisations_localisation_sheet.dart';

/// Affiche le menu d'un(e) ami(e), identique à celui des trois points de la
/// discussion : localiser, autorisations, renommer, retirer.
///
/// [onModifie] est appelé après un renommage ou un retrait réussi, pour que
/// l'écran appelant (la liste d'amis) se rafraîchisse.
Future<void> afficherMenuAmi(
  BuildContext context, {
  required String amiId,
  required String nom,
  String? avatar,
  VoidCallback? onModifie,
}) async {
  if (amiId.isEmpty) return;
  final service = SupabaseService();
  final autorisations = await service.etatAutorisationsLocalisation(amiId);
  if (!context.mounted) return;

  final simpleAutorise = autorisations?['ami_autorise_moi_loc_simple'] == true;
  final urgenceDispo =
      autorisations?['urgence_dispo_pour_moi_localiser_ami'] == true;

  final choix = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Text(
                  nom,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              ListTile(
                enabled: simpleAutorise,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.my_location),
                title: const Text('Localiser maintenant'),
                subtitle: Text(
                  simpleAutorise ? '$nom t\'a autorisé' : 'Pas encore autorisé',
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: simpleAutorise
                    ? () => Navigator.pop(ctx, 'localiser_simple')
                    : null,
              ),
              ListTile(
                enabled: urgenceDispo,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.sos_outlined),
                title: const Text('Localiser en urgence'),
                subtitle: Text(
                  urgenceDispo ? 'Une seule fois' : 'Déjà utilisée',
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: urgenceDispo
                    ? () => Navigator.pop(ctx, 'localiser_urgence')
                    : null,
              ),
              const Divider(),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.lock_outline),
                title: const Text('Autorisations de localisation'),
                onTap: () => Navigator.pop(ctx, 'autorisations'),
              ),
              const Divider(),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Renommer cet ami(e)'),
                onTap: () => Navigator.pop(ctx, 'renommer'),
              ),
              const Divider(),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Signaler'),
                onTap: () => Navigator.pop(ctx, 'signaler'),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(Icons.block, color: theme.colorScheme.error),
                title: Text(
                  'Bloquer',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: () => Navigator.pop(ctx, 'bloquer'),
              ),
              const Divider(),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(
                  Icons.person_remove_outlined,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  'Retirer cet ami(e)',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: () => Navigator.pop(ctx, 'retirer'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (!context.mounted || choix == null) return;

  switch (choix) {
    case 'localiser_simple':
      await _localiserAvec(
        context,
        service: service,
        amiId: amiId,
        nom: nom,
        avatar: avatar,
        urgence: false,
      );
      break;
    case 'localiser_urgence':
      await _localiserAvec(
        context,
        service: service,
        amiId: amiId,
        nom: nom,
        avatar: avatar,
        urgence: true,
      );
      break;
    case 'autorisations':
      await ouvrirAutorisationsLocalisation(context, amiId: amiId, nom: nom);
      break;
    case 'renommer':
      final nouveau = await _demanderNom(context, nom);
      if (!context.mounted || nouveau == null) return;
      await service.definirSurnomAmi(amiId, nouveau);
      Journal.i('SOCIAL', 'Ami(e) renommé', {
        'avant': nom,
        'apres': nouveau.isEmpty ? '(nom d\'origine)' : nouveau,
      });
      onModifie?.call();
      break;
    case 'signaler':
      await signalerUtilisateur(context, userId: amiId);
      break;
    case 'bloquer':
      final ok = await bloquerUtilisateur(context, userId: amiId, nom: nom);
      if (ok) onModifie?.call();
      break;
    case 'retirer':
      final confirme = await _confirmerRetrait(context, nom);
      if (!context.mounted || confirme != true) return;
      final ok = await service.retirerAmi(amiId);
      if (!context.mounted) return;
      if (!ok) {
        Journal.a('SOCIAL', 'Retrait de l\'ami(e) non enregistré', {
          'ami': nom,
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Retrait non enregistré. Vérifie ta connexion.'),
          ),
        );
        return;
      }
      Journal.i('SOCIAL', 'Ami(e) retiré(e)', {'ami': nom});
      onModifie?.call();
      break;
  }
}

Future<void> _localiserAvec(
  BuildContext context, {
  required SupabaseService service,
  required String amiId,
  required String nom,
  String? avatar,
  required bool urgence,
}) async {
  Journal.i(
    'SOCIAL',
    urgence
        ? 'Localisation d\'urgence demandée'
        : 'Localisation simple demandée',
    {'ami': nom},
  );
  final resultat = urgence
      ? await service.localiserUrgence(amiId)
      : await service.localiserSimple(amiId);
  if (!context.mounted) return;

  if (resultat == null || resultat['ok'] != true) {
    final erreur = resultat?['erreur']?.toString();
    Journal.a('SOCIAL', 'Localisation impossible : ${erreur ?? 'réseau'}', {
      'ami': nom,
      'mode': urgence ? 'urgence' : 'simple',
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_messageErreurLocalisation(erreur, nom))),
    );
    return;
  }
  Journal.s('SOCIAL', 'Localisation réussie', {
    'ami': nom,
    'mode': urgence ? 'urgence' : 'simple',
  });

  final latitude = _double(resultat['latitude']);
  final longitude = _double(resultat['longitude']);
  if (latitude == null || longitude == null) return;
  final position = AmiPosition(
    id: amiId,
    nom: nom,
    avatar: avatar,
    position: LatLng(latitude, longitude),
    cap: _double(resultat['cap']),
  );
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => TrafficScreen(amiALocaliser: position)),
  );
}

String _messageErreurLocalisation(String? erreur, String nom) {
  return switch (erreur) {
    'non_autorise' => '$nom ne t\'autorise pas encore à le/la localiser.',
    'urgence_epuisee' =>
      'Localisation d\'urgence déjà utilisée. Demande à $nom de la renouveler.',
    'pas_de_position' => '$nom n\'a pas de position partagée pour le moment.',
    'pas_ami' => 'Vous n\'êtes plus amis(es).',
    _ => 'Localisation impossible. Vérifie ta connexion.',
  };
}

Future<String?> _demanderNom(BuildContext context, String nom) async {
  final controller = TextEditingController(text: nom);
  final resultat = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Renommer cet ami(e)'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          hintText: 'Nouveau nom',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );
  return resultat;
}

Future<bool?> _confirmerRetrait(BuildContext context, String nom) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Retirer cet ami(e) ?'),
      content: Text('$nom ne sera plus dans tes amis(es).'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Retirer'),
        ),
      ],
    ),
  );
}

double? _double(Object? valeur) {
  if (valeur == null) return null;
  if (valeur is num) return valeur.toDouble();
  return double.tryParse(valeur.toString());
}
