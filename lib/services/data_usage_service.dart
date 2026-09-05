import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Catégorie fonctionnelle d'une consommation de données réseau.
///
/// Chaque grande fonction de l'application qui consomme des méga-octets est
/// classée ici pour pouvoir dire « l'itinéraire m'a coûté X Mo », « les
/// cartes m'ont coûté Y Mo », etc.
enum CategorieData {
  /// Tuiles de carte (chargement en naviguant, téléchargement hors ligne,
  /// préchargement).
  cartes('Cartes'),

  /// Calcul d'itinéraire OSRM (dont la géométrie des polylignes).
  itineraire('Itinéraire'),

  /// Recherche de lieux, géocodage inverse et voies proches
  /// (Photon, Nominatim, Overpass).
  recherche('Recherche'),

  /// Connexion au serveur KinFlow : identité, profil, réglages, signalements
  /// d'état de route (Supabase).
  connexion('Connexion');

  const CategorieData(this.libelle);

  final String libelle;
}

/// Compteur de consommation de données par catégorie de fonction.
///
/// Mesure en octets ce que chaque fonction de l'application a réellement
/// téléchargé (parse les réponses) et envoyé (requêtes), puis l'affiche en
/// méga-octets. Persiste les totaux sur disque ([SharedPreferences]) pour
/// garder l'historique entre deux lancements.
class DataUsageService extends ChangeNotifier {
  DataUsageService._() {
    _charger();
  }

  static final DataUsageService instance = DataUsageService._();

  static const String _cleStockage = 'kinflow_data_usage_v1';

  /// Totaux cumulés par catégorie, en octets reçus.
  final Map<CategorieData, int> _octetsRecus = {};

  /// Totaux cumulés par catégorie, en octets envoyés (requêtes).
  final Map<CategorieData, int> _octetsEnvoyes = {};

  bool _chargementEffectue = false;

  /// Octets reçus (téléchargés) pour une catégorie.
  int octetsRecusPour(CategorieData categorie) => _octetsRecus[categorie] ?? 0;

  /// Octets envoyés (requêtes) pour une catégorie.
  int octetsEnvoyesPour(CategorieData categorie) =>
      _octetsEnvoyes[categorie] ?? 0;

  /// Total de téléchargé (reçu), toutes catégories confondues, en octets.
  int get totalOctetsRecus => _octetsRecus.values.fold(0, (a, b) => a + b);

  /// Total d'envoyé, toutes catégories confondues, en octets.
  int get totalOctetsEnvoyes => _octetsEnvoyes.values.fold(0, (a, b) => a + b);

  /// Enregistre la consommation d'une fonction réseau.
  ///
  /// [octetsRecus] = taille de la réponse téléchargée (l'essentiel du
  /// forfait), [octetsEnvoyes] = taille de la requête émise.
  void enregistrer(
    CategorieData categorie, {
    int octetsRecus = 0,
    int octetsEnvoyes = 0,
  }) {
    if (octetsRecus > 0) {
      _octetsRecus[categorie] = (octetsRecusPour(categorie) + octetsRecus);
    }
    if (octetsEnvoyes > 0) {
      _octetsEnvoyes[categorie] = (octetsEnvoyesPour(categorie) + octetsEnvoyes);
    }
    _planifierSauvegarde();
    _notifier();
    if (octetsRecus > 0 || octetsEnvoyes > 0) {
      // Trace temporaire de diagnostic : la consommation de chaque service
      // apparaît en direct dans la console, cumulée depuis l'ouverture.
      debugPrint(
        '[CONSO DATA] ${categorie.libelle.padRight(12)} '
        '↓ ${enMo(octetsRecusPour(categorie))} '
        '↑ ${enMo(octetsEnvoyesPour(categorie))} '
        '| total ↓ ${enMo(totalOctetsRecus)} '
        '↑ ${enMo(totalOctetsEnvoyes)}',
      );
    }
  }

  /// Remet tous les compteurs à zéro (nouveau départ).
  Future<void> reinitialiser() async {
    _octetsRecus.clear();
    _octetsEnvoyes.clear();
    _notifier();
    await _sauvegarder();
  }

  // ---------------------------------------------------------------------
  // Lecture / persistance
  // ---------------------------------------------------------------------

  void _notifier() {
    _minuterieNotification ??= Future<void>.delayed(
      const Duration(milliseconds: 80),
      () {
        _minuterieNotification = null;
        notifyListeners();
      },
    );
  }

  Future<void>? _minuterieNotification;

  Future<void> _charger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _chargementEffectue = true;
      final brut = prefs.getString(_cleStockage);
      if (brut == null || brut.isEmpty) return;
      final donnees = json.decode(brut);
      if (donnees is! Map) return;
      final recus = donnees['recus'];
      final envoyes = donnees['envoyes'];
      if (recus is Map) {
        for (final e in recus.entries) {
          final c = _categorieDe(e.key);
          if (c == null || e.value is! int) continue;
          _octetsRecus[c] = e.value as int;
        }
      }
      if (envoyes is Map) {
        for (final e in envoyes.entries) {
          final c = _categorieDe(e.key);
          if (c == null || e.value is! int) continue;
          _octetsEnvoyes[c] = e.value as int;
        }
      }
      _notifier();
    } catch (_) {
      _chargementEffectue = true;
    }
  }

  CategorieData? _categorieDe(String nom) {
    for (final c in CategorieData.values) {
      if (c.name == nom) return c;
    }
    return null;
  }

  Timer? _minuterieSauvegarde;

  void _planifierSauvegarde() {
    _minuterieSauvegarde ??= Timer(
      const Duration(seconds: 3),
      () {
        _minuterieSauvegarde = null;
        _sauvegarder();
      },
    );
  }

  Future<void> _sauvegarder() async {
    if (!_chargementEffectue) {
      // Attendre que la restauration ait lu l'ancien contenu avant d'écrire,
      // sinon on écraserait les compteurs précédents trop tôt.
      _planifierSauvegarde();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cleStockage,
        json.encode({
          'recus': {
            for (final e in _octetsRecus.entries) e.key.name: e.value,
          },
          'envoyes': {
            for (final e in _octetsEnvoyes.entries) e.key.name: e.value,
          },
        }),
      );
    } catch (_) {
      // Le stockage peut être indisponible : le compteur reste en mémoire.
    }
  }

  /// Formate un nombre d'octets en chaîne lisible en méga-octets
  /// (avec une décimale quand c'est pertinent), ex. « 2,4 Mo ».
  static String enMo(int octets) {
    if (octets >= 1024 * 1024) {
      final mo = octets / (1024 * 1024);
      return '${mo.toStringAsFixed(mo >= 10 ? 1 : 2)} Mo';
    }
    if (octets >= 1024) {
      return '${(octets / 1024).toStringAsFixed(1)} Ko';
    }
    return '$octets o';
  }
}

/// Effectue des requêtes HTTP en comptabilisant automatiquement les octets
/// consommés dans la catégorie de fonction indiquée.
///
/// Le corps téléchargé ([http.Response.bodyBytes]) constitue l'essentiel de
/// la consommation : il est compté en « reçu ». Le corps envoyé (méthodes
/// POST avec body) est compté en « envoyé ». Les en-têtes, négligeables au
/// regard des corps, ne sont pas rapportés (cela garde la mesure lisible en
/// Mo et en faibles octets).
class HttpMeter {
  /// Effectue une requête GET et compte la consommation dans [categorie].
  static Future<http.Response> get(
    CategorieData categorie,
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) {
    final requete = http.Request('GET', Uri.parse(url))
      ..headers.addAll(headers ?? const {});
    return _executer(categorie, requete, timeout: timeout);
  }

  /// Effectue une requête POST avec [body] (Map encodé en application/x-www-
  /// form-urlencoded si [encode] est vrai, sinon JSON de la Map) et compte la
  /// consommation dans [categorie].
  static Future<http.Response> post(
    CategorieData categorie,
    String url, {
    Map<String, String>? headers,
    Object? body,
    bool encode = false,
    Duration? timeout,
  }) {
    final requete = http.Request('POST', Uri.parse(url))
      ..headers.addAll(headers ?? const {});
    if (body != null) {
      if (encode) {
        requete.headers['Content-Type'] =
            'application/x-www-form-urlencoded';
        requete.body = (body as Map).entries
            .map((e) =>
                '${Uri.encodeComponent('${e.key}')}='
                '${Uri.encodeComponent('${e.value}')}')
            .join('&');
      } else if (body is String) {
        requete.body = body;
      } else {
        requete.headers['Content-Type'] = 'application/json';
        requete.body = json.encode(body);
      }
    }
    return _executer(categorie, requete, timeout: timeout);
  }

  /// Exécute la requête, mesure les octets et les attribue à [categorie].
  static Future<http.Response> _executer(
    CategorieData categorie,
    http.Request requete, {
    Duration? timeout,
  }) async {
    final envoyes = _octetsEnvoi(requete);
    final client = http.Client();
    try {
      final future = client.send(requete).then(http.Response.fromStream);
      final reponse = timeout == null
          ? await future
          : await future.timeout(timeout);
      DataUsageService.instance.enregistrer(
        categorie,
        octetsRecus: reponse.bodyBytes.length,
        octetsEnvoyes: envoyes,
      );
      return reponse;
    } finally {
      client.close();
    }
  }

  static int _octetsEnvoi(http.Request requete) {
    final body = requete.body;
    final tailleCorps = body.isEmpty ? 0 : utf8.encode(body).length;
    // Version très légère des en-têtes courants (User-Agent, Content-Type).
    const tailleEnTetes = 128;
    return tailleCorps + tailleEnTetes;
  }
}

