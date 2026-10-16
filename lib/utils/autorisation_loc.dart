import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Demande d'autorisation de « localisation simple ».
///
/// À la première amitié, chaque personne doit être prévenue et donner son
/// accord : l'un en acceptant la demande, l'autre à la première ouverture de la
/// discussion. L'accord peut être retiré à tout moment depuis la discussion
/// (« Autorisations de localisation »).

/// Affiche la question « Autoriser [nom] à te localiser ? ». Retourne le choix
/// de l'utilisateur (true = oui, false = non), ou null s'il ferme la boîte.
Future<bool?> demanderAutorisationLocSimple(
  BuildContext context,
  String nom,
) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Localisation'),
      content: Text(
        'Autoriser $nom à te localiser à tout moment (localisation simple) ?\n\n'
        'Tu pourras retirer cette autorisation quand tu veux. En cas '
        'd\'urgence, $nom pourra te localiser une fois même sans autorisation.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Non'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Oui'),
        ),
      ],
    ),
  );
}

String _cle(String amiId) => 'loc_autorisation_demandee_$amiId';

/// Vrai si la question de localisation a déjà été posée pour cet(te) ami(e)
/// sur cet appareil (évite de la reposer en boucle).
Future<bool> questionLocDejaPosee(String amiId) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_cle(amiId)) ?? false;
}

/// Mémorise que la question a été posée pour cet(te) ami(e).
Future<void> marquerQuestionLocPosee(String amiId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_cle(amiId), true);
}
