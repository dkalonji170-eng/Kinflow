import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../models/information_ville.dart';
import 'crash_reporter.dart';
import 'diagnostics_service.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._();
  factory SupabaseService() => _instance;
  SupabaseService._();

  static const Duration _timeout = Duration(seconds: 20);

  Completer<void>? _initCompleter;
  Object? _initError;
  String? _derniereErreur;

  bool get isInitialized =>
      (_initCompleter?.isCompleted ?? false) && _initError == null;

  Object? get initError => _initError;

  /// Dernière erreur détaillée rencontrée lors d'une opération.
  String? get derniereErreur => _derniereErreur;

  /// Attend la fin de l'initialisation (succès ou échec) sans lever d'erreur.
  Future<void> get ready {
    final completer = _initCompleter;
    if (completer == null) return init();
    return completer.future;
  }

  Future<void> init() async {
    final existing = _initCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<void>();
    _initCompleter = completer;

    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.anonKey,
      ).timeout(_timeout);
      Journal.s('SUPABASE', 'Connexion au serveur établie');
      await _signInAnonymously();
    } catch (e, st) {
      _initError = e;
      Journal.e('SUPABASE', 'Échec de connexion au serveur', {'erreur': '$e'});
      debugPrint('[KinFlow] Erreur Supabase: $e');
      reportCrash('Supabase', e, st);
    }

    if (!completer.isCompleted) completer.complete();
    return completer.future;
  }

  SupabaseClient? get _client {
    if (_initError != null || !(_initCompleter?.isCompleted ?? false)) {
      return null;
    }
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<void> _signInAnonymously() async {
    final client = _client;
    if (client == null) return;
    try {
      final session = client.auth.currentSession;
      if (session == null) {
        await client.auth.signInAnonymously().timeout(_timeout);
      }
    } catch (e, st) {
      debugPrint('[KinFlow] Erreur connexion anonyme: $e');
      Journal.e('SUPABASE', 'Identité anonyme refusée par le serveur',
          {'erreur': '$e'});
      reportCrash('AuthAnonyme', e, st);
    }
  }

  Future<void> ensureSignedIn() async {
    await _signInAnonymously();
  }

  String? get userId => _client?.auth.currentUser?.id;
  bool get isSignedIn => _client?.auth.currentSession != null;

  Future<bool> saveProfile({
    required String nom,
    required String prenom,
    String sexe = '',
    String date = '',
    String telephone = '',
    String email = '',
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      final id = userId;
      if (client == null || id == null) {
        _derniereErreur =
            'Supabase non initialisé ou identité anonyme absente.';
        return false;
      }
      await client.from('profiles').upsert({
        'id': id,
        'nom': nom,
        'prenom': prenom,
        'sexe': sexe,
        'date': date,
        'telephone': telephone,
        'email': email,
      }).timeout(_timeout);
      Journal.s('PROFIL', 'Profil enregistré sur le serveur', {'nom': nom});
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur saveProfile: $_derniereErreur');
      Journal.e('PROFIL', 'Enregistrement du profil refusé',
          {'erreur': _derniereErreur});
      return false;
    }
  }

  /// Formate le message d'une erreur Supabase pour le débogage.
  String _detailErreur(Object e) {
    try {
      final postgrest = e as PostgrestException;
      return '${postgrest.message} (${postgrest.code})';
    } catch (_) {}
    try {
      final auth = e as AuthException;
      return auth.message;
    } catch (_) {}
    if (e is TimeoutException) {
      return 'Le serveur met trop de temps à répondre. Vérifiez votre connexion internet puis réessayez.';
    }
    if (e is http.ClientException) {
      return 'Problème de connexion réseau. Vérifiez votre internet puis réessayez.';
    }
    return e.toString();
  }

  Future<Map<String, dynamic>?> loadProfile() async {
    final client = _client;
    if (client == null) return null;
    try {
      final id = client.auth.currentUser?.id;
      if (id == null) return null;
      final response = await client
          .from('profiles')
          .select()
          .eq('id', id)
          .maybeSingle()
          .timeout(_timeout);
      return response;
    } catch (e) {
      debugPrint('[KinFlow] Erreur loadProfile: $e');
      Journal.a('PROFIL', 'Lecture du profil impossible', {'erreur': '$e'});
      return null;
    }
  }

  /// Enregistre le thème (mode sombre) du compte connecté.
  /// Retourne false si aucun compte n'est lié à l'identité actuelle.
  Future<bool> saveTheme(bool sombre) async {
    try {
      await ready;
      final client = _client;
      final id = userId;
      if (client == null || id == null) return false;
      await client
          .from('profiles')
          .update({'mode_sombre': sombre})
          .eq('id', id)
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur saveTheme: $_derniereErreur');
      Journal.a('REGLAGES', 'Thème non enregistré sur le serveur',
          {'erreur': _derniereErreur});
      return false;
    }
  }

  /// Enregistre un nouveau profil et lui attribue un code.
  /// Retourne le code généré, ou null en cas d'échec.
  Future<String?> enregistrerAvecCode({
    required String nom,
    required String prenom,
    String sexe = '',
    String date = '',
    String telephone = '',
    String email = '',
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      final id = userId;
      if (client == null || id == null) {
        _derniereErreur =
            'Supabase non initialisé ou identité anonyme absente.';
        return null;
      }

      final code = await _genererCodeUnique();
      if (code == null) return null;

      await client.from('profiles').upsert({
        'id': id,
        'nom': nom,
        'prenom': prenom,
        'sexe': sexe,
        'date': date,
        'telephone': telephone,
        'email': email,
        'code': code,
      }).timeout(_timeout);
      Journal.s('PROFIL', 'Nouveau compte créé', {'code_attribue': code});
      return code;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur enregistrement: $_derniereErreur');
      Journal.e('PROFIL', 'Création du compte refusée',
          {'erreur': _derniereErreur});
      return null;
    }
  }

  /// Connecte un compte existant à l'aide de son nom et de son code :
  /// le profil correspondant est adopté sous l'identité anonyme actuelle.
  /// Retourne le profil, ou null si le nom ou le code est introuvable.
  Future<Map<String, dynamic>?> connecterAvecCode(
    String codeSaisi, {
    String nom = '',
  }) async {
    try {
      await ensureSignedIn();
      final client = _client;
      final id = userId;
      if (client == null || id == null) {
        _derniereErreur =
            'Supabase non initialisé ou identité anonyme absente.';
        return null;
      }

      final code = codeSaisi.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      if (code.isEmpty) {
        _derniereErreur = 'Code vide.';
        return null;
      }
      final nomNettoye = nom.trim();

      // Adoption du profil via une fonction RPC SECURITY DEFINER côté
      // Supabase : elle vérifie le code et le nom, puis transfère le profil
      // sous l'identité anonyme actuelle sans dépendre des politiques RLS.
      final result = await client
          .rpc('adopter_profil', params: {'code_saisi': code, 'nom_saisi': nomNettoye})
          .timeout(_timeout);
      if (result == null) {
        _derniereErreur = 'Nom ou code incorrect.';
        Journal.a('CONNEXION', 'Connexion refusée : nom ou code incorrect', {
          'nom': nomNettoye,
        });
        return null;
      }
      Journal.s('CONNEXION', 'Connexion réussie', {
        'nom': nomNettoye,
      });
      return (result as Map).cast<String, dynamic>();
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur connexion par code: $_derniereErreur');
      Journal.e('CONNEXION', 'Erreur pendant la connexion',
          {'erreur': _derniereErreur});
      return null;
    }
  }

  Future<String?> _genererCodeUnique() async {
    final client = _client;
    if (client == null) {
      _derniereErreur = 'Supabase non initialisé.';
      return null;
    }
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    for (var tentative = 0; tentative < 8; tentative++) {
      final code = List.generate(
        8,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      try {
        // La vérification passe par une fonction SECURITY DEFINER pour
        // fonctionner même lorsque RLS est active sur profiles.
        final dispo = await client
            .rpc('code_unique_disponible', params: {'p_code': code})
            .timeout(_timeout);
        if (dispo == true) return code;
      } catch (e) {
        // Repli : si la fonction n'existe pas encore (migration non lancée),
        // on retombe sur la lecture directe (marche sans RLS).
        try {
          final existant = await client
              .from('profiles')
              .select('code')
              .eq('code', code)
              .maybeSingle()
              .timeout(_timeout);
          if (existant == null) return code;
        } catch (e2) {
          _derniereErreur =
              'Impossible de générer le code (${_detailErreur(e2)}). '
              'Vérifiez que la colonne "code" existe dans la table profiles.';
          debugPrint('[KinFlow] Erreur génération code: $e2');
          return null;
        }
      }
    }
    _derniereErreur = 'Impossible de générer un code.';
    return null;
  }

  /// Dépose un signalement d'état de route (état + position + cap).
  Future<bool> signalerEtat({
    required String etat,
    required double latitude,
    required double longitude,
    double? cap,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) {
        _derniereErreur = 'Supabase non initialisé.';
        return false;
      }
      final ok = await client
          .rpc('signaler_etat', params: {
            'p_etat': etat,
            'p_latitude': latitude,
            'p_longitude': longitude,
            'p_cap': cap,
          })
          .timeout(_timeout);
      if (ok != true) {
        Journal.a('SUPABASE', 'Le serveur a refusé le signalement');
      }
      return ok == true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur signalerEtat: $_derniereErreur');
      Journal.e('SIGNALEMENT', 'Envoi du signalement échoué',
          {'erreur': _derniereErreur});
      return false;
    }
  }

  /// Signalements récents (60 min) : liste anonyme d'états avec positions.
  Future<List<Map<String, dynamic>>> chargerSignalementsRecents() async {
    final client = _client;
    if (client == null) return const [];
    try {
      final resultat = await client.rpc('signalements_recents').timeout(_timeout);
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargerSignalementsRecents: $e');
      Journal.a('CARTE', 'Signalements récents indisponibles',
          {'erreur': '$e'});
      return const [];
    }
  }

  /// Le fil de la ville : les informations publiées par KinFlow avec les
  /// compteurs VERT/ROUGE et la propre réaction du visiteur.
  /// Vide si la connexion échoue (l'écran réessaie).
  Future<List<InformationVille>> chargerFilInformations() async {
    final client = _client;
    if (client == null) return const [];
    try {
      final resultat = await client.rpc('fil_informations').timeout(_timeout);
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) InformationVille.depuisJson(e.cast<String, dynamic>()),
      ];
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargerFilInformations: $e');
      Journal.a('FIL', 'Fil de la ville indisponible', {'erreur': '$e'});
      return const [];
    }
  }

  /// Réagit à une information ('VERT' ou 'ROUGE'). Retaper la même couleur
  /// retire la réaction ; taper l'autre couleur la remplace.
  /// Retourne le nouvel état ('VERT' ou 'ROUGE'), ou null si la réaction a
  /// été retirée — ou bien en cas d'échec (serveur/réseau).
  Future<String?> reagirInformation(String informationId, String sens) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('reagir_information', params: {
            'p_id': informationId,
            'p_sens': sens,
          })
          .timeout(_timeout);
      final sensResultat = resultat is String ? resultat : null;
      if (sensResultat == null) {
        Journal.a('FIL', 'Réaction retirée ou absente',
            {'information': informationId});
      } else {
        Journal.s('FIL', 'Réaction enregistrée',
            {'information': informationId, 'sens': sensResultat});
      }
      return sensResultat;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur reagirInformation: $_derniereErreur');
      Journal.e('FIL', 'Réaction échouée', {'erreur': _derniereErreur});
      return null;
    }
  }

  /// Réagit à un émoji sur une information : le pose s'il n'existe pas,
  /// le retire s'il existe déjà (bascule). Retourne true si la bascule a
  /// réussi, null en cas d'échec serveur/réseau.
  Future<bool?> reagirEmoji(String informationId, String emoji) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('reagir_emoji', params: {
            'p_id': informationId,
            'p_emoji': emoji,
          })
          .timeout(_timeout);
      if (resultat is bool) {
        Journal.s('FIL', 'Émoji enregistré',
            {'information': informationId, 'emoji': emoji});
        return resultat;
      }
      return null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur reagirEmoji: $_derniereErreur');
      Journal.e('FIL', 'Émoji échoué', {'erreur': _derniereErreur});
      return null;
    }
  }

  /// Clé locale de la dernière visite du Fil Social — partagée entre
  /// l'accueil (badge) et l'écran Social (points rouges).
  static const String cleDernierVuFil = 'fil_social_dernier_vu';

  Future<DateTime?> lireDernierVuFil() async {
    final prefs = await SharedPreferences.getInstance();
    final valeur = prefs.getString(cleDernierVuFil);
    if (valeur == null) return null;
    return DateTime.tryParse(valeur);
  }

  Future<void> marquerFilVu() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cleDernierVuFil, DateTime.now().toIso8601String());
  }

  /// Nombre d'infos publiées après la date donnée — pour le badge rouge de
  /// l'accueil. 0 en cas d'échec (le badge reste discret).
  Future<int> compterNouvellesInfos(DateTime? depuis) async {
    try {
      final client = _client;
      if (client == null) return 0;
      final resultat = await client
          .rpc('compter_infos_recentes', params: {
            'p_depuis': depuis?.toUtc().toIso8601String(),
          })
          .timeout(_timeout);
      return (resultat as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('[KinFlow] Erreur compterNouvellesInfos: $e');
      return 0;
    }
  }

  Future<void> signOut() async {
    final client = _client;
    if (client == null) return;
    try {
      await client.auth.signOut().timeout(_timeout);
    } catch (e) {
      debugPrint('[KinFlow] Erreur signOut: $e');
    }
  }
}
