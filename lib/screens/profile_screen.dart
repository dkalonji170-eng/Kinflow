import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import '../services/diagnostics_service.dart';
import '../services/supabase_service.dart';
import '../widgets/avatar_animal.dart';
import 'edit_profile_screen.dart';

/// Mon profil : l'avatar puis deux sections DÉPLIABLES, comme dans les
/// Paramètres — un appui sur la ligne fait descendre la flèche et ouvre le
/// contenu :
///
///  - « Code du compte » : le code privé qui sert à se reconnecter ;
///  - « Code ami » : le code public à partager pour qu'on t'ajoute.
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

  /// Code AMI public (distinct du code de compte, qui est privé).
  String _codeAmi = "";
  bool _chargementCodeAmi = true;

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
    _chargerCodeAmi();
  }

  Future<void> _chargerCodeAmi() async {
    final codeAmi = await SupabaseService().monCodeAmi();
    if (!mounted) return;
    setState(() {
      _codeAmi = (codeAmi ?? '').trim();
      _chargementCodeAmi = false;
    });
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

  void _copier(String valeur, String message) {
    Clipboard.setData(ClipboardData(text: valeur));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// Ligne dépliable « façon Paramètres » : une ligne avec la flèche à droite,
  /// qui descend et laisse apparaître [contenu] quand on appuie dessus.
  Widget _section({
    required IconData icone,
    required String titre,
    required List<Widget> contenu,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Pas de trait de séparation au-dessus/dessous du contenu ouvert.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icone, color: theme.colorScheme.primary),
          title: Text(
            titre,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          // La flèche par défaut (chevron vers le bas) se retourne vers le
          // haut à l'ouverture : c'est le mouvement demandé.
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: contenu,
        ),
      ),
    );
  }

  Widget _texteSecondaire(String texte) {
    final couleur = Theme.of(context).colorScheme;
    return Text(
      texte,
      style: TextStyle(
        fontSize: 12,
        color: couleur.onSurface.withValues(alpha: 0.6),
      ),
    );
  }

  /// Code présenté en gros, sélectionnable et copiable d'un appui.
  Widget _codeAffichable({
    required String valeur,
    required String messageCopie,
    required String vide,
  }) {
    final couleur = Theme.of(context).colorScheme;
    if (valeur.isEmpty) {
      return _texteSecondaire(vide);
    }
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: couleur.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              _formaterCode(valeur),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copier',
          icon: const Icon(Icons.copy, size: 20),
          onPressed: () => _copier(valeur, messageCopie),
        ),
      ],
    );
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
    return Scaffold(
      appBar: AppBar(title: const Text("Mon profil"), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
        children: [
          Center(
            child: AvatarAnimalWidget(
              taille: 108,
              avatarId: avatar,
              // Un halo lumineux pour que l'avatar ressorte sur le fond.
              brillance: true,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              "$nom $prenom",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 20),

          // 1) Code du compte — privé.
          _section(
            icone: Icons.key,
            titre: 'Code du compte',
            contenu: [
              _codeAffichable(
                valeur: code,
                messageCopie: 'Code de compte copié',
                vide: 'Code indisponible pour le moment.',
              ),
              const SizedBox(height: 8),
              _texteSecondaire('Ne le partage pas : il sert à te reconnecter.'),
            ],
          ),

          // 2) Code ami — public.
          _section(
            icone: Icons.person_add_alt_1,
            titre: 'Code ami',
            contenu: [
              if (_chargementCodeAmi)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                _codeAffichable(
                  valeur: _codeAmi,
                  messageCopie: 'Code ami copié',
                  vide: 'Code ami indisponible pour le moment.',
                ),
              const SizedBox(height: 8),
              _texteSecondaire(
                'Partage-le pour qu\'on t\'ajoute dans les amis(es).',
              ),
            ],
          ),

          // 3) Sexe et coordonnées.
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.badge_outlined, color: colorScheme.primary),
              title: Text("Sexe : $sexe"),
              subtitle: Text(
                "Date de naissance : $date\n"
                "Téléphone : $telephone\n"
                "Email : $email",
              ),
            ),
          ),
          const SizedBox(height: 20),
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
                _chargerCodeAmi();
              });
            },
            icon: const Icon(Icons.edit),
            label: const Text("Modifier mon profil"),
          ),
        ],
      ),
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
