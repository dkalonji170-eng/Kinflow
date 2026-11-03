import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';
import '../services/position_partage_service.dart';
import '../services/supabase_service.dart';
import 'splash_screen.dart';

/// Compte : sauvegarde de l'identité anonyme en compte email/mot de passe,
/// et suppression définitive du compte.
class CompteScreen extends StatefulWidget {
  const CompteScreen({super.key});

  @override
  State<CompteScreen> createState() => _CompteScreenState();
}

class _CompteScreenState extends State<CompteScreen> {
  final _email = TextEditingController();
  final _motDePasse = TextEditingController();
  final _confirmation = TextEditingController();
  bool _chargement = true;
  bool _traitement = false;
  bool _masquerMotDePasse = true;
  String? _emailCompte;
  bool _emailConfirme = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  @override
  void dispose() {
    _email.dispose();
    _motDePasse.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    final profil = await SupabaseService().loadProfile();
    if (!mounted) return;
    setState(() {
      _emailCompte = SupabaseService().emailCompte;
      _emailConfirme = SupabaseService().emailCompteConfirme;
      final emailProfil = profil?['email'] as String? ?? '';
      if (emailProfil.isNotEmpty) _email.text = emailProfil;
      _chargement = false;
    });
  }

  Future<void> _sauvegarder() async {
    if (_motDePasse.text != _confirmation.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Les mots de passe ne correspondent pas.'),
        ),
      );
      return;
    }
    setState(() => _traitement = true);
    final resultat = await SupabaseService().sauvegarderComptePermanent(
      email: _email.text,
      motDePasse: _motDePasse.text,
    );
    if (!mounted) return;
    setState(() {
      _traitement = false;
      _emailCompte = SupabaseService().emailCompte;
      _emailConfirme = SupabaseService().emailCompteConfirme;
    });

    final message = switch (resultat) {
      'ok' => 'Compte sauvegardé. Vous pouvez vous connecter par email.',
      'confirmation_requise' =>
        'Compte créé. Vérifiez votre boîte mail pour confirmer l’adresse.',
      'email_invalide' => 'Adresse e-mail invalide.',
      'mot_de_passe_trop_court' =>
        'Le mot de passe doit contenir au moins 6 caractères.',
      _ =>
        SupabaseService().derniereErreur ?? 'Sauvegarde impossible. Réessayez.',
    };
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    if (resultat == 'ok' || resultat == 'confirmation_requise') {
      _motDePasse.clear();
      _confirmation.clear();
    }
  }

  Future<void> _supprimerCompte() async {
    final controller = TextEditingController();
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer définitivement le compte ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cette action est irréversible : profil, messages, photos, '
              'vocaux, amis(es) et signalements seront supprimés.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Tapez SUPPRIMER pour confirmer',
                border: OutlineInputBorder(),
              ),
            ),
          ],
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
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim() == 'SUPPRIMER'),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (confirme != true || !mounted) return;

    setState(() => _traitement = true);
    Journal.i('COMPTE', 'Suppression définitive demandée');
    PositionPartageService.instance.stop();
    final resultat = await SupabaseService().supprimerMonCompte();
    if (!mounted) return;

    if (resultat != 'supprime') {
      setState(() => _traitement = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            SupabaseService().derniereErreur ??
                'Suppression impossible pour le moment.',
          ),
        ),
      );
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SplashScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final permanent = _emailCompte != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Mon compte'), centerTitle: true),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Icon(
                  permanent ? Icons.verified_user : Icons.person_outline,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 10),
                Text(
                  permanent
                      ? 'Compte permanent'
                      : 'Compte enregistré sur cet appareil',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  permanent
                      ? (_emailConfirme
                            ? 'Vous pouvez vous connecter sur un autre '
                                  'téléphone avec $_emailCompte et votre mot '
                                  'de passe.'
                            : 'Confirmez l’adresse $_emailCompte depuis votre '
                                  'boîte mail avant de vous connecter sur un '
                                  'autre téléphone.')
                      : 'Votre compte fonctionne avec le code affiché sur '
                            'cet appareil. Ajoutez un email et un mot de passe '
                            'pour le retrouver même après une réinstallation.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                if (permanent)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.email_outlined),
                      title: const Text('Email de connexion'),
                      subtitle: Text(_emailCompte!),
                      trailing: Icon(
                        _emailConfirme
                            ? Icons.check_circle
                            : Icons.mark_email_unread_outlined,
                      ),
                    ),
                  )
                else ...[
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _motDePasse,
                    obscureText: _masquerMotDePasse,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Mot de passe',
                      helperText: '6 caractères minimum',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _masquerMotDePasse
                            ? 'Afficher le mot de passe'
                            : 'Masquer le mot de passe',
                        icon: Icon(
                          _masquerMotDePasse
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () => setState(
                          () => _masquerMotDePasse = !_masquerMotDePasse,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _confirmation,
                    obscureText: true,
                    onSubmitted: (_) => _traitement ? null : _sauvegarder(),
                    decoration: const InputDecoration(
                      labelText: 'Confirmer le mot de passe',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _traitement ? null : _sauvegarder,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      _traitement ? 'Sauvegarde…' : 'Sauvegarder mon compte',
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'Zone dangereuse',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                  onPressed: _traitement ? null : _supprimerCompte,
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Supprimer définitivement mon compte'),
                ),
              ],
            ),
    );
  }
}
