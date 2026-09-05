import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_result.dart';
import '../services/diagnostics_service.dart';
import '../services/search_service.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const int _nombreRecentes = 2;

  final SearchService _service = SearchService();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  StreamSubscription<List<SearchResult>>? _rechercheSub;
  List<SearchResult> _recentes = [];
  List<String> _suggestionsCategories = [];
  List<SearchResult> _resultats = [];
  bool _rechercheEnCours = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_surSaisie);
    _chargerRecentes();
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
            hintText: 'Rechercher un lieu à Kinshasa',
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

  Widget _vueRecentes() {
    if (_recentes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search,
              size: 48,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              'Cherchez un lieu de Kinshasa.\n'
              'Vos 2 dernières recherches apparaîtront ici.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Recherches récentes',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
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
