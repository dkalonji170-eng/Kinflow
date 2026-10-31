import 'package:shared_preferences/shared_preferences.dart';

/// Série de jours d'activité : nombre de jours consécutifs où la personne a
/// utilisé KinFlow.
///
/// Calculée localement (aucune requête, aucun quota) à partir de la date de
/// la dernière utilisation enregistrée. Elle donne un motif de revenir chaque
/// jour sans rien promettre que l'app ne puisse tenir hors ligne.
class SerieActivite {
  SerieActivite._();

  static final SerieActivite instance = SerieActivite._();

  static const String _cleSerie = 'kinflow_serie_activite';
  static const String _cleMeilleure = 'kinflow_meilleure_serie_activite';
  static const String _cleDernierJour = 'kinflow_serie_activite_dernier_jour';

  int _serie = 0;
  int _meilleure = 0;

  /// Série en cours, en jours (0 tant que l'app n'a jamais été ouverte).
  int get serie => _serie;

  /// Meilleure série jamais atteinte.
  int get meilleure => _meilleure;

  /// Recharge la série depuis le disque et l'expire si elle est cassée
  /// (dernière activité antérieure à hier).
  Future<void> charger() async {
    final prefs = await SharedPreferences.getInstance();
    _serie = prefs.getInt(_cleSerie) ?? 0;
    _meilleure = prefs.getInt(_cleMeilleure) ?? 0;
    final ecart = _ecartJours(prefs.getString(_cleDernierJour));
    if (ecart != null && ecart > 1) {
      _serie = 0;
      await prefs.setInt(_cleSerie, 0);
    }
  }

  /// Enregistre une activité du jour et renvoie la série à jour.
  /// Une seconde activité le même jour ne fait pas monter la série.
  Future<int> marquerActivite() async {
    final prefs = await SharedPreferences.getInstance();
    final aujourdHui = _aujourdHui();
    final dernier = prefs.getString(_cleDernierJour);
    final ecart = _ecartJours(dernier);

    if (dernier == aujourdHui) {
      // Déjà compté aujourd'hui : la série ne bouge pas.
      if (_serie == 0) {
        _serie = 1;
        await prefs.setInt(_cleSerie, _serie);
      }
      return _serie;
    }

    if (ecart == 1) {
      _serie = (_serie <= 0 ? 1 : _serie) + 1;
    } else {
      _serie = 1;
    }

    if (_serie > _meilleure) {
      _meilleure = _serie;
      await prefs.setInt(_cleMeilleure, _meilleure);
    }
    await prefs.setInt(_cleSerie, _serie);
    await prefs.setString(_cleDernierJour, aujourdHui);
    return _serie;
  }

  /// Vrai si l'activité du jour est déjà comptée.
  Future<bool> tenueAujourdHui() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cleDernierJour) == _aujourdHui();
  }

  // --- Dates : on ne compare que des jours, jamais des heures ---------------

  static String _aujourdHui() => _formater(DateTime.now());

  static String _formater(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  static DateTime? _lireJour(String? valeur) {
    if (valeur == null || valeur.isEmpty) return null;
    final morceaux = valeur.split('-');
    if (morceaux.length != 3) return null;
    final annee = int.tryParse(morceaux[0]);
    final mois = int.tryParse(morceaux[1]);
    final jour = int.tryParse(morceaux[2]);
    if (annee == null || mois == null || jour == null) return null;
    return DateTime(annee, mois, jour);
  }

  /// Nombre de jours écoulés depuis [jour] (null si la date est illisible).
  static int? _ecartJours(String? jour) {
    final date = _lireJour(jour);
    if (date == null) return null;
    final maintenant = DateTime.now();
    final auj = DateTime(maintenant.year, maintenant.month, maintenant.day);
    return auj.difference(date).inDays;
  }
}
