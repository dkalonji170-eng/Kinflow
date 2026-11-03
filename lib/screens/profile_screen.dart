import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import '../widgets/avatar_animal.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.integre = false});

  final bool integre;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String nom = "";
  String prenom = "";
  String sexe = "";
  String date = "";
  String telephone = "";
  String email = "";
  String code = "";
  String avatar = "";
  bool _chargementPage = true;
  bool _pageCreee = false;
  final TextEditingController _nomPage = TextEditingController();
  final TextEditingController _descriptionPage = TextEditingController();
  final TextEditingController _categoriePage = TextEditingController();

  String _formaterCode(String c) {
    final propre = c.trim();
    if (propre.length == 8) {
      return '${propre.substring(0, 4)}-${propre.substring(4)}';
    }
    return propre;
  }

  @override
  void initState() {
    super.initState();
    chargerProfil();
    _chargerPage();
  }

  @override
  void dispose() {
    _nomPage.dispose();
    _descriptionPage.dispose();
    _categoriePage.dispose();
    super.dispose();
  }

  Future<void> _chargerPage() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _pageCreee = prefs.getBool('kinflow_page_ma_page_creee') ?? false;
      _nomPage.text = prefs.getString('kinflow_page_ma_page_nom') ?? '';
      _descriptionPage.text =
          prefs.getString('kinflow_page_ma_page_description') ?? '';
      _categoriePage.text =
          prefs.getString('kinflow_page_ma_page_categorie') ?? '';
      _chargementPage = false;
    });
  }

  Future<void> _creerPage() async {
    if (_nomPage.text.trim().isEmpty || _categoriePage.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Renseigne au minimum le nom et la catégorie de la page.'),
        ),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('kinflow_page_ma_page_creee', true);
    await prefs.setString('kinflow_page_ma_page_nom', _nomPage.text.trim());
    await prefs.setString(
      'kinflow_page_ma_page_description',
      _descriptionPage.text.trim(),
    );
    await prefs.setString(
      'kinflow_page_ma_page_categorie',
      _categoriePage.text.trim(),
    );
    if (!mounted) return;
    setState(() => _pageCreee = true);
  }

  Future<void> _sauverParametresPage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kinflow_page_ma_page_nom', _nomPage.text.trim());
    await prefs.setString(
      'kinflow_page_ma_page_description',
      _descriptionPage.text.trim(),
    );
    await prefs.setString(
      'kinflow_page_ma_page_categorie',
      _categoriePage.text.trim(),
    );
    if (!mounted) return;
    Navigator.pop(context);
    setState(() {});
  }

  void _ouvrirParametresPage() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          MediaQuery.viewInsetsOf(ctx).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paramètres de la page',
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nomPage,
              decoration: const InputDecoration(
                labelText: 'Nom de la page',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _categoriePage,
              decoration: const InputDecoration(
                labelText: 'Catégorie',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionPage,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sauverParametresPage,
                child: const Text('Enregistrer'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _configurationInitiale() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.web_outlined, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'Paramètre ta page avant de la créer',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _nomPage,
          decoration: const InputDecoration(
            labelText: 'Nom de la page *',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _categoriePage,
          decoration: const InputDecoration(
            labelText: 'Catégorie *',
            hintText: 'Commerce, association, artiste…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descriptionPage,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Description',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _creerPage,
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('Créer ma page'),
        ),
      ],
    );
  }

  Future<void> chargerProfil() async {
    final service = SupabaseService();
    // 1) Affichage instantané depuis le cache local (petit animal tapé) :
    //    pas d'écran vide le temps de la requête réseau.
    final cache = await service.chargerProfilCache();
    if (!mounted) return;
    if (cache != null) _appliquer(cache);
    // 2) Rafraîchissement depuis le serveur (données à jour).
    Journal.i('PROFIL', 'Chargement du profil depuis le serveur');
    try {
      final profile = await service.loadProfile();
      if (!mounted) return;
      if (profile != null) {
        _appliquer(profile);
      } else if (cache == null) {
        Journal.a(
          'PROFIL',
          'Aucun profil renvoyé par le serveur (non connecté ?)',
        );
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargement profil: $e');
      Journal.e('PROFIL', 'Chargement du profil planté', {'erreur': '$e'});
    }
  }

  /// Applique un profil (cache local ou serveur) à l'affichage.
  void _appliquer(Map<String, dynamic> profile) {
    if (!mounted) return;
    setState(() {
      nom = profile['nom'] as String? ?? '';
      prenom = profile['prenom'] as String? ?? '';
      sexe = profile['sexe'] as String? ?? '';
      date = profile['date'] as String? ?? '';
      telephone = profile['telephone'] as String? ?? '';
      email = profile['email'] as String? ?? '';
      code = profile['code'] as String? ?? '';
      avatar = profile['avatar'] as String? ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_chargementPage) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_pageCreee) {
      final configuration = Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: widget.integre ? null : AppBar(title: const Text('Ma page')),
        body: _configurationInitiale(),
      );
      return widget.integre ? configuration.body! : configuration;
    }

    final contenu = Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          AvatarAnimalWidget(taille: 90, avatarId: avatar),
          const SizedBox(height: 15),
          Text(
            "$nom $prenom",
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          if (_nomPage.text.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _nomPage.text.trim(),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ],
          if (_categoriePage.text.trim().isNotEmpty)
            Text(_categoriePage.text.trim()),
          if (_descriptionPage.text.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _descriptionPage.text.trim(),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 30),
          Card(
            child: ListTile(
              title: Text("Sexe : $sexe"),
              subtitle: Text(
                "Date de naissance : $date\n"
                "Téléphone : $telephone\n"
                "Email : $email",
              ),
            ),
          ),
          const Spacer(),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              foregroundColor: colorScheme.onSurface,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const EditProfileScreen(),
                ),
              ).then((value) {
                chargerProfil();
              });
            },
            icon: const Icon(Icons.edit),
            label: const Text("Modifier mon profil"),
          ),
        ],
      ),
    );

    final pageMenu = PopupMenuButton<String>(
      tooltip: 'Informations et paramètres de la page',
      onSelected: (valeur) {
        if (valeur == 'parametres') _ouvrirParametresPage();
        if (valeur == 'permissions') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Gestion des personnes autorisées à venir.'),
            ),
          );
        }
        if (valeur == 'publication') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Gestion des informations de la page à venir.'),
            ),
          );
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'parametres',
          child: ListTile(
            leading: Icon(Icons.settings_outlined),
            title: Text('Informations et paramètres'),
          ),
        ),
        PopupMenuItem(
          value: 'permissions',
          child: ListTile(
            leading: Icon(Icons.admin_panel_settings_outlined),
            title: Text('Autoriser des personnes'),
          ),
        ),
        PopupMenuItem(
          value: 'publication',
          child: ListTile(
            leading: Icon(Icons.post_add_outlined),
            title: Text('Informations de la page'),
          ),
        ),
      ],
    );

    final page = Scaffold(
      appBar: widget.integre
          ? AppBar(
              automaticallyImplyLeading: false,
              title: Text(_nomPage.text.trim().isEmpty ? 'Ma page' : _nomPage.text.trim()),
              actions: [pageMenu],
            )
          : AppBar(
              title: const Text('Ma page'),
              actions: [pageMenu],
            ),
      body: contenu,
    );

    if (widget.integre) return page;
    return page;
  }
}
