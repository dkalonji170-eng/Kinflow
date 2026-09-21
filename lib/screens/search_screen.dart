import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_result.dart';
import '../services/diagnostics_service.dart';
import '../services/search_service.dart';

class SearchScreen extends StatefulWidget {
  /// Appelé quand l'utilisateur demande à poser son domicile directement sur
  /// la carte (« Ma maison » sans domicile enregistré, ou action « Placer sur
  /// la carte ») : l'écran de recherche se referme et la carte passe en mode
  /// pose d'une icône maison.
  final VoidCallback? onDemanderPoserMaison;

  /// Même mécanique pour le lieu de travail (« Mon travail ») : la carte
  /// passe en mode pose d'une icône mallette.
  final VoidCallback? onDemanderPoserTravail;

  const SearchScreen({
    super.key,
    this.onDemanderPoserMaison,
    this.onDemanderPoserTravail,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  /// Nombre de recherches récentes mémorisées et affichées sous « Ma maison ».
  static const int _nombreRecentes = 5;

  final SearchService _service = SearchService();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  StreamSubscription<List<SearchResult>>? _rechercheSub;
  List<SearchResult> _recentes = [];
  List<String> _suggestionsCategories = [];
  List<SearchResult> _resultats = [];
  bool _rechercheEnCours = false;

  /// Lieu de domicile enregistré (clé `lieu_maison`), affiché au-dessus des
  /// recherches récentes. `null` tant que l'utilisateur n'a pas choisi.
  SearchResult? _maison;

  /// Lieu de travail enregistré (clé `lieu_travail`), même présentation.
  SearchResult? _travail;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_surSaisie);
    _chargerRecentes();
    _chargerMaison();
    _chargerTravail();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _rechercheSub?.cancel();
    _controller.removeListener(_surSaisie);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _chargerRecentes() async {
    final prefs = await SharedPreferences.getInstance();
    final brut = prefs.getString('recherches_recentes');
    if (brut == null || !mounted) return;

    try {
      final donnees = json.decode(brut) as List;
      final recentes = <SearchResult>[];
      for (final e in donnees) {
        if (e is! Map) continue;
        final lat = (e['lat'] as num?)?.toDouble();
        final lon = (e['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        recentes.add(
          SearchResult(
            nom: (e['nom'] ?? '').toString(),
            sousTitre: (e['sousTitre'] ?? '').toString(),
            latitude: lat,
            longitude: lon,
          ),
        );
      }
      setState(() {
        _recentes = recentes.take(_nombreRecentes).toList();
      });
    } catch (_) {
      // historique illisible : ignoré
    }
  }

  Future<void> _chargerMaison() async {
    final prefs = await SharedPreferences.getInstance();
    final brut = prefs.getString('lieu_maison');
    if (brut == null || !mounted) return;
    try {
      final e = json.decode(brut) as Map;
      final lat = (e['lat'] as num?)?.toDouble();
      final lon = (e['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) return;
      setState(() {
        _maison = SearchResult(
          nom: (e['nom'] ?? '').toString(),
          sousTitre: (e['sousTitre'] ?? '').toString(),
          latitude: lat,
          longitude: lon,
        );
      });
    } catch (_) {
      // maison illisible : ignorée
    }
  }

  Future<void> _persisterMaison() async {
    final maison = _maison;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (maison == null) {
        await prefs.remove('lieu_maison');
        return;
      }
      await prefs.setString(
        'lieu_maison',
        json.encode({
          'nom': maison.nom,
          'sousTitre': maison.sousTitre,
          'lat': maison.latitude,
          'lon': maison.longitude,
        }),
      );
    } catch (_) {
      // persistance impossible : ignoré
    }
  }

  Future<void> _chargerTravail() async {
    final prefs = await SharedPreferences.getInstance();
    final brut = prefs.getString('lieu_travail');
    if (brut == null || !mounted) return;
    try {
      final e = json.decode(brut) as Map;
      final lat = (e['lat'] as num?)?.toDouble();
      final lon = (e['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) return;
      setState(() {
        _travail = SearchResult(
          nom: (e['nom'] ?? '').toString(),
          sousTitre: (e['sousTitre'] ?? '').toString(),
          latitude: lat,
          longitude: lon,
        );
      });
    } catch (_) {
      // travail illisible : ignoré
    }
  }

  Future<void> _persisterTravail() async {
    final travail = _travail;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (travail == null) {
        await prefs.remove('lieu_travail');
        return;
      }
      await prefs.setString(
        'lieu_travail',
        json.encode({
          'nom': travail.nom,
          'sousTitre': travail.sousTitre,
          'lat': travail.latitude,
          'lon': travail.longitude,
        }),
      );
    } catch (_) {
      // persistance impossible : ignoré
    }
  }

  /// Toucher la carte « Ma maison » : si elle est enregistrée, elle devient
  /// directement la destination choisie. Sinon, on bascule sur la carte en
  /// mode « poser ma maison » : l'icône maison suit le centre de l'écran, la
  /// carte peut pivoter pour viser le domicile, et on la pose d'un appui.
  void _choisirMaison() {
    final maison = _maison;
    if (maison != null) {
      Journal.i('RECHERCHE', 'Maison choisie comme destination', {
        'nom': maison.nom,
      });
      Navigator.pop(context, maison);
      return;
    }
    // Pas encore de domicile : on referme la recherche et on laisse l'icône
    // maison se glisser sur la carte, à poser par l'utilisateur.
    widget.onDemanderPoserMaison?.call();
    Navigator.pop(context);
  }

  /// Toucher la carte « Mon travail » : si le lieu est enregistré, il devient
  /// directement la destination (l'itinéraire jusqu'au travail se trace
  /// automatiquement depuis la carte). Sinon, on bascule sur la carte en mode
  /// « poser un lieu personnel » pour poser la mallette.
  void _choisirTravail() {
    final travail = _travail;
    if (travail != null) {
      Journal.i('RECHERCHE', 'Travail choisi comme destination', {
        'nom': travail.nom,
      });
      Navigator.pop(context, travail);
      return;
    }
    widget.onDemanderPoserTravail?.call();
    Navigator.pop(context);
  }

  /// Ouvre la fenêtre de recherche pour enregistrer (ou remplacer) le lieu
  /// de domicile. Si [retournerSelection] est vrai, le lieu choisi est aussi
  /// renvoyé comme destination ; sinon on reste dans l'écran de recherche.
  Future<void> _ouvrirChoixMaison({required bool retournerSelection}) async {
    final lieu = await showModalBottomSheet<SearchResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ChoixMaisonSheet(),
    );
    if (lieu == null) return;
    if (!mounted) return;
    setState(() => _maison = lieu);
    await _persisterMaison();
    if (!mounted) return;
    Journal.i('RECHERCHE', 'Maison enregistrée', {'nom': lieu.nom});
    if (retournerSelection) {
      Navigator.pop(context, lieu);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maison enregistrée.')),
      );
    }
  }

  /// Ouvre la fenêtre de recherche pour enregistrer (ou remplacer) le lieu
  /// de travail par nom. Si [retournerSelection] est vrai, le lieu choisi est
  /// aussi renvoyé comme destination.
  Future<void> _ouvrirChoixTravail({required bool retournerSelection}) async {
    final lieu = await showModalBottomSheet<SearchResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ChoixMaisonSheet(),
    );
    if (lieu == null) return;
    if (!mounted) return;
    setState(() => _travail = lieu);
    await _persisterTravail();
    if (!mounted) return;
    Journal.i('RECHERCHE', 'Lieu de travail enregistré', {'nom': lieu.nom});
    if (retournerSelection) {
      Navigator.pop(context, lieu);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lieu de travail enregistré.')),
      );
    }
  }

  void _surSaisie() {
    final texte = _controller.text.trim();

    setState(() {
      _suggestionsCategories = _service.suggestionsCategories(texte);
    });

    _debounce?.cancel();
    if (texte.length < 2) {
      _rechercheSub?.cancel();
      _rechercheSub = null;
      setState(() {
        _resultats = [];
        _rechercheEnCours = false;
      });
      return;
    }

    // Si le texte collé correspond à des coordonnées géographiques
    // (ex. « -4.321679, 15.311559 »), on propose directement ce point
    // sans passer par les géocodeurs.
    final coordonnees = _parserCoordonnees(texte);
    if (coordonnees != null) {
      _rechercheSub?.cancel();
      _rechercheSub = null;
      setState(() {
        _resultats = [coordonnees];
        _rechercheEnCours = false;
      });
      return;
    }

    setState(() => _rechercheEnCours = true);
    // 250 ms : assez court pour que les suggestions « suivent le doigt »,
    // assez long pour ne pas mitrailler les géocodeurs à chaque lettre.
    _debounce = Timer(const Duration(milliseconds: 250), () {
      Journal.i('RECHERCHE', 'Saisie envoyée aux géocodeurs', {'terme': texte});
      _rechercheSub?.cancel();
      _rechercheSub = _service.rechercherLieu(texte).listen((resultats) {
        if (!mounted) return;
        // Résultat périmé : l'utilisateur a modifié la saisie depuis.
        if (_controller.text.trim() != texte) return;
        setState(() {
          _resultats = resultats;
          // Première liste reçue : on arrête le grand spinner, les lots
          // suivants (Overpass) se fusionnent à l'affichage.
          _rechercheEnCours = false;
        });
      }, onError: (_) {
        if (!mounted) return;
        setState(() => _rechercheEnCours = false);
      });
    });
  }

  Future<void> _selectionner(SearchResult resultat) async {
    _debounce?.cancel();
    Journal.i('RECHERCHE', 'Lieu tapé dans la liste de résultats', {
      'nom': resultat.nom,
      'lat': resultat.latitude,
      'lon': resultat.longitude,
    });

    _recentes.removeWhere(
      (r) => r.latitude == resultat.latitude && r.longitude == resultat.longitude,
    );
    _recentes.insert(0, resultat);
    if (_recentes.length > _nombreRecentes) {
      _recentes.removeRange(_nombreRecentes, _recentes.length);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'recherches_recentes',
        json.encode([
          for (final r in _recentes)
            {
              'nom': r.nom,
              'sousTitre': r.sousTitre,
              'lat': r.latitude,
              'lon': r.longitude,
            },
        ]),
      );
    } catch (_) {
      // persistance impossible : ignoré
    }

    if (!mounted) return;
    Navigator.pop(context, resultat);
  }

  /// Transforme une saisie de type « -4.321679, 15.311559 » en résultat de
  /// coordonnées sélectionnable, ou renvoie null si ce n'est pas des
  /// coordonnées.
  SearchResult? _parserCoordonnees(String texte) {
    final partie = texte.trim();
    // Accepte le format « -4.321679, 15.311559 ».
    final correspondances =
        RegExp(r'^([-+]?\d{1,3}(?:\.\d+)?)\s*[,;\s]\s*([-+]?\d{1,3}(?:\.\d+)?)$')
            .firstMatch(partie);
    if (correspondances == null) return null;

    final lat = double.tryParse(correspondances.group(1)!);
    final lon = double.tryParse(correspondances.group(2)!);
    if (lat == null || lon == null) return null;
    // Latitude valide entre -90 et 90, longitude entre -180 et 180.
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;

    return SearchResult(
      nom: 'Position',
      sousTitre: '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}',
      latitude: lat,
      longitude: lon,
    );
  }

  void _remplir(String texte) {
    Journal.i('RECHERCHE', 'Suggestion de catégorie choisie', {'libelle': texte});    _controller.text = texte;
    _controller.selection = TextSelection.collapsed(offset: texte.length);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final couleur = Theme.of(context).colorScheme;
    final saisie = _controller.text.trim();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Fermer',
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Rechercher un lieu (Kinshasa ou ailleurs)',
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: saisie.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Effacer',
                    onPressed: () {
                      _controller.clear();
                      _focus.requestFocus();
                    },
                  ),
          ),
        ),
      ),
      body: saisie.isEmpty ? _vueRecentes() : _vueSuggestions(couleur),
    );
  }

  Widget _tileMaison() {
    final maison = _maison;
    final couleur = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.home, color: couleur.primary),
      title: Text(maison?.nom ?? 'Ma maison'),
      subtitle: maison == null
          ? const Text('Posez-la directement sur la carte')
          : (maison.sousTitre.isEmpty
              ? null
              : Text(
                  maison.sousTitre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )),
      trailing: maison == null
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Options de la maison',
              onSelected: (valeur) {
                if (valeur == 'carte') {
                  // Reposer le domicile sur la carte : on referme la
                  // recherche et le mode « poser ma maison » prend le relais.
                  widget.onDemanderPoserMaison?.call();
                  Navigator.pop(context);
                } else if (valeur == 'changer') {
                  _ouvrirChoixMaison(retournerSelection: false);
                } else if (valeur == 'supprimer') {
                  setState(() => _maison = null);
                  _persisterMaison();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Maison supprimée.')),
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'carte', child: Text('Placer sur la carte')),
                PopupMenuItem(value: 'changer', child: Text('Chercher par nom')),
                PopupMenuItem(value: 'supprimer', child: Text('Supprimer')),
              ],
            ),
      onTap: _choisirMaison,
    );
  }

  Widget _tileTravail() {
    final travail = _travail;
    final couleur = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.work, color: couleur.primary),
      title: Text(travail?.nom ?? 'Mon travail'),
      subtitle: travail == null
          ? const Text('Posez-le directement sur la carte')
          : (travail.sousTitre.isEmpty
              ? null
              : Text(
                  travail.sousTitre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )),
      trailing: travail == null
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Options du lieu de travail',
              onSelected: (valeur) {
                if (valeur == 'carte') {
                  // Reposer le lieu de travail sur la carte : on referme la
                  // recherche et le mode « poser un lieu » prend le relais.
                  widget.onDemanderPoserTravail?.call();
                  Navigator.pop(context);
                } else if (valeur == 'changer') {
                  _ouvrirChoixTravail(retournerSelection: false);
                } else if (valeur == 'supprimer') {
                  setState(() => _travail = null);
                  _persisterTravail();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Lieu de travail supprimé.'),
                    ),
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'carte', child: Text('Placer sur la carte')),
                PopupMenuItem(value: 'changer', child: Text('Chercher par nom')),
                PopupMenuItem(value: 'supprimer', child: Text('Supprimer')),
              ],
            ),
      onTap: _choisirTravail,
    );
  }

  Widget _vueRecentes() {
    final couleur = Theme.of(context).colorScheme;

    return ListView(
      children: [
        _tileMaison(),
        _tileTravail(),
        const Divider(height: 8),
        if (_recentes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Recherches récentes',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: couleur.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          for (final r in _recentes)
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(r.nom),
              subtitle: r.sousTitre.isEmpty
                  ? null
                  : Text(
                      r.sousTitre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => _selectionner(r),
            ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Column(
              children: [
                Icon(
                  Icons.search,
                  size: 36,
                  color: couleur.onSurface.withValues(alpha: 0.3),
                ),
                const SizedBox(height: 8),
                Text(
                  'Cherchez un lieu : Kinshasa est recherchée en priorité,'
                  '\net toute la planète est couverte si rien n\'y est trouvé.'
                  '\nVos 5 dernières recherches apparaîtront ici.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: couleur.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _vueSuggestions(ColorScheme couleur) {
    final enfants = <Widget>[];

    if (_suggestionsCategories.isNotEmpty) {
      enfants.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Suggestions',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: couleur.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
      for (final s in _suggestionsCategories) {
        enfants.add(
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(s),
            onTap: () => _remplir(s),
          ),
        );
      }
      enfants.add(const Divider(height: 8));
    }

    if (_rechercheEnCours && _resultats.isEmpty) {
      enfants.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else {
      for (final r in _resultats) {
        enfants.add(
          ListTile(
            leading: const Icon(Icons.location_on, color: Colors.green),
            title: Text(r.nom),
            subtitle: r.sousTitre.isEmpty
                ? null
                : Text(
                    r.sousTitre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _selectionner(r),
          ),
        );
      }
      if (_resultats.isEmpty && _suggestionsCategories.isEmpty) {
        enfants.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'Aucun lieu trouvé.',
                style: TextStyle(color: couleur.onSurface.withValues(alpha: 0.6)),
              ),
            ),
          ),
        );
      }
    }

    return ListView(children: enfants);
  }
}

/// Fenêtre de recherche utilisée pour enregistrer le lieu de domicile :
/// même moteur que l'écran principal (suggestions + géocodeur), mais le
/// résultat est renvoyé au parent qui le persiste en clé `lieu_maison`.
class _ChoixMaisonSheet extends StatefulWidget {
  const _ChoixMaisonSheet();

  @override
  State<_ChoixMaisonSheet> createState() => _ChoixMaisonSheetState();
}

class _ChoixMaisonSheetState extends State<_ChoixMaisonSheet> {
  final SearchService _service = SearchService();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  StreamSubscription<List<SearchResult>>? _rechercheSub;
  List<String> _suggestionsCategories = [];
  List<SearchResult> _resultats = [];
  bool _rechercheEnCours = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_surSaisie);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _rechercheSub?.cancel();
    _controller.removeListener(_surSaisie);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _surSaisie() {
    final texte = _controller.text.trim();
    setState(() {
      _suggestionsCategories = _service.suggestionsCategories(texte);
    });

    _debounce?.cancel();
    if (texte.length < 2) {
      _rechercheSub?.cancel();
      _rechercheSub = null;
      setState(() {
        _resultats = [];
        _rechercheEnCours = false;
      });
      return;
    }

    setState(() => _rechercheEnCours = true);
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _rechercheSub?.cancel();
      _rechercheSub = _service.rechercherLieu(texte).listen((resultats) {
        if (!mounted) return;
        if (_controller.text.trim() != texte) return;
        setState(() {
          _resultats = resultats;
          _rechercheEnCours = false;
        });
      }, onError: (_) {
        if (!mounted) return;
        setState(() => _rechercheEnCours = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final couleur = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.home, color: couleur.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Enregistrer comme maison',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Rechercher un lieu (Kinshasa ou ailleurs)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(children: _enfants(couleur)),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _enfants(ColorScheme couleur) {
    final enfants = <Widget>[];

    if (_suggestionsCategories.isNotEmpty) {
      enfants.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Suggestions',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: couleur.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
      for (final s in _suggestionsCategories) {
        enfants.add(
          ListTile(
            leading: const Icon(Icons.search),
            title: Text(s),
            onTap: () {
              _controller.text = s;
              _controller.selection =
                  TextSelection.collapsed(offset: s.length);
            },
          ),
        );
      }
      enfants.add(const Divider(height: 8));
    }

    if (_rechercheEnCours && _resultats.isEmpty) {
      enfants.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else {
      for (final r in _resultats) {
        enfants.add(
          ListTile(
            leading: const Icon(Icons.location_on, color: Colors.green),
            title: Text(r.nom),
            subtitle: r.sousTitre.isEmpty
                ? null
                : Text(
                    r.sousTitre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => Navigator.pop(context, r),
          ),
        );
      }
      if (_resultats.isEmpty && _suggestionsCategories.isEmpty) {
        enfants.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'Aucun lieu trouvé.',
                style: TextStyle(color: couleur.onSurface.withValues(alpha: 0.6)),
              ),
            ),
          ),
        );
      }
    }

    return enfants;
  }
}
