import 'dart:async';

import 'supabase_service.dart';

/// Cache des grades (rangs) par identifiant d'utilisateur.
///
/// Le grade est affiché sur l'avatar animal partout dans l'app (liste d'amis,
/// carte, audio, discussion…) et en grand quand on touche l'icône. Sans cache,
/// chaque reconstruction d'un avatar relancerait un appel
/// `rang_signalements_utilisateur` ; ici une seule requête est faite par
/// personne, puis le rang complet est gardé en mémoire.
///
/// Un échec réseau n'est pas réessayé immédiatement : on attend
/// [_delaiApresEchec] avant de retenter, pour ne pas marteler le serveur
/// lorsque l'appareil est hors ligne.
class RangService {
  RangService._();

  static final RangService instance = RangService._();

  static const Duration _delaiApresEchec = Duration(minutes: 2);

  /// Nombre maximum de requêtes simultanées : une liste d'amis peut afficher
  /// des dizaines d'avatars d'un coup, on évite de saturer le réseau.
  static const int _maxSimultanees = 3;

  final Map<String, Map<String, dynamic>> _rangs = {};
  final Map<String, Future<Map<String, dynamic>?>> _chargements = {};
  final Map<String, DateTime> _prochainEssai = {};
  final List<void Function()> _attente = [];
  int _actives = 0;

  /// Rang complet déjà connu (nom, niveau, compteur, progression…), ou null.
  Map<String, dynamic>? rang(String userId) => _rangs[userId];

  /// Niveau déjà connu (1..8), ou null si pas encore chargé.
  int? niveau(String userId) {
    final brut = _rangs[userId]?['niveau'];
    if (brut is! num) return null;
    return brut.toInt().clamp(1, 8);
  }

  /// Charge le niveau d'un utilisateur, avec cache et déduplication.
  Future<int?> charger(String userId) async {
    final rang = await chargerRang(userId);
    final brut = rang?['niveau'];
    if (brut is! num) return null;
    return brut.toInt().clamp(1, 8);
  }

  /// Charge le rang complet d'un utilisateur. Les appels concurrents pour la
  /// même personne partagent la même requête.
  Future<Map<String, dynamic>?> chargerRang(String userId) {
    if (userId.isEmpty) return Future<Map<String, dynamic>?>.value();
    final connu = _rangs[userId];
    if (connu != null) return Future<Map<String, dynamic>?>.value(connu);

    final prochain = _prochainEssai[userId];
    if (prochain != null && DateTime.now().isBefore(prochain)) {
      return Future<Map<String, dynamic>?>.value();
    }

    final enCours = _chargements[userId];
    if (enCours != null) return enCours;

    final futur = _planifier(userId);
    _chargements[userId] = futur;
    return futur.whenComplete(() => _chargements.remove(userId));
  }

  /// Met la requête en file si trop de chargements sont déjà en cours.
  Future<Map<String, dynamic>?> _planifier(String userId) {
    final completer = Completer<Map<String, dynamic>?>();
    void lancer() {
      _actives++;
      _charger(userId)
          .then((rang) {
            if (!completer.isCompleted) completer.complete(rang);
          })
          .catchError((Object _) {
            if (!completer.isCompleted) completer.complete(null);
            return null;
          })
          .whenComplete(() {
            _actives--;
            _demarrerSuivants();
          });
    }

    if (_actives < _maxSimultanees) {
      lancer();
    } else {
      _attente.add(lancer);
    }
    return completer.future;
  }

  void _demarrerSuivants() {
    while (_actives < _maxSimultanees && _attente.isNotEmpty) {
      _attente.removeAt(0)();
    }
  }

  /// Précharge plusieurs rangs en parallèle (liste d'amis, marqueurs carte).
  void precharger(Iterable<String> userIds) {
    for (final id in userIds) {
      if (id.isEmpty || _rangs.containsKey(id)) continue;
      unawaited(chargerRang(id));
    }
  }

  Future<Map<String, dynamic>?> _charger(String userId) async {
    final rang = await SupabaseService().rangSignalementsUtilisateur(userId);
    if (rang == null || rang['niveau'] is! num) {
      _prochainEssai[userId] = DateTime.now().add(_delaiApresEchec);
      return null;
    }
    _rangs[userId] = rang;
    _prochainEssai.remove(userId);
    return rang;
  }
}
