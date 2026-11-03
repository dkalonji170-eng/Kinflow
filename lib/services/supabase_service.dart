import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../models/information_ville.dart';
import '../models/commentaire.dart';
import '../models/publication.dart';
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

  // Backoff des appels d'amis (polling toutes les 10 s côté écrans). Quand le
  // serveur est injoignable (hors ligne, DNS mort), on espace les tentatives
  // au lieu de marteler le réseau et de saturer le journal.
  int _echecsAmisConsecutifs = 0;
  DateTime? _prochainEssaiAmis;
  int _echecsDemandesConsecutifs = 0;
  DateTime? _prochainEssaiDemandes;

  /// Backoff exponentiel : 10 s, 20 s, 40 s… plafonné à 60 s.
  Duration _calculerBackoff(int echecs) {
    final exposant = (echecs - 1).clamp(0, 4).toInt();
    final secondes = 10 * (1 << exposant);
    return Duration(seconds: secondes > 60 ? 60 : secondes);
  }

  bool get isInitialized =>
      (_initCompleter?.isCompleted ?? false) && _initError == null;

  Object? get initError => _initError;

  /// Dernière erreur détaillée rencontrée lors d'une opération.
  String? get derniereErreur => _derniereErreur;

  /// Attend la fin de l'initialisation (succès ou échec) sans lever d'erreur.
  /// Si une tentative précédente a échoué (souvent une simple coupure réseau au
  /// démarrage), on relance l'initialisation au lieu de rester bloqué sans
  /// session jusqu'au prochain redémarrage de l'application.
  Future<void> get ready {
    final completer = _initCompleter;
    if (completer == null || _initError != null) return init();
    return completer.future;
  }

  Future<void> init() async {
    final existing = _initCompleter;
    if (existing != null) {
      // Succès déjà acquis : rien à refaire. Échec précédent : on retente.
      if (!existing.isCompleted || _initError == null) return existing.future;
    }

    final completer = Completer<void>();
    _initCompleter = completer;
    _initError = null;

    try {
      // `Supabase.instance` lève une exception tant que l'instance n'est pas
      // prête : on évite ainsi un second `Supabase.initialize` (interdit) lors
      // d'une nouvelle tentative.
      if (!_instancePrete) {
        await Supabase.initialize(
          url: SupabaseConfig.url,
          publishableKey: SupabaseConfig.anonKey,
        ).timeout(_timeout);
        Journal.s('SUPABASE', 'Connexion au serveur établie');
      }
    } catch (e, st) {
      // L'instance a pu être initialisée malgré le dépassement de délai : dans
      // ce cas elle est utilisable et on ne considère pas l'init comme échouée.
      if (!_instancePrete) {
        _initError = e;
        Journal.e('SUPABASE', 'Échec de connexion au serveur', {
          'erreur': '$e',
        });
        debugPrint('[KinFlow] Erreur Supabase: $e');
        reportCrash('Supabase', e, st);
        if (!completer.isCompleted) completer.complete();
        return completer.future;
      }
    }

    await _signInAnonymously();

    if (!completer.isCompleted) completer.complete();
    return completer.future;
  }

  /// Vrai si l'instance globale Supabase est utilisable (déjà initialisée).
  bool get _instancePrete {
    try {
      Supabase.instance.client;
      return true;
    } catch (_) {
      return false;
    }
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
    if (client.auth.currentSession != null) return;
    // Deux tentatives : la première peut échouer sur un réseau capricieux, la
    // seconde (après une courte pause) suffit souvent à rétablir la session.
    for (var tentative = 0; tentative < 2; tentative++) {
      try {
        await client.auth.signInAnonymously().timeout(_timeout);
        return;
      } catch (e, st) {
        debugPrint(
          '[KinFlow] Erreur connexion anonyme (essai ${tentative + 1}): $e',
        );
        Journal.e('SUPABASE', 'Identité anonyme refusée par le serveur', {
          'erreur': '$e',
        });
        reportCrash('AuthAnonyme', e, st);
        if (tentative == 0) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
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
    String avatar = '',
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      final id = userId;
      if (client == null || id == null) {
        _derniereErreur =
            'Pas de connexion au serveur. Vérifie ton réseau puis réessaie.';
        return false;
      }
      await _avecReessai(
        () => client
            .from('profiles')
            .upsert({
              'id': id,
              'nom': nom,
              'prenom': prenom,
              'sexe': sexe,
              'date': date,
              'telephone': telephone,
              'email': email,
              'avatar': avatar,
            })
            .timeout(_timeout),
      );
      Journal.s('PROFIL', 'Profil enregistré sur le serveur', {'nom': nom});
      try {
        await marquerCompteLie(nom: nom, prenom: prenom, avatar: avatar);
      } catch (_) {}
      // Met à jour le cache local pour un affichage instantané (on conserve
      // les champs gérés par le serveur, comme le code de compte et l'id).
      try {
        final cache = await chargerProfilCache() ?? <String, dynamic>{};
        cache.addAll({
          'nom': nom,
          'prenom': prenom,
          'sexe': sexe,
          'date': date,
          'telephone': telephone,
          'email': email,
          'avatar': avatar,
        });
        await sauverProfilCache(cache);
      } catch (_) {}
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur saveProfile: $_derniereErreur');
      Journal.e('PROFIL', 'Enregistrement du profil refusé', {
        'erreur': _derniereErreur,
      });
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
    if (e is StorageException) {
      final texte = '${e.message} ${e.error ?? ''}'.toLowerCase();
      if (texte.contains('bucket not found') ||
          texte.contains('nosuchbucket')) {
        return 'Stockage des médias non configuré sur le serveur '
            '(bucket manquant).';
      }
      if (texte.contains('row-level security') ||
          texte.contains('accessdenied') ||
          texte.contains('unauthorized')) {
        return 'Envoi refusé par le stockage. Vérifie que tu es bien '
            'connecté, puis réessaie.';
      }
      if (texte.contains('too large') || texte.contains('payload')) {
        return 'Cette photo est trop lourde pour le serveur.';
      }
      return e.message;
    }
    if (e is TimeoutException) {
      return 'Le serveur met trop de temps à répondre. Vérifie ta connexion internet puis réessaie.';
    }
    if (_estErreurReseau(e)) {
      return 'Problème de connexion réseau. Vérifie ton internet puis réessaie.';
    }
    return e.toString();
  }

  /// Reconnaît les erreurs réseau/TLS (qui arrivent surtout au redémarrage de
  /// l'app ou sur un Wi-Fi capricieux) pour afficher un message lisible plutôt
  /// qu'un texte technique du type « HandshakeException ».
  bool _estErreurReseau(Object e) {
    if (e is http.ClientException) return true;
    final texte = e.toString();
    return texte.contains('HandshakeException') ||
        texte.contains('SocketException') ||
        texte.contains('ClientException') ||
        texte.contains('Connection terminated') ||
        texte.contains('Connection closed') ||
        texte.contains('Connection reset') ||
        texte.contains('Connection refused') ||
        texte.contains('Failed host lookup') ||
        texte.contains('Network is unreachable') ||
        texte.contains('Software caused connection abort');
  }

  /// Rejoue [action] une fois si elle échoue sur une erreur réseau : ces
  /// erreurs sont souvent transitoires (poignée de main TLS interrompue…).
  Future<T> _avecReessai<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      if (!_estErreurReseau(e)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      return await action();
    }
  }

  Future<Map<String, dynamic>?> loadProfile() async {
    final client = _client;
    try {
      final id = client?.auth.currentUser?.id;
      if (client != null && id != null) {
        final response = await client
            .from('profiles')
            .select()
            .eq('id', id)
            .maybeSingle()
            .timeout(_timeout);
        if (response != null) {
          // Cache local : permet un affichage instantané au prochain accès.
          await sauverProfilCache(response);
          return response;
        }
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur loadProfile: $e');
      Journal.a('PROFIL', 'Lecture du profil impossible', {'erreur': '$e'});
    }
    // Repli hors connexion : on rend le profil mis en cache local.
    return chargerProfilCache();
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
      Journal.a('REGLAGES', 'Thème non enregistré sur le serveur', {
        'erreur': _derniereErreur,
      });
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
    String avatar = '',
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      final id = userId;
      if (client == null || id == null) {
        _derniereErreur =
            'Pas de connexion au serveur. Vérifie ton réseau puis réessaie.';
        return null;
      }

      final code = await _genererCodeUnique();
      if (code == null) return null;

      await _avecReessai(
        () => client
            .from('profiles')
            .upsert({
              'id': id,
              'nom': nom,
              'prenom': prenom,
              'sexe': sexe,
              'date': date,
              'telephone': telephone,
              'email': email,
              'avatar': avatar,
              'code': code,
            })
            .timeout(_timeout),
      );
      Journal.s('PROFIL', 'Nouveau compte créé', {'code_attribue': code});
      try {
        await marquerCompteLie(
          nom: nom,
          prenom: prenom,
          avatar: avatar,
          code: code,
        );
      } catch (_) {}
      return code;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur enregistrement: $_derniereErreur');
      Journal.e('PROFIL', 'Création du compte refusée', {
        'erreur': _derniereErreur,
      });
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
            'Pas de connexion au serveur. Vérifie ton réseau puis réessaie.';
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
      final result = await _avecReessai(
        () => client
            .rpc(
              'adopter_profil',
              params: {'code_saisi': code, 'nom_saisi': nomNettoye},
            )
            .timeout(_timeout),
      );

      if (result is Map) {
        final map = result.cast<String, dynamic>();
        if (map['erreur'] == 'trop_de_tentatives') {
          _derniereErreur =
              'Trop de tentatives. Réessayez dans quelques minutes.';
          Journal.a('CONNEXION', 'Adoption bloquée par rate limiting', {
            'retry_after_secondes': map['retry_after_secondes'],
          });
          return null;
        }
        Journal.s('CONNEXION', 'Connexion réussie', {'nom': nomNettoye});
        final profilMap = map;
        try {
          await marquerCompteLie(
            nom: (profilMap['nom'] as String? ?? nomNettoye).trim(),
            prenom: (profilMap['prenom'] as String? ?? '').trim(),
            avatar: (profilMap['avatar'] as String? ?? ''),
            code: (profilMap['code'] as String? ?? code).trim(),
          );
        } catch (_) {}
        return profilMap;
      }

      if (result == null) {
        _derniereErreur = 'Nom ou code incorrect.';
        Journal.a('CONNEXION', 'Connexion refusée : nom ou code incorrect', {
          'nom': nomNettoye,
        });
        return null;
      }

      _derniereErreur = 'Nom ou code incorrect.';
      Journal.a('CONNEXION', 'Connexion refusée : nom ou code incorrect', {
        'nom': nomNettoye,
      });
      return null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur connexion par code: $_derniereErreur');
      Journal.e('CONNEXION', 'Erreur pendant la connexion', {
        'erreur': _derniereErreur,
      });
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
          .rpc(
            'signaler_etat',
            params: {
              'p_etat': etat,
              'p_latitude': latitude,
              'p_longitude': longitude,
              'p_cap': cap,
            },
          )
          .timeout(_timeout);
      if (ok != true) {
        Journal.a('SUPABASE', 'Le serveur a refusé le signalement');
      }
      return ok == true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur signalerEtat: $_derniereErreur');
      Journal.e('SIGNALEMENT', 'Envoi du signalement échoué', {
        'erreur': _derniereErreur,
      });
      return false;
    }
  }

  /// Signalements récents (60 min) : liste anonyme d'états avec positions.
  Future<List<Map<String, dynamic>>> chargerSignalementsRecents() async {
    final client = _client;
    if (client == null) return const [];
    try {
      final resultat = await client
          .rpc('signalements_recents')
          .timeout(_timeout);
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargerSignalementsRecents: $e');
      Journal.a('CARTE', 'Signalements récents indisponibles', {
        'erreur': '$e',
      });
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

  /// Valeur renvoyée quand une réaction a bien été retirée.
  ///
  /// La fonction SQL renvoie `null` à la fois pour un retrait réussi et pour
  /// une erreur, ce qui empêchait l'interface d'annuler un retrait optimiste
  /// quand le réseau échouait. On utilise donc un sentinelle côté client :
  /// `null` = échec, [reactionAucune] = retrait confirmé.
  static const String reactionAucune = 'AUCUNE';

  /// Réagit à une information ('VERT' ou 'ROUGE'). Retaper la même couleur
  /// retire la réaction ; taper l'autre couleur la remplace.
  /// Retourne le nouvel état ('VERT' ou 'ROUGE'), [reactionAucune] si la
  /// réaction a été retirée, ou null en cas d'échec (serveur/réseau).
  Future<String?> reagirInformation(String informationId, String sens) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'reagir_information',
            params: {'p_id': informationId, 'p_sens': sens},
          )
          .timeout(_timeout);
      final sensResultat = resultat is String ? resultat : reactionAucune;
      if (sensResultat == reactionAucune) {
        Journal.s('FIL', 'Réaction retirée', {'information': informationId});
      } else {
        Journal.s('FIL', 'Réaction enregistrée', {
          'information': informationId,
          'sens': sensResultat,
        });
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
          .rpc(
            'reagir_emoji',
            params: {'p_id': informationId, 'p_emoji': emoji},
          )
          .timeout(_timeout);
      if (resultat == true) {
        Journal.s('FIL', 'Émoji enregistré', {
          'information': informationId,
          'emoji': emoji,
        });
        return true;
      }
      // `false` = emoji refusé (info inconnue, session absente…). On le traite
      // comme un échec pour que l'interface annule la bascule optimiste.
      _derniereErreur = 'émoji refusé par le serveur';
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

  /// Cache local du compte lié à cet appareil : permet d'ouvrir directement
  /// l'application même si la session Supabase n'est pas restaurée à chaud.
  static const String cleCompteLie = 'kinflow_compte_lie';
  static const String cleCompteNom = 'kinflow_compte_nom';
  static const String cleComptePrenom = 'kinflow_compte_prenom';
  static const String cleCompteAvatar = 'kinflow_compte_avatar';
  static const String cleCompteCode = 'kinflow_compte_code';

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

  /// Marque localement que cet appareil est lié à un compte existant.
  Future<void> marquerCompteLie({
    required String nom,
    required String prenom,
    String avatar = '',
    String code = '',
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(cleCompteLie, true);
      await prefs.setString(cleCompteNom, nom.trim());
      await prefs.setString(cleComptePrenom, prenom.trim());
      await prefs.setString(cleCompteAvatar, avatar);
      await prefs.setString(cleCompteCode, code);
    } catch (_) {}
  }

  /// Indique si un compte est déjà lié à cet appareil (cache local).
  Future<bool> estCompteLie() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(cleCompteLie) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Lit les infos du compte lié depuis le cache local.
  Future<Map<String, String>> lireCompteLieLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return {
        'nom': prefs.getString(cleCompteNom) ?? '',
        'prenom': prefs.getString(cleComptePrenom) ?? '',
        'avatar': prefs.getString(cleCompteAvatar) ?? '',
        'code': prefs.getString(cleCompteCode) ?? '',
      };
    } catch (_) {
      return {'nom': '', 'prenom': '', 'avatar': '', 'code': ''};
    }
  }

  /// Efface le cache local du compte lié (après déconnexion).
  Future<void> effacerCompteLieLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(cleCompteLie);
      await prefs.remove(cleCompteNom);
      await prefs.remove(cleComptePrenom);
      await prefs.remove(cleCompteAvatar);
      await prefs.remove(cleCompteCode);
      await prefs.remove(cleCacheProfil);
      // On garde les surnoms d'amis sur l'appareil (comme un contact du
      // téléphone) : ils doivent survivre à une déconnexion / reconnexion du
      // même compte. Un surnom n'est appliqué qu'à un(e) ami(e) réel(le) de
      // la liste du compte, donc rien ne fuite d'un compte à l'autre.
    } catch (_) {}
  }

  // --- Surnoms locaux des amis ----------------------------------------------

  /// Un surnom personnalisé par ami(e), conservé sur cet appareil (comme le
  /// nom d'un contact dans le téléphone). Le serveur n'en garde aucune trace :
  /// seul l'affichage local est modifié.
  static const String _prefixeSurnomAmi = 'surnom_ami_';

  /// Enregistre le surnom local d'un ami(e). Un surnom vide l'efface et
  /// rétablit le nom d'origine.
  Future<void> definirSurnomAmi(String amiId, String surnom) async {
    if (amiId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cle = '$_prefixeSurnomAmi$amiId';
      final propre = surnom.trim();
      if (propre.isEmpty) {
        await prefs.remove(cle);
      } else {
        await prefs.setString(cle, propre);
      }
    } catch (_) {}
  }

  /// Surnom local d'un ami(e), ou null s'il n'y en a pas.
  Future<String?> surnomAmi(String amiId) async {
    if (amiId.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final valeur = prefs.getString('$_prefixeSurnomAmi$amiId');
      return (valeur == null || valeur.isEmpty) ? null : valeur;
    } catch (_) {
      return null;
    }
  }

  /// Tous les surnoms enregistrés sur cet appareil (ami_id → surnom).
  Future<Map<String, String>> chargerSurnomsAmis() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final resultat = <String, String>{};
      for (final cle in prefs.getKeys()) {
        if (!cle.startsWith(_prefixeSurnomAmi)) continue;
        final valeur = prefs.getString(cle);
        if (valeur != null && valeur.isNotEmpty) {
          resultat[cle.substring(_prefixeSurnomAmi.length)] = valeur;
        }
      }
      return resultat;
    } catch (_) {
      return {};
    }
  }

  /// Renvoie une copie de [amis] où chaque ami(e) renommé(e) affiche son
  /// surnom : le prénom devient le surnom et le nom est vidé pour éviter
  /// « Surnom AncienNom ». La liste d'origine (pour le cache) reste intacte.
  List<Map<String, dynamic>> appliquerSurnomsAmis(
    List<Map<String, dynamic>> amis,
    Map<String, String> surnoms,
  ) {
    if (surnoms.isEmpty) return amis;
    return [
      for (final ami in amis)
        if (surnoms[ami['ami_id']] != null)
          {...ami, 'prenom': surnoms[ami['ami_id']], 'nom': ''}
        else
          ami,
    ];
  }

  // --- Cache du profil ------------------------------------------------------

  /// Profil complet mis en cache local : il s'affiche **instantanément** à
  /// l'ouverture de « Mon profil » (petit animal), même sans connexion.
  static const String cleCacheProfil = 'kinflow_cache_profil';

  /// Enregistre le profil complet dans le cache local.
  Future<void> sauverProfilCache(Map<String, dynamic> profil) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(cleCacheProfil, jsonEncode(profil));
    } catch (_) {}
  }

  /// Lit le profil complet depuis le cache local (null s'il n'y en a pas).
  Future<Map<String, dynamic>?> chargerProfilCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final brut = prefs.getString(cleCacheProfil);
      if (brut == null || brut.isEmpty) return null;
      final valeur = jsonDecode(brut);
      return valeur is Map ? Map<String, dynamic>.from(valeur) : null;
    } catch (_) {
      return null;
    }
  }

  // --- Caches hors ligne (fil d'infos + amis) -------------------------------

  static const String cleCacheInfos = 'kinflow_cache_infos_fil';
  static const String cleCacheAmis = 'kinflow_cache_amis';

  /// Durée de vie d'une information dans le fil, alignée sur le serveur :
  /// `fil_informations` ne renvoie que les 48 dernières heures (plus les
  /// épinglées, qui ne disparaissent jamais). Le cache applique la même
  /// fenêtre : une info déjà lue reste disponible hors connexion **jusqu'à sa
  /// disparition**, puis est retirée.
  static const Duration dureeVieInfos = Duration(hours: 48);

  /// Durée de vie d'un message dans une discussion, alignée sur le serveur :
  /// `mes_messages_ami` ne renvoie que les 7 derniers jours. Le cache garde les
  /// messages lus **jusqu'à leur disparition** (7 jours), puis les retire.
  static const Duration dureeVieMessages = Duration(days: 7);

  /// Vrai tant qu'une information est dans la fenêtre du fil : moins de 48 h,
  /// ou épinglée (les épinglées ne disparaissent pas).
  static bool informationActive(InformationVille info, {DateTime? maintenant}) {
    if (info.epinglee) return true;
    final reference = maintenant ?? DateTime.now();
    return reference.difference(info.creeA) < dureeVieInfos;
  }

  /// Vrai tant qu'un message est dans la fenêtre de la discussion (7 jours).
  /// Un message sans date connue est conservé par prudence.
  static bool messageActif(
    Map<String, dynamic> message, {
    DateTime? maintenant,
  }) {
    final brut = message['cree_a'];
    if (brut == null) return true;
    final cree = DateTime.tryParse(brut.toString());
    if (cree == null) return true;
    final reference = maintenant ?? DateTime.now();
    return reference.difference(cree.toLocal()) < dureeVieMessages;
  }

  /// Sauvegarde le fil d'informations dans le cache local : il reste visible
  /// au prochain lancement même sans connexion.
  Future<void> sauverInfosCache(List<InformationVille> infos) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // On n'écrit que les informations encore dans la fenêtre : les info
      // « disparues » (> 48 h, non épinglées) sont retirées du cache.
      final actives = [
        for (final i in infos)
          if (informationActive(i)) i,
      ];
      final json = jsonEncode([for (final i in actives) i.toJson()]);
      await prefs.setString(cleCacheInfos, json);
    } catch (_) {}
  }

  /// Charge le fil d'informations depuis le cache local, en écartant celles
  /// qui ont dépassé la fenêtre de 48 h (elles ont « disparu »).
  Future<List<InformationVille>> chargerInfosCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final brut = prefs.getString(cleCacheInfos);
      if (brut == null || brut.isEmpty) return const [];
      final liste = jsonDecode(brut);
      if (liste is! List) return const [];
      final infos = [
        for (final e in liste)
          if (e is Map)
            InformationVille.depuisJson(Map<String, dynamic>.from(e)),
      ];
      return [
        for (final i in infos)
          if (informationActive(i)) i,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Sauvegarde la liste d'amis (et demandes, code, compteurs, aperçus) dans le
  /// cache local pour un affichage immédiat, même hors connexion.
  Future<void> sauverAmisCache({
    required List<Map<String, dynamic>> amis,
    required List<Map<String, dynamic>> demandes,
    required String codeAmi,
    required Map<String, int> nonLus,
    required Map<String, Map<String, dynamic>> apercus,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode({
        'amis': amis,
        'demandes': demandes,
        'code_ami': codeAmi,
        'non_lus': nonLus,
        'apercus': apercus,
      });
      await prefs.setString(cleCacheAmis, json);
    } catch (_) {}
  }

  /// Charge le cache local des amis. Retourne null si aucun cache.
  Future<Map<String, dynamic>?> chargerAmisCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final brut = prefs.getString(cleCacheAmis);
      if (brut == null || brut.isEmpty) return null;
      final objet = jsonDecode(brut);
      if (objet is! Map) return null;
      return Map<String, dynamic>.from(objet);
    } catch (_) {
      return null;
    }
  }

  /// Met à jour uniquement la partie « amis » du cache local, en conservant le
  /// reste (demandes, code, compteurs). Utilisé par la carte, qui ne charge
  /// que les positions.
  Future<void> majCacheAmis(List<Map<String, dynamic>> amis) async {
    if (amis.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final existant = prefs.getString(cleCacheAmis);
      var base = <String, dynamic>{};
      if (existant != null && existant.isNotEmpty) {
        final objet = jsonDecode(existant);
        if (objet is Map) base = Map<String, dynamic>.from(objet);
      }
      base['amis'] = amis;
      await prefs.setString(cleCacheAmis, jsonEncode(base));
    } catch (_) {}
  }

  /// Préfixe des caches de discussion : un cache par ami(e), pour afficher la
  /// conversation instantanément (même hors connexion) au lieu d'attendre le
  /// réseau, parfois très lent.
  static const String _prefixeCacheMessages = 'kinflow_cache_msgs_';

  String _cleCacheMessages(String amiId) => '$_prefixeCacheMessages$amiId';

  /// Sauvegarde la discussion d'un(e) ami(e) dans le cache local. Seuls les
  /// messages encore dans la fenêtre de 7 jours sont conservés : ils restent
  /// lisibles **jusqu'à leur disparition**, puis sont écartés.
  Future<void> sauverMessagesCache(
    String amiId,
    List<Map<String, dynamic>> messages,
  ) async {
    if (amiId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final actifs = [
        for (final m in messages)
          if (messageActif(m)) m,
      ];
      await prefs.setString(_cleCacheMessages(amiId), jsonEncode(actifs));
    } catch (_) {}
  }

  /// Charge la discussion d'un(e) ami(e) depuis le cache local, en écartant
  /// les messages de plus de 7 jours (ils ont « disparu » côté serveur).
  Future<List<Map<String, dynamic>>> chargerMessagesCache(String amiId) async {
    if (amiId.isEmpty) return const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final brut = prefs.getString(_cleCacheMessages(amiId));
      if (brut == null || brut.isEmpty) return const [];
      final liste = jsonDecode(brut);
      if (liste is! List) return const [];
      final messages = [
        for (final e in liste)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
      return [
        for (final m in messages)
          if (messageActif(m)) m,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Efface les caches hors ligne (après déconnexion).
  Future<void> effacerCachesHorsLigne() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(cleCacheInfos);
      await prefs.remove(cleCacheAmis);
      await prefs.remove(cleCacheProfil);
      // Discussions : une clé par ami(e), on les retrouve par préfixe.
      for (final cle in prefs.getKeys().toList()) {
        if (cle.startsWith(_prefixeCacheMessages)) {
          await prefs.remove(cle);
        }
      }
    } catch (_) {}
  }

  /// Nombre d'infos publiées après la date donnée — pour le badge rouge de
  /// l'accueil. 0 en cas d'échec (le badge reste discret).
  Future<int> compterNouvellesInfos(DateTime? depuis) async {
    try {
      // Attendre l'initialisation : au démarrage, l'accueil interroge le
      // compteur avant que le client Supabase ne soit prêt ; sans cette
      // attente la requête repartait à 0 et le badge ne s'affichait jamais.
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return 0;
      final resultat = await client
          .rpc(
            'compter_infos_recentes',
            params: {'p_depuis': depuis?.toUtc().toIso8601String()},
          )
          .timeout(_timeout);
      return (resultat as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('[KinFlow] Erreur compterNouvellesInfos: $e');
      return 0;
    }
  }

  // --- Amis(es) -------------------------------------------------------------
  // Le lien entre deux personnes passe par le CODE unique du profil (celui
  // déjà utilisé pour se reconnecter). Toutes les opérations passent par des
  // fonctions SECURITY DEFINER côté Supabase (voir migration _amities.sql).

  /// Normalise un code saisi : majuscules, sans tirets ni espaces. Le serveur
  /// compare ensuite directement ce code à `profiles.code_ami`.
  static String _normaliserCode(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Mon code AMI (public, partageable), ou null si indisponible. À ne pas
  /// confondre avec le code de compte ([loadProfile] → 'code'), qui reste
  /// secret car il sert à se reconnecter.
  Future<String?> monCodeAmi() async {
    await ready;
    final client = _client;
    if (client == null) return null;
    try {
      final resultat = await client.rpc('mon_code_ami').timeout(_timeout);
      return resultat is String ? resultat : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur monCodeAmi: $_derniereErreur');
      return null;
    }
  }

  /// Cherche un profil par son code AMI. Retourne {prenom, nom, avatar}, ou
  /// null si aucun profil ne porte ce code (ou en cas d'échec).
  Future<Map<String, dynamic>?> chercherProfilParCode(String code) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('chercher_profil', params: {'p_code': _normaliserCode(code)})
          .timeout(_timeout);
      final ligne = resultat is List && resultat.isNotEmpty
          ? resultat.first
          : null;
      if (ligne is Map) return ligne.cast<String, dynamic>();
      return null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur chercherProfilParCode: $_derniereErreur');
      return null;
    }
  }

  /// Envoie une demande d'amitié à partir d'un code AMI. Retourne le code
  /// résultat du serveur : 'envoye', 'accepte', 'deja_ami', 'deja_envoye',
  /// 'introuvable', 'soi_meme', 'code_invalide', 'non_connecte' — ou null en
  /// cas d'échec réseau/serveur.
  Future<String?> envoyerDemandeAmi(String code) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('envoyer_demande_ami', params: {'p_code': _normaliserCode(code)})
          .timeout(_timeout);
      final codeResultat = resultat is String ? resultat : null;
      Journal.a('AMIS', 'Demande d\'ami envoyée', {'resultat': codeResultat});
      return codeResultat;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur envoyerDemandeAmi: $_derniereErreur');
      Journal.e('AMIS', 'Envoi de la demande échoué', {
        'erreur': _derniereErreur,
      });
      return null;
    }
  }

  /// Demandes d'amitié reçues et encore en attente. En cas d'échec répété
  /// (hors ligne), un backoff espace les tentatives et limite les logs.
  Future<List<Map<String, dynamic>>> mesDemandesAmis() async {
    await ready;
    final client = _client;
    if (client == null) return const [];

    final maintenant = DateTime.now();
    final prochain = _prochainEssaiDemandes;
    if (prochain != null && maintenant.isBefore(prochain)) {
      return const []; // En pleine temporisation : on n'insiste pas.
    }

    try {
      final resultat = await client.rpc('mes_demandes_amis').timeout(_timeout);
      _echecsDemandesConsecutifs = 0;
      _prochainEssaiDemandes = null;
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      _echecsDemandesConsecutifs++;
      final attente = _calculerBackoff(_echecsDemandesConsecutifs);
      _prochainEssaiDemandes = DateTime.now().add(attente);
      if (_echecsDemandesConsecutifs == 1 ||
          _echecsDemandesConsecutifs % 6 == 0) {
        Journal.a('AMIS', 'Demandes d\'amis indisponibles', {
          'erreur': '$e',
          'echecs_consecutifs': _echecsDemandesConsecutifs,
          'prochain_essai_dans_s': attente.inSeconds,
        });
      }
      debugPrint(
        '[KinFlow] Erreur mesDemandesAmis (#$_echecsDemandesConsecutifs): $e',
      );
      return const [];
    }
  }

  /// Accepte ou refuse une demande reçue. Retourne true si la mise à jour a
  /// été appliquée.
  Future<bool> repondreDemandeAmi(String id, bool accepter) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final resultat = await client
          .rpc(
            'repondre_demande_ami',
            params: {'p_id': id, 'p_accepter': accepter},
          )
          .timeout(_timeout);
      final ok = resultat == true;
      if (ok) {
        Journal.s('AMIS', accepter ? 'Demande acceptée' : 'Demande refusée');
      }
      return ok;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur repondreDemandeAmi: $_derniereErreur');
      Journal.e('AMIS', 'Réponse à la demande échouée', {
        'erreur': _derniereErreur,
      });
      return false;
    }
  }

  /// Mes amis(es). Chaque entrée contient ami_id, prenom, nom, avatar, et la
  /// position (latitude/longitude/cap/maj_a) si le partage est actif. Même si
  /// la position est ancienne (téléphone éteint depuis longtemps), maj_a est
  /// renvoyée pour permettre « il y a … » sur la carte. Si le partage est
  /// désactivé, latitude/longitude valent null.
  ///
  /// En cas d'échec réseau/serveur, un backoff exponentiel espace les
  /// tentatives (10 s → 60 s) et le log n'est écrit que pour la première
  /// panne puis une fois sur six : hors ligne, l'appel cesse de solliciter le
  /// réseau toutes les 10 s et ne sature plus le journal.
  Future<List<Map<String, dynamic>>> mesAmis() async {
    await ready;
    final client = _client;
    if (client == null) return const [];

    final maintenant = DateTime.now();
    final prochain = _prochainEssaiAmis;
    if (prochain != null && maintenant.isBefore(prochain)) {
      return const []; // En pleine temporisation : on n'insiste pas.
    }

    try {
      final resultat = await client.rpc('mes_amis').timeout(_timeout);
      _echecsAmisConsecutifs = 0;
      _prochainEssaiAmis = null;
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      _echecsAmisConsecutifs++;
      final attente = _calculerBackoff(_echecsAmisConsecutifs);
      _prochainEssaiAmis = maintenant.add(attente);
      if (_echecsAmisConsecutifs == 1 || _echecsAmisConsecutifs % 6 == 0) {
        Journal.a('AMIS', 'Liste d\'amis indisponible', {
          'erreur': '$e',
          'echecs_consecutifs': _echecsAmisConsecutifs,
          'prochain_essai_dans_s': attente.inSeconds,
        });
      }
      debugPrint('[KinFlow] Erreur mesAmis (#$_echecsAmisConsecutifs): $e');
      return const [];
    }
  }

  /// Envoie une information KinFlow à un ami(e). Retourne 'envoye' en cas de
  /// succès, sinon un code d'erreur ('pas_ami', 'contenu_vide', ...), ou null
  /// en cas d'échec réseau/serveur.
  Future<String?> envoyerInfoAmi({
    required String amiId,
    required String contenu,
    String? sourceUrl,
    String? informationId,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'envoyer_info_ami',
            params: {
              'p_ami_id': amiId,
              'p_contenu': contenu,
              'p_source_url': sourceUrl,
              'p_information_id': informationId,
            },
          )
          .timeout(_timeout);
      return resultat is String ? resultat : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur envoyerInfoAmi: $_derniereErreur');
      Journal.e('AMIS', 'Envoi d\'info échoué', {'erreur': _derniereErreur});
      return null;
    }
  }

  /// Informations reçues de mes amis(es), les plus récentes d'abord. Chaque
  /// entrée : id, expediteur, prenom, nom, avatar, contenu, source_url,
  /// cree_a, lu.
  Future<List<Map<String, dynamic>>> mesInfosRecues() async {
    await ready;
    final client = _client;
    if (client == null) return const [];
    try {
      final resultat = await client.rpc('mes_infos_recues').timeout(_timeout);
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      debugPrint('[KinFlow] Erreur mesInfosRecues: $e');
      Journal.a('AMIS', 'Informations reçues indisponibles', {'erreur': '$e'});
      return const [];
    }
  }

  /// Marque toutes mes informations reçues comme lues.
  Future<bool> marquerInfosRecuesVues() async {
    await ready;
    final client = _client;
    if (client == null) return false;
    try {
      final resultat = await client
          .rpc('marquer_infos_recues_vues')
          .timeout(_timeout);
      return resultat == true;
    } catch (e) {
      debugPrint('[KinFlow] Erreur marquerInfosRecuesVues: $e');
      return false;
    }
  }

  /// Envoie un message privé à un ami(e) (durée de vie : 7 jours). Retourne
  /// 'envoye' ou un code d'erreur ('pas_ami', 'contenu_vide', ...).
  ///
  /// [audioFormes] : forme d'onde du vocal (0..100, une valeur par barre),
  /// stockée avec le message pour être redessinée chez le destinataire.
  ///
  /// [repondreA] : identifiant du message auquel celui-ci répond. On enregistre
  /// la RÉFÉRENCE (pas une copie du texte) : l'aperçu est reconstruit à
  /// l'affichage, et le message cité peut donc être modifié sans la casser.
  Future<String?> envoyerMessageAmi({
    required String amiId,
    required String contenu,
    String? audioChemin,
    int? audioDureeMs,
    List<int>? audioFormes,
    String? imageChemin,
    String? repondreA,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'envoyer_message_ami',
            params: {
              'p_ami_id': amiId,
              'p_contenu': contenu,
              if (audioChemin != null && audioChemin.isNotEmpty)
                'p_audio_chemin': audioChemin,
              'p_audio_duree_ms': ?audioDureeMs,
              if (audioFormes != null && audioFormes.isNotEmpty)
                'p_audio_formes': audioFormes,
              if (imageChemin != null && imageChemin.isNotEmpty)
                'p_image_chemin': imageChemin,
              if (repondreA != null && repondreA.isNotEmpty)
                'p_reply_to_message_id': repondreA,
            },
          )
          .timeout(_timeout);
      return resultat is String ? resultat : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur envoyerMessageAmi: $_derniereErreur');
      return null;
    }
  }

  /// Modifie le texte d'un message déjà envoyé (appui long → « Modifier »).
  /// Seul l'expéditeur peut le faire, et seulement pour un message texte.
  /// Retourne 'modifie' ou un code d'erreur ('pas_autorise',
  /// 'vocal_non_modifiable', ...).
  Future<String?> modifierMessageAmi({
    required String messageId,
    required String contenu,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'modifier_message',
            params: {'p_message_id': messageId, 'p_contenu': contenu},
          )
          .timeout(_timeout);
      return resultat is String ? resultat : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur modifierMessageAmi: $_derniereErreur');
      return null;
    }
  }

  /// Supprime un message (appui long → « Supprimer »). Pour l'expéditeur c'est
  /// définitif des deux côtés (l'audio du vocal et la photo sont retirés du
  /// bucket) ; pour le destinataire le message n'est masqué que de son propre
  /// fil.
  /// Retourne 'supprime' ou un code d'erreur ('pas_autorise', ...).
  /// [audioChemin] / [imageChemin] : chemins dans les buckets, retirés du
  /// Storage après une suppression réussie (droits garantis par la politique
  /// de suppression, contrairement à la tentative SQL du RPC).
  Future<String?> supprimerMessageAmi(
    String messageId, {
    String? audioChemin,
    String? imageChemin,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('supprimer_message', params: {'p_message_id': messageId})
          .timeout(_timeout);
      if (resultat == 'supprime') {
        if (audioChemin != null && audioChemin.isNotEmpty) {
          try {
            await client.storage
                .from('messages_vocaux')
                .remove([audioChemin])
                .timeout(_timeout);
          } catch (e) {
            // Fichier orphelin : le message est déjà supprimé, on ne bloque pas.
            debugPrint('[KinFlow] Audio vocal non supprimé du bucket: $e');
          }
        }
        if (imageChemin != null && imageChemin.isNotEmpty) {
          try {
            await client.storage
                .from('messages_images')
                .remove([imageChemin])
                .timeout(_timeout);
          } catch (e) {
            debugPrint('[KinFlow] Photo non supprimée du bucket: $e');
          }
        }
      }
      return resultat is String ? resultat : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur supprimerMessageAmi: $_derniereErreur');
      return null;
    }
  }

  Future<String?> televerserVocal({
    required String amiId,
    required List<int> octets,
    required String extension,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final uid = client.auth.currentUser?.id;
      if (uid == null) return null;
      final chemin =
          '$uid/$amiId/vocal_${DateTime.now().microsecondsSinceEpoch}.$extension';
      await client.storage
          .from('messages_vocaux')
          .uploadBinary(
            chemin,
            Uint8List.fromList(octets),
            fileOptions: const FileOptions(
              contentType: 'audio/mp4',
              upsert: false,
            ),
          )
          .timeout(const Duration(seconds: 60));
      return chemin;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur televerserVocal: $_derniereErreur');
      return null;
    }
  }

  Future<String?> urlVocalSignee(String chemin) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final url = await client.storage
          .from('messages_vocaux')
          .createSignedUrl(chemin, 3600)
          .timeout(_timeout);
      return url;
    } catch (e) {
      debugPrint('[KinFlow] Erreur urlVocalSignee: $e');
      return null;
    }
  }

  // --- Photos des messages privés -------------------------------------------

  /// Téléverse une photo dans le bucket privé `messages_images` et retourne son
  /// chemin (dossier 1 = moi, dossier 2 = l'ami(e), comme les vocaux). Null en
  /// cas d'échec (hors ligne, droits, quota…).
  Future<String?> televerserImage({
    required String amiId,
    required List<int> octets,
    required String extension,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final uid = client.auth.currentUser?.id;
      if (uid == null) return null;
      final ext = extension.toLowerCase().replaceAll('.', '');
      final contentType = switch (ext) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        'heic' => 'image/heic',
        _ => 'image/jpeg',
      };
      final chemin =
          '$uid/$amiId/image_${DateTime.now().microsecondsSinceEpoch}.'
          '${ext.isEmpty ? 'jpg' : ext}';
      await client.storage
          .from('messages_images')
          .uploadBinary(
            chemin,
            Uint8List.fromList(octets),
            fileOptions: FileOptions(contentType: contentType, upsert: false),
          )
          .timeout(const Duration(seconds: 60));
      return chemin;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur televerserImage: $_derniereErreur');
      return null;
    }
  }

  /// URL signée (1 h) d'une photo de message. Null si le fichier n'est pas
  /// accessible (supprimé, droits, hors ligne).
  Future<String?> urlImageSignee(String chemin) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final url = await client.storage
          .from('messages_images')
          .createSignedUrl(chemin, 3600)
          .timeout(_timeout);
      return url;
    } catch (e) {
      debugPrint('[KinFlow] Erreur urlImageSignee: $e');
      return null;
    }
  }

  /// Tague un(e) ami(e) sur une information : crée un message système dans la
  /// discussion qui pointe vers l'information. Retourne 'envoye' ou un code
  /// d'erreur ('pas_ami', 'info_introuvable', ...).
  Future<String?> taguerInformationAmi({
    required String amiId,
    required String infoId,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'taguer_information',
            params: {'p_ami_id': amiId, 'p_info_id': infoId},
          )
          .timeout(_timeout);
      return resultat is String ? resultat : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur taguerInformationAmi: $_derniereErreur');
      return null;
    }
  }

  /// La discussion (7 derniers jours) avec un ami(e), du plus ancien au plus
  /// récent. Chaque entrée : id, expediteur, contenu, cree_a, moi.
  Future<List<Map<String, dynamic>>> mesMessagesAmi(String amiId) async {
    await ready;
    final client = _client;
    if (client == null) return const [];
    try {
      final resultat = await client
          .rpc('mes_messages_ami', params: {'p_ami_id': amiId})
          .timeout(_timeout);
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      debugPrint('[KinFlow] Erreur mesMessagesAmi: $e');
      return const [];
    }
  }

  /// Autorise (ou non) un(e) ami(e) à me localiser en mode simple, à tout
  /// moment. Révoquable à volonté. Retourne true si l'état a été enregistré.
  Future<bool> definirAutorisationLocSimple(
    String amiId,
    bool autoriser,
  ) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final resultat = await client
          .rpc(
            'definir_autorisation_loc_simple',
            params: {'p_ami_id': amiId, 'p_autoriser': autoriser},
          )
          .timeout(_timeout);
      final ok = resultat == true;
      if (ok) {
        Journal.s('AMIS', 'Autorisation de localisation modifiée', {
          'autoriser': autoriser,
        });
      }
      return ok;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint(
        '[KinFlow] Erreur definirAutorisationLocSimple: $_derniereErreur',
      );
      return false;
    }
  }

  /// Renouvelle la localisation d'urgence qu'un(e) ami(e) peut encore utiliser
  /// pour me localiser (une seule fois, une fois consommée). C'est la personne
  /// localisée qui renouvelle. Retourne true si l'état a été enregistré.
  Future<bool> renouvelerUrgence(String amiId) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final resultat = await client
          .rpc('renouveler_urgence', params: {'p_ami_id': amiId})
          .timeout(_timeout);
      final ok = resultat == true;
      if (ok) Journal.s('AMIS', 'Localisation d\'urgence renouvelée');
      return ok;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur renouvelerUrgence: $_derniereErreur');
      return false;
    }
  }

  /// État des autorisations de localisation avec un(e) ami(e). Renvoie une
  /// table avec, entre autres, [ami_autorise_moi_loc_simple] (l'ami(e) m'a
  /// autorisé), [moi_autorise_ami_loc_simple] (je l'ai autorisé),
  /// [urgence_dispo_pour_moi_localiser_ami] (il me reste une urgence) et
  /// [urgence_dispo_pour_ami_localiser_moi]. Retourne null en cas d'échec.
  Future<Map<String, dynamic>?> etatAutorisationsLocalisation(
    String amiId,
  ) async {
    await ready;
    final client = _client;
    if (client == null) return null;
    try {
      final resultat = await client
          .rpc('etat_autorisations_localisation', params: {'p_ami_id': amiId})
          .timeout(_timeout);
      if (resultat is Map) {
        final map = resultat.cast<String, dynamic>();
        if (map['ok'] == true) return Map<String, dynamic>.from(map);
      }
      return null;
    } catch (e) {
      debugPrint('[KinFlow] Erreur etatAutorisationsLocalisation: $e');
      return null;
    }
  }

  /// Localise un(e) ami(e) en mode simple (nécessite son autorisation).
  /// Retourne {ok:true, latitude, longitude, cap, maj_a, message} ou
  /// {ok:false, erreur:...}. Null en cas d'échec réseau/serveur.
  Future<Map<String, dynamic>?> localiserSimple(String amiId) =>
      _localiser('localiser_simple', amiId);

  /// Localise un(e) ami(e) en urgence (consomme l'urgence disponible).
  /// Même forme de retour que [localiserSimple].
  Future<Map<String, dynamic>?> localiserUrgence(String amiId) =>
      _localiser('localiser_urgence', amiId);

  Future<Map<String, dynamic>?> _localiser(
    String fonction,
    String amiId,
  ) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(fonction, params: {'p_ami_id': amiId})
          .timeout(_timeout);
      if (resultat is Map) return resultat.cast<String, dynamic>();
      return null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur $fonction: $_derniereErreur');
      return null;
    }
  }

  /// Signale un problème (mur collaboratif).
  Future<String?> signalerProbleme(String type, String description) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'signaler_probleme',
            params: {'p_type': type, 'p_description': description},
          )
          .timeout(_timeout);
      return resultat?.toString();
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur signalerProbleme: $_derniereErreur');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> listeSignalementsProblemes() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const [];
      final resultat = await client
          .rpc('liste_signalements_problemes')
          .timeout(_timeout);
      if (resultat is! List) return const [];
      return [
        for (final e in resultat)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      debugPrint('[KinFlow] Erreur listeSignalementsProblemes: $e');
      return const [];
    }
  }

  Future<Map<String, dynamic>?> toggleLikeProbleme(String problemeId) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('toggle_like_probleme', params: {'p_probleme_id': problemeId})
          .timeout(_timeout);
      if (resultat is Map) return resultat.cast<String, dynamic>();
      return null;
    } catch (e) {
      debugPrint('[KinFlow] Erreur toggleLikeProbleme: $e');
      return null;
    }
  }

  /// Marque comme lus les messages reçus d'un ami(e).
  Future<bool> marquerMessagesLus(String amiId) async {
    await ready;
    final client = _client;
    if (client == null) return false;
    try {
      final resultat = await client
          .rpc('marquer_messages_lus', params: {'p_ami_id': amiId})
          .timeout(_timeout);
      return resultat == true;
    } catch (e) {
      debugPrint('[KinFlow] Erreur marquerMessagesLus: $e');
      return false;
    }
  }

  /// Estampille l'arrivée sur mon téléphone des messages non lus que je viens
  /// de récupérer : l'expéditeur voit alors son message « reçu ».
  Future<bool> marquerMessagesRecus() async {
    await ready;
    final client = _client;
    if (client == null) return false;
    try {
      final resultat = await client
          .rpc('marquer_messages_recus')
          .timeout(_timeout);
      return resultat == true;
    } catch (e) {
      debugPrint('[KinFlow] Erreur marquerMessagesRecus: $e');
      return false;
    }
  }

  /// Nombre de messages non lus par ami(e) : clé = ami_id, valeur = nombre.
  Future<Map<String, int>> nbMessagesNonLusAmis() async {
    await ready;
    final client = _client;
    if (client == null) return const {};
    try {
      final resultat = await client
          .rpc('nb_messages_non_lus_amis')
          .timeout(_timeout);
      if (resultat is! List) return const {};
      final comptes = <String, int>{};
      for (final e in resultat) {
        if (e is! Map) continue;
        final id = e['ami_id']?.toString();
        final nb = (e['nb'] as num?)?.toInt() ?? 0;
        if (id != null && nb > 0) comptes[id] = nb;
      }
      return comptes;
    } catch (e) {
      debugPrint('[KinFlow] Erreur nbMessagesNonLusAmis: $e');
      return const {};
    }
  }

  /// Dernier message échangé avec chaque ami(e) (fenêtre 7 jours) : clé =
  /// ami_id, valeur = {contenu, moi, cree_a}. Sert d'aperçu sous le nom.
  Future<Map<String, Map<String, dynamic>>> apercusMessagesAmis() async {
    await ready;
    final client = _client;
    if (client == null) return const {};
    try {
      final resultat = await client
          .rpc('apercus_messages_amis')
          .timeout(_timeout);
      if (resultat is! List) return const {};
      final apercus = <String, Map<String, dynamic>>{};
      for (final e in resultat) {
        if (e is! Map) continue;
        final id = e['ami_id']?.toString();
        if (id == null || id.isEmpty) continue;
        apercus[id] = e.cast<String, dynamic>();
      }
      return apercus;
    } catch (e) {
      debugPrint('[KinFlow] Erreur apercusMessagesAmis: $e');
      return const {};
    }
  }

  /// Retire un ami (symétrique). Retourne true si une relation a été
  /// supprimée.
  Future<bool> retirerAmi(String amiId) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final resultat = await client
          .rpc('retirer_ami', params: {'p_id': amiId})
          .timeout(_timeout);
      final ok = resultat == true;
      if (ok) Journal.s('AMIS', 'Ami retiré');
      return ok;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur retirerAmi: $_derniereErreur');
      Journal.e('AMIS', 'Retrait de l\'ami échoué', {
        'erreur': _derniereErreur,
      });
      return false;
    }
  }

  /// Publie ma position pour mes amis(es) — uniquement si le partage est
  /// actif (le drapeau se change via [definirPartagePosition]).
  Future<bool> publierMaPosition({
    required double latitude,
    required double longitude,
    double? cap,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final resultat = await client
          .rpc(
            'publier_ma_position',
            params: {
              'p_latitude': latitude,
              'p_longitude': longitude,
              'p_cap': cap,
            },
          )
          .timeout(_timeout);
      return resultat == true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur publierMaPosition: $_derniereErreur');
      return false;
    }
  }

  /// Active ou désactive le partage de ma position avec mes amis(es).
  ///
  /// [dureeMinutes] vaut null pour « jusqu'à désactivation ». La désactivation
  /// efface immédiatement les coordonnées côté serveur.
  Future<bool> definirPartagePosition(bool actif, {int? dureeMinutes}) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final resultat = await client
          .rpc(
            'definir_partage_position',
            params: {'p_actif': actif, 'p_duree_minutes': dureeMinutes},
          )
          .timeout(_timeout);
      final ok = resultat == true;
      if (ok) {
        Journal.s('AMIS', 'Partage de position modifié', {
          'actif': actif,
          'duree_minutes': dureeMinutes,
        });
      }
      return ok;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur definirPartagePosition: $_derniereErreur');
      Journal.e('AMIS', 'Changement du partage échoué', {
        'erreur': _derniereErreur,
      });
      return false;
    }
  }

  /// Mon partage de position est-il actif ? (false en cas d'échec)
  Future<bool> monPartagePosition() async {
    await ready;
    final client = _client;
    if (client == null) return false;
    try {
      final resultat = await client
          .rpc('mon_partage_position')
          .timeout(_timeout);
      return resultat == true;
    } catch (e) {
      debugPrint('[KinFlow] Erreur monPartagePosition: $e');
      return false;
    }
  }

  /// Détail du consentement de partage : actif + date d'expiration.
  Future<Map<String, dynamic>> monPartagePositionDetails() async {
    await ready;
    final client = _client;
    if (client == null) return {'actif': false, 'expire_a': null};
    try {
      final resultat = await client
          .rpc('mon_partage_position_details')
          .timeout(_timeout);
      if (resultat is Map) return resultat.cast<String, dynamic>();
      return {'actif': false, 'expire_a': null};
    } catch (e) {
      debugPrint('[KinFlow] Erreur monPartagePositionDetails: $e');
      return {'actif': false, 'expire_a': null};
    }
  }

  /// Compte mes signalements routiers
  Future<int> compterMesSignalements() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return 0;
      final res = await client
          .rpc('compter_signalements_utilisateur')
          .timeout(_timeout);
      if (res is int) return res;
      if (res is num) return res.toInt();
      return 0;
    } catch (e) {
      debugPrint('[KinFlow] Erreur compterMesSignalements: $e');
      return 0;
    }
  }

  // --- Blocage et signalement d'utilisateurs --------------------------------

  Future<String?> bloquerUtilisateur(String id) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final res = await client
          .rpc('bloquer_utilisateur', params: {'p_id': id})
          .timeout(_timeout);
      return res is String ? res : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur bloquerUtilisateur: $_derniereErreur');
      return null;
    }
  }

  Future<bool> debloquerUtilisateur(String id) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final res = await client
          .rpc('debloquer_utilisateur', params: {'p_id': id})
          .timeout(_timeout);
      return res == true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur debloquerUtilisateur: $_derniereErreur');
      return false;
    }
  }

  Future<bool> estBloque(String id) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final res = await client
          .rpc('est_bloque', params: {'p_id': id})
          .timeout(_timeout);
      return res == true;
    } catch (e) {
      debugPrint('[KinFlow] Erreur estBloque: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> mesBlocages() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const [];
      final res = await client.rpc('mes_blocages').timeout(_timeout);
      if (res is! List) return const [];
      return [
        for (final e in res)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur mesBlocages: $_derniereErreur');
      return const [];
    }
  }

  Future<String?> signalerUtilisateur({
    required String id,
    required String motif,
    String description = '',
    String? messageId,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final res = await client
          .rpc(
            'signaler_utilisateur',
            params: {
              'p_id': id,
              'p_motif': motif,
              'p_description': description,
              'p_message_id': messageId,
            },
          )
          .timeout(_timeout);
      return res is String ? res : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur signalerUtilisateur: $_derniereErreur');
      return null;
    }
  }

  // --- Compte permanent ------------------------------------------------------

  /// Email du compte permanent, ou null si l'identité est encore anonyme.
  String? get emailCompte => _client?.auth.currentUser?.email;

  bool get emailCompteConfirme =>
      _client?.auth.currentUser?.emailConfirmedAt != null;

  bool get possedeComptePermanent => emailCompte != null;

  /// Convertit l'utilisateur anonyme courant en compte email/mot de passe,
  /// sans changer d'identifiant : profil, amis et messages sont conservés.
  /// Retourne 'ok', 'confirmation_requise', 'email_invalide',
  /// 'mot_de_passe_trop_court' ou 'erreur'.
  Future<String> sauvegarderComptePermanent({
    required String email,
    required String motDePasse,
  }) async {
    final emailNettoye = email.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(emailNettoye)) {
      _derniereErreur = 'Adresse e-mail invalide.';
      return 'email_invalide';
    }
    if (motDePasse.length < 6) {
      _derniereErreur = 'Le mot de passe doit contenir au moins 6 caractères.';
      return 'mot_de_passe_trop_court';
    }
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) {
        _derniereErreur = 'Pas de connexion au serveur.';
        return 'erreur';
      }
      final res = await client.auth
          .updateUser(UserAttributes(email: emailNettoye, password: motDePasse))
          .timeout(_timeout);
      final user = res.user;
      if (user == null) {
        _derniereErreur = 'Le serveur n\'a pas confirmé la sauvegarde.';
        return 'erreur';
      }
      final id = user.id;
      try {
        await client
            .from('profiles')
            .update({'email': emailNettoye})
            .eq('id', id)
            .timeout(_timeout);
      } catch (_) {}
      Journal.s('COMPTE', 'Compte permanent activé');
      if (user.emailConfirmedAt == null) return 'confirmation_requise';
      return 'ok';
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint(
        '[KinFlow] Erreur sauvegarderComptePermanent: $_derniereErreur',
      );
      Journal.e('COMPTE', 'Sauvegarde du compte échouée', {
        'erreur': _derniereErreur,
      });
      return 'erreur';
    }
  }

  /// Connexion par email/mot de passe sur un nouvel appareil.
  Future<Map<String, dynamic>?> connecterAvecEmail({
    required String email,
    required String motDePasse,
  }) async {
    try {
      await ready;
      final client = _client;
      if (client == null) {
        _derniereErreur = 'Pas de connexion au serveur.';
        return null;
      }
      final res = await client.auth
          .signInWithPassword(
            email: email.trim().toLowerCase(),
            password: motDePasse,
          )
          .timeout(_timeout);
      final user = res.user;
      if (user == null) {
        _derniereErreur = 'Email ou mot de passe incorrect.';
        return null;
      }
      final profil = await client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle()
          .timeout(_timeout);
      if (profil == null) {
        _derniereErreur = 'Profil introuvable pour ce compte.';
        try {
          await client.auth.signOut().timeout(_timeout);
        } catch (_) {}
        return null;
      }
      await sauverProfilCache(profil);
      try {
        await marquerCompteLie(
          nom: (profil['nom'] as String? ?? '').trim(),
          prenom: (profil['prenom'] as String? ?? '').trim(),
          avatar: (profil['avatar'] as String? ?? ''),
          code: (profil['code'] as String? ?? ''),
        );
      } catch (_) {}
      Journal.s('CONNEXION', 'Connexion email réussie');
      return profil;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur connexion email: $_derniereErreur');
      Journal.e('CONNEXION', 'Connexion email échouée', {
        'erreur': _derniereErreur,
      });
      return null;
    }
  }

  // --- Suppression de compte -------------------------------------------------

  /// Supprime définitivement le compte et toutes ses données.
  /// Retourne 'supprime' ou 'erreur' (détail dans [derniereErreur]).
  Future<String> supprimerMonCompte() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) {
        _derniereErreur = 'Pas de connexion au serveur.';
        return 'erreur';
      }
      final res = await client.functions
          .invoke('supprimer-compte')
          .timeout(const Duration(seconds: 40));
      if (res.status != 200) {
        _derniereErreur =
            'Suppression impossible (code ${res.status}). Réessayez plus tard.';
        return 'erreur';
      }
      try {
        await client.auth.signOut().timeout(_timeout);
      } catch (_) {}
      await effacerCompteLieLocal();
      await effacerCachesHorsLigne();
      Journal.s('COMPTE', 'Compte supprimé définitivement');
      return 'supprime';
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur supprimerMonCompte: $_derniereErreur');
      Journal.e('COMPTE', 'Suppression du compte échouée', {
        'erreur': _derniereErreur,
      });
      return 'erreur';
    }
  }

  // --- Notifications push ----------------------------------------------------

  Future<bool> enregistrerTokenPush(
    String token, {
    String plateforme = 'android',
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      final res = await client
          .rpc(
            'enregistrer_token_push',
            params: {'p_token': token, 'p_plateforme': plateforme},
          )
          .timeout(_timeout);
      return res == true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur enregistrerTokenPush: $_derniereErreur');
      return false;
    }
  }

  Future<bool> supprimerTokenPush(String token) async {
    try {
      await ready;
      final client = _client;
      if (client == null) return false;
      final res = await client
          .rpc('supprimer_token_push', params: {'p_token': token})
          .timeout(_timeout);
      return res == true;
    } catch (e) {
      debugPrint('[KinFlow] Erreur supprimerTokenPush: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> mesPreferencesNotifications() async {
    const defaut = {
      'push_actif': true,
      'embouteillages': true,
      'routes_bloquees': true,
      'messages': true,
      'demandes_amis': true,
      'infos': true,
    };
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return Map<String, dynamic>.from(defaut);
      final res = await client
          .rpc('mes_preferences_notifications')
          .timeout(_timeout);
      if (res is Map) {
        return {...defaut, ...res.cast<String, dynamic>()};
      }
      return Map<String, dynamic>.from(defaut);
    } catch (e) {
      debugPrint('[KinFlow] Erreur mesPreferencesNotifications: $e');
      return Map<String, dynamic>.from(defaut);
    }
  }

  Future<Map<String, dynamic>> definirPreferencesNotifications(
    Map<String, dynamic> preferences,
  ) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const {};
      final res = await client
          .rpc(
            'definir_preferences_notifications',
            params: {'p_preferences': preferences},
          )
          .timeout(_timeout);
      if (res is Map) return res.cast<String, dynamic>();
      return const {};
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint(
        '[KinFlow] Erreur definirPreferencesNotifications: $_derniereErreur',
      );
      return const {};
    }
  }

  Future<void> signOut() async {
    final client = _client;
    if (client == null) {
      await effacerCompteLieLocal();
      await effacerCachesHorsLigne();
      return;
    }
    // Coupe le partage AVANT de perdre la session : sinon les dernières
    // coordonnées resteraient visibles par les amis après la déconnexion.
    try {
      await client
          .rpc(
            'definir_partage_position',
            params: {'p_actif': false, 'p_duree_minutes': null},
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('[KinFlow] Désactivation position au signOut: $e');
    }
    try {
      await client.rpc('supprimer_mes_tokens_push').timeout(_timeout);
    } catch (e) {
      debugPrint('[KinFlow] Suppression tokens push au signOut: $e');
    }
    try {
      await client.auth.signOut().timeout(_timeout);
    } catch (e) {
      debugPrint('[KinFlow] Erreur signOut: $e');
    }
    await effacerCompteLieLocal();
    await effacerCachesHorsLigne();
  }

  // ===========================================================================
  // Espaces informateurs (phase A)
  // ===========================================================================
  //
  // Un espace est privé : il n'est accessible que par son lien (jeton). Ces
  // méthodes ne lisent jamais la table `publications` en direct : tout passe
  // par des RPC SECURITY DEFINER, pour que la règle « lien ou abonnement »
  // reste au même endroit.

  /// URLs signées déjà obtenues, avec leur expiration (évite de re-signer à
  /// chaque reconstruction d'écran).
  final Map<String, (String, DateTime)> _cachePhotosPublications = {};

  /// Mon espace : jeton, bio et compteurs. Null si non connecté.
  Future<Map<String, dynamic>?> monEspace() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final ligne = await client
          .rpc('mon_espace')
          .maybeSingle()
          .timeout(_timeout);
      return ligne == null ? null : Map<String, dynamic>.from(ligne);
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur monEspace: $_derniereErreur');
      return null;
    }
  }

  /// 'proprietaire', 'membres' ou 'tous'.
  Future<bool> modifierOuverturePublication(String mode) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      await client
          .rpc('modifier_ouverture_publication', params: {'p_mode': mode})
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint(
        '[KinFlow] Erreur modifierOuverturePublication: $_derniereErreur',
      );
      return false;
    }
  }

  Future<bool> modifierBioEspace(String bio) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      await client
          .rpc('modifier_bio_espace', params: {'p_bio': bio})
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur modifierBioEspace: $_derniereErreur');
      return false;
    }
  }

  /// Révoque l'ancien lien et en renvoie un nouveau. Null en cas d'échec.
  Future<String?> regenererJetonEspace() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('regenerer_jeton_espace')
          .timeout(_timeout);
      return resultat?.toString();
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur regenererJetonEspace: $_derniereErreur');
      return null;
    }
  }

  Future<List<Publication>> mesPublications({int limite = 50}) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const [];
      final resultat = await client
          .rpc('mes_publications', params: {'p_limite': limite})
          .timeout(_timeout);
      return _lirePublications(resultat);
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur mesPublications: $_derniereErreur');
      return const [];
    }
  }

  /// Publie un reportage et renvoie son identifiant. Null en cas d'échec
  /// (le détail lisible est dans [derniereErreur]).
  Future<String?> publierPublication({
    required String jeton,
    required String titre,
    required String contenu,
    String type = 'info',
    String? lieu,
    List<String> photos = const [],
    bool anonyme = false,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'publier_publication',
            params: {
              'p_jeton': jeton.trim(),
              'p_titre': titre,
              'p_contenu': contenu,
              'p_photos': photos,
              'p_type': type,
              'p_lieu': lieu,
              'p_anonyme': anonyme,
            },
          )
          .timeout(_timeout);
      return resultat?.toString();
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur publierPublication: $_derniereErreur');
      return null;
    }
  }

  Future<bool> supprimerPublication(String id) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      await client
          .rpc('supprimer_publication', params: {'p_id': id})
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur supprimerPublication: $_derniereErreur');
      return false;
    }
  }

  /// Téléverse une photo de reportage dans le bucket privé
  /// `publications_photos` et renvoie son chemin.
  Future<String?> televerserPhotoPublication({
    required List<int> octets,
    required String extension,
    required String dossier,
    int index = 0,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final uid = client.auth.currentUser?.id;
      if (uid == null) return null;
      final ext = extension.toLowerCase().replaceAll('.', '');
      final contentType = switch (ext) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        'heic' => 'image/heic',
        _ => 'image/jpeg',
      };
      final proprietaire = dossier.trim().isEmpty ? uid : dossier.trim();
      final chemin =
          '$proprietaire/pub_${DateTime.now().microsecondsSinceEpoch}_$index.'
          '${ext.isEmpty ? 'jpg' : ext}';
      await client.storage
          .from('publications_photos')
          .uploadBinary(
            chemin,
            Uint8List.fromList(octets),
            fileOptions: FileOptions(contentType: contentType, upsert: false),
          )
          .timeout(const Duration(seconds: 60));
      return chemin;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint(
        '[KinFlow] Erreur televerserPhotoPublication: $_derniereErreur',
      );
      return null;
    }
  }

  /// URL signée (1 h) d'une photo de reportage, mise en cache.
  Future<String?> urlPhotoPublication(String chemin) async {
    if (chemin.trim().isEmpty) return null;
    final cache = _cachePhotosPublications[chemin];
    if (cache != null && cache.$2.isAfter(DateTime.now())) return cache.$1;
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final url = await client.storage
          .from('publications_photos')
          .createSignedUrl(chemin, 3600)
          .timeout(_timeout);
      _cachePhotosPublications[chemin] = (
        url,
        DateTime.now().add(const Duration(minutes: 50)),
      );
      return url;
    } catch (e) {
      debugPrint('[KinFlow] Erreur urlPhotoPublication: $e');
      return null;
    }
  }

  /// L'espace correspondant à un jeton (null si le lien est invalide).
  Future<Map<String, dynamic>?> espaceParJeton(String jeton) async {
    final propre = jeton.trim();
    if (propre.isEmpty) return null;
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final ligne = await client
          .rpc('espace_par_jeton', params: {'p_jeton': propre})
          .maybeSingle()
          .timeout(_timeout);
      return ligne == null ? null : Map<String, dynamic>.from(ligne);
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur espaceParJeton: $_derniereErreur');
      return null;
    }
  }

  /// Marque l'espace comme suivi (ouvrir un lien vaut abonnement). C'est ce
  /// qui autorise la lecture des photos privées du bucket.
  Future<bool> suivreEspace(String jeton) async {
    final propre = jeton.trim();
    if (propre.isEmpty) return false;
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      await client
          .rpc('suivre_espace', params: {'p_jeton': propre})
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur suivreEspace: $_derniereErreur');
      return false;
    }
  }

  /// Suivre explicitement un espace (ou ne plus le suivre). L'accès en
  /// lecture reste acquis tant que le lien est valide.
  Future<bool?> basculerSuiviEspace(String jeton, bool suivre) async {
    final propre = jeton.trim();
    if (propre.isEmpty) return null;
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'basculer_suivi_espace',
            params: {'p_jeton': propre, 'p_suivre': suivre},
          )
          .timeout(_timeout);
      return resultat == true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur basculerSuiviEspace: $_derniereErreur');
      return null;
    }
  }

  /// Les espaces que je suis : liste de l'onglet « Suivis ».
  Future<List<Map<String, dynamic>>> mesAbonnements() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const [];
      final resultat = await client.rpc('mes_abonnements').timeout(_timeout);
      if (resultat is! List) return const [];
      return resultat
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur mesAbonnements: $_derniereErreur');
      return const [];
    }
  }

  Future<List<Publication>> publicationsEspace(
    String jeton, {
    int limite = 50,
  }) async {
    final propre = jeton.trim();
    if (propre.isEmpty) return const [];
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const [];
      final resultat = await client
          .rpc(
            'publications_espace',
            params: {'p_jeton': propre, 'p_limite': limite},
          )
          .timeout(_timeout);
      return _lirePublications(resultat);
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur publicationsEspace: $_derniereErreur');
      return const [];
    }
  }

  /// Équipe de mon espace : les personnes autorisées à publier.
  Future<List<Map<String, dynamic>>> mesMembresEspace() async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const [];
      final resultat = await client.rpc('mes_membres_espace').timeout(_timeout);
      if (resultat is! List) return const [];
      return resultat
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur mesMembresEspace: $_derniereErreur');
      return const [];
    }
  }

  Future<Map<String, dynamic>?> trouverUtilisateurParCode(String code) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('trouver_utilisateur_par_code', params: {'p_code': code.trim()})
          .timeout(_timeout);
      final ligne = resultat is List && resultat.isNotEmpty
          ? resultat.first
          : null;
      return ligne is Map ? Map<String, dynamic>.from(ligne) : null;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint(
        '[KinFlow] Erreur trouverUtilisateurParCode: $_derniereErreur',
      );
      return null;
    }
  }

  Future<bool> ajouterMembreEspace(String code) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      await client
          .rpc('ajouter_membre_espace', params: {'p_code': code.trim()})
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur ajouterMembreEspace: $_derniereErreur');
      return false;
    }
  }

  Future<bool> retirerMembreEspace(String membre) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      await client
          .rpc('retirer_membre_espace', params: {'p_membre': membre})
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur retirerMembreEspace: $_derniereErreur');
      return false;
    }
  }

  /// Ajoute ou retire mon like. Renvoie le nouvel état (true = liké).
  Future<bool?> likerPublication(String publication) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc('liker_publication', params: {'p_publication': publication})
          .timeout(_timeout);
      return resultat == true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur likerPublication: $_derniereErreur');
      return null;
    }
  }

  Future<List<Commentaire>> commentairesPublication(String publication) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return const [];
      final resultat = await client
          .rpc(
            'commentaires_publication',
            params: {'p_publication': publication},
          )
          .timeout(_timeout);
      return _lireCommentaires(resultat);
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur commentairesPublication: $_derniereErreur');
      return const [];
    }
  }

  Future<String?> commenterPublication({
    required String publication,
    required String contenu,
    String? parent,
    bool anonyme = false,
  }) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'commenter_publication',
            params: {
              'p_publication': publication,
              'p_contenu': contenu,
              'p_parent': parent,
              'p_anonyme': anonyme,
            },
          )
          .timeout(_timeout);
      return resultat?.toString();
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur commenterPublication: $_derniereErreur');
      return null;
    }
  }

  Future<bool> supprimerCommentaire(String id) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return false;
      await client
          .rpc('supprimer_commentaire', params: {'p_id': id})
          .timeout(_timeout);
      return true;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur supprimerCommentaire: $_derniereErreur');
      return false;
    }
  }

  /// Pose / retire mon emoji sur un commentaire. Renvoie l'emoji conservé,
  /// ou null si la réaction a été retirée.
  Future<String?> reagirCommentaire(String commentaire, String emoji) async {
    try {
      await ready;
      await ensureSignedIn();
      final client = _client;
      if (client == null) return null;
      final resultat = await client
          .rpc(
            'reagir_commentaire',
            params: {'p_commentaire': commentaire, 'p_emoji': emoji},
          )
          .timeout(_timeout);
      final texte = resultat?.toString().trim() ?? '';
      return texte.isEmpty ? null : texte;
    } catch (e) {
      _derniereErreur = _detailErreur(e);
      debugPrint('[KinFlow] Erreur reagirCommentaire: $_derniereErreur');
      return null;
    }
  }

  List<Commentaire> _lireCommentaires(dynamic resultat) {
    if (resultat is! List) return const [];
    return resultat
        .whereType<Map>()
        .map((e) => Commentaire.depuisJson(Map<String, dynamic>.from(e)))
        .where((c) => c.id.isNotEmpty)
        .toList(growable: false);
  }

  List<Publication> _lirePublications(dynamic resultat) {
    if (resultat is! List) return const [];
    return resultat
        .whereType<Map>()
        .map((e) => Publication.depuisJson(Map<String, dynamic>.from(e)))
        .where((p) => p.id.isNotEmpty)
        .toList(growable: false);
  }
}
