import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config/ia_config.dart';
import '../models/ami_position.dart';
import '../models/search_result.dart';
import '../services/search_service.dart';
import '../services/supabase_service.dart';
import 'diagnostics_service.dart';

/// Une action demandée par l'IA (function call) : nom + arguments.
class ActionIA {
  ActionIA({required this.nom, required this.arguments});

  final String nom;
  final Map<String, dynamic> arguments;
}

/// Réponse de l'IA : du texte et/ou une ou plusieurs actions à exécuter.
class ReponseIA {
  ReponseIA({this.texte = '', this.actions = const []});

  final String texte;
  final List<ActionIA> actions;
}

/// Le « cerveau » de Kinflow : un ami(e) IA qui discute et peut déclencher de
/// vraies actions dans l'app (localiser un ami, tracer un itinéraire, chercher
/// un lieu, envoyer un message) via le *function calling* de Gemini.
///
/// L'IA renvoie soit du texte, soit un (ou des) appel(s) de fonction. La
/// couche écran exécute l'action puis rappelle [repondreAuxActions] pour que
/// l'IA finalise sa phrase (ex. « J'ai localisé Marie »).
class IAService {
  IAService._();
  static final IAService instance = IAService._();

  final SearchService _search = SearchService();

  /// Historique de conversation au format Gemini (contents). Conservé en
  /// mémoire pour la durée de la session ; on ne garde que les N derniers
  /// tours pour ne pas dépasser les limites de tokens.
  final List<Map<String, dynamic>> _historique = [];

  static const int _maxTours = 30;

  // ---------------------------------------------------------------------------
  // Déclaration des fonctions exposées à l'IA (les « outils » de Kinflow)
  // ---------------------------------------------------------------------------

  static const List<Map<String, dynamic>> _fonctions = [
    {
      'name': 'localiser_ami',
      'description':
          'Localise un(de un(e) ami(e) sur la carte et ouvre la carte centrée '
              'sur lui/elle. À utiliser quand l\'utilisateur demande où est un '
              'ami, ou veut le/la localiser.',
      'parameters': {
        'type': 'object',
        'properties': {
          'nom_ami': {
            'type': 'string',
            'description': 'Prénom (ou nom) de l\'ami(e) à localiser.',
          },
        },
        'required': ['nom_ami'],
      },
    },
    {
      'name': 'itineraire_vers',
      'description':
          'Trace un itinéraire (route) depuis la position actuelle de '
              'l\'utilisateur jusqu\'à une destination donnée. À utiliser quand '
              'l\'utilisateur demande un trajet, un chemin, ou « jusqu\'à » un '
              'lieu.',
      'parameters': {
        'type': 'object',
        'properties': {
          'destination': {
            'type': 'string',
            'description':
                'Nom du lieu de destination (ex : « aéroport de N\'dolo », '
                    '« marché Central »).',
          },
        },
        'required': ['destination'],
      },
    },
    {
      'name': 'rechercher_lieu',
      'description':
          'Cherche un lieu / point d\'intérêt (restaurant, pharmacie, école, '
              'station-service…) et retourne les résultats. À utiliser quand '
              'l\'utilisateur cherche un endroit.',
      'parameters': {
        'type': 'object',
        'properties': {
          'terme': {
            'type': 'string',
            'description': 'Ce qu\'il faut chercher (ex : « pharmacie »).',
          },
        },
        'required': ['terme'],
      },
    },
    {
      'name': 'envoyer_message_ami',
      'description':
          'Envoie un message texte à un(de un(e) ami(e). À utiliser quand '
              'l\'utilisateur veut écrire à un ami (ex : « dis à Marie que '
              'j\'arrive »).',
      'parameters': {
        'type': 'object',
        'properties': {
          'nom_ami': {
            'type': 'string',
            'description': 'Prénom (ou nom) de l\'ami(e) destinataire.',
          },
          'message': {
            'type': 'string',
            'description': 'Le texte du message à envoyer.',
          },
        },
        'required': ['nom_ami', 'message'],
      },
    },
  ];

  // ---------------------------------------------------------------------------
  // Prompt système : la personnalité de Kinflow
  // ---------------------------------------------------------------------------

  static const String _systeme = '''
Tu es « Kinflow », un(e) ami(e) IA intégré(e) dans l'application KinFlow (une app de navigation et de trafic à Kinshasa, RDC).

PERSONNALITÉ :
- Tu es chaleureux(se), naturel(le), amical(e) — comme un vrai ami.
- Tu parles en français, de façon simple et décontractée.
- Tu es bref : une ou deux phrases suffisent, sauf si on te demande des détails.
- Tu connais bien Kinshasa (quartiers, repères, trafic).

CAPACITÉS :
Tu peux exécuter des actions directement dans l'app. Pour cela, utilise les fonctions disponibles :
- localiser_ami : pour savoir où est un ami / le localiser sur la carte.
- itineraire_vers : pour tracer un trajet jusqu'à un lieu.
- rechercher_lieu : pour chercher un endroit (pharmacie, restaurant…).
- envoyer_message_ami : pour envoyer un message à un ami.

RÈGLES :
- Quand l'utilisateur te demande une action, exécute-la (appelle la fonction) puis termine ta réponse de façon naturelle.
- Si une action échoue (ami introuvable, lieu introuvable), dis-le simplement et propose une aide.
- Ne t'invente pas de fonctionnalités qui n'existent pas.
- Reste un ami : tu peux discuter, poser des questions, être du soutien.
''';

  // ---------------------------------------------------------------------------
  // Appels
  // ---------------------------------------------------------------------------

  /// Envoie un message texte de l'utilisateur et obtient la réponse de l'IA
  /// (texte + éventuelles actions à exécuter).
  Future<ReponseIA> envoyer(String texte) async {
    if (!IAConfig.estConfiguree) {
      return ReponseIA(
        texte: 'Kinflow n\'est pas encore configuré : ajoute ta clé API Gemini '
            'dans lib/config/ia_config.dart pour me donner vie. 🤖',
      );
    }
    _historique.add({
      'role': 'user',
      'parts': [
        {'text': texte},
      ],
    });
    _limiterHistorique();
    return _appelerGemini();
  }

  /// Renvoie à l'IA le résultat des actions exécutées, pour qu'elle finalise
  /// sa réponse (ex. « C'est fait, j'ai localisé Marie »).
  Future<ReponseIA> repondreAuxActions(
    List<Map<String, dynamic>> resultats,
  ) async {
    _historique.add({
      'role': 'user',
      'parts': [
        for (final r in resultats)
          {
            'functionResponse': {
              'name': r['nom'],
              'response': r['reponse'] ?? <String, dynamic>{},
            },
          },
      ],
    });
    _limiterHistorique();
    return _appelerGemini();
  }

  /// Repart de zéro (nouvelle discussion).
  void reinitialiser() => _historique.clear();

  void _limiterHistorique() {
    // On garde toujours le prompt système hors de l'historique ; ici on tronque
    // simplement les anciens tours. Chaque tour = 1 entrée (user ou model).
    if (_historique.length > _maxTours * 2) {
      _historique.removeRange(0, _historique.length - _maxTours * 2);
    }
  }

  // ---------------------------------------------------------------------------
  // Appel HTTP + parsing Gemini
  // ---------------------------------------------------------------------------

  Future<ReponseIA> _appelerGemini() async {
    final corps = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _systeme},
        ],
      },
      'contents': _historique,
      'tools': [
        {'functionDeclarations': _fonctions},
      ],
      'generationConfig': {'temperature': 0.7},
    });

    final reponse = await http
        .post(
          IAConfig.endpointGenerer,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': IAConfig.cleApi,
          },
          body: corps,
        )
        .timeout(const Duration(seconds: 45));

    if (reponse.statusCode != 200) {
      Journal.a('IA', 'Erreur Gemini HTTP ${reponse.statusCode}', {
        'corps': reponse.body.length > 300
            ? '${reponse.body.substring(0, 300)}…'
            : reponse.body,
      });
      return ReponseIA(
        texte: 'Oups, j\'ai eu un souci de connexion (${reponse.statusCode}). '
            'Réessaie dans un instant. 🙈',
      );
    }

    return _parserReponse(utf8.decode(reponse.bodyBytes));
  }

  /// Analyse la réponse JSON de Gemini et en extrait le texte + les actions.
  ReponseIA _parserReponse(String brut) {
    try {
      final json = jsonDecode(brut) as Map<String, dynamic>;
      final candidats = (json['candidates'] as List?) ?? const [];
      if (candidats.isEmpty) {
        return ReponseIA(texte: 'Hmm, je n\'ai rien à répondre pour l\'instant.');
      }
      final contenu =
          (candidats.first as Map<String, dynamic>)['content'] as Map?;
      final parts = (contenu?['parts'] as List?) ?? const [];

      final buffer = StringBuffer();
      final actions = <ActionIA>[];

      for (final p in parts) {
        if (p is! Map) continue;
        final texte = p['text'];
        if (texte is String && texte.isNotEmpty) buffer.write(texte);
        final fc = p['functionCall'];
        if (fc is Map) {
          actions.add(
            ActionIA(
              nom: fc['name']?.toString() ?? '',
              arguments: (fc['args'] as Map?)?.cast<String, dynamic>() ?? {},
            ),
          );
        }
      }

      // On garde la réponse du modèle dans l'historique Gemini (texte +
      // functionCall) pour que le tour suivant soit cohérent.
      _historique.add({
        'role': 'model',
        'parts': parts,
      });

      return ReponseIA(texte: buffer.toString(), actions: actions);
    } catch (e) {
      Journal.a('IA', 'Parsing de la réponse Gemini échoué', {'erreur': '$e'});
      return ReponseIA(
        texte: 'J\'ai eu du mal à comprendre ma propre réponse. Réessaie. 🤔',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Exécution des actions côté app (appelée par l'écran)
  // ---------------------------------------------------------------------------

  /// Localise un ami par son nom et retourne [AmiPosition] si trouvé.
  Future<AmiPosition?> localiserAmi(String nom) async {
    final ami = await _trouverAmi(nom);
    return ami;
  }

  /// Cherche un lieu et retourne la première liste de résultats.
  Future<List<SearchResult>> rechercherLieu(String terme) async {
    try {
      final stream = _search.rechercherLieu(terme);
      final resultats = await stream.first;
      return resultats.take(5).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Envoie un message à un ami. Retourne 'ok' ou un code d'erreur.
  Future<String> envoyerMessageAmi(String nom, String message) async {
    final ami = await _trouverAmi(nom);
    if (ami == null) return 'ami_introuvable';
    final resultat = await SupabaseService().envoyerMessageAmi(
      amiId: ami.id,
      contenu: message,
    );
    return resultat == 'envoye' ? 'ok' : (resultat ?? 'reseau');
  }

  /// Trouve un ami par nom (prénom ou nom, insensible à la casse, par
  /// correspondance partielle). Retourne null si introuvable.
  Future<AmiPosition?> _trouverAmi(String nom) async {
    final cible = _normaliser(nom);
    if (cible.isEmpty) return null;

    final service = SupabaseService();
    final brut = await service.mesAmis();
    final surnoms = await service.chargerSurnomsAmis();
    final lignes = service.appliquerSurnomsAmis(brut, surnoms);

    AmiPosition? partiel;
    for (final ligne in lignes) {
      final ami = AmiPosition.depuisJson(ligne);
      if (ami == null) continue;
      final candidats = <String>[
        ami.nom,
        (ligne['prenom']?.toString() ?? ''),
        (ligne['nom']?.toString() ?? ''),
      ];
      for (final candidat in candidats) {
        final norm = _normaliser(candidat);
        if (norm.isEmpty) continue;
        if (norm == cible) return ami; // correspondance exacte : on prend.
        if (norm.contains(cible) || cible.contains(norm)) {
          partiel ??= ami; // correspondance partielle : repli.
        }
      }
    }
    return partiel;
  }

  static String _normaliser(String s) =>
      s.toLowerCase().trim().replaceAll(RegExp(r'[éèêë]'), 'e')
          .replaceAll(RegExp(r'[àâä]'), 'a')
          .replaceAll(RegExp(r'[îï]'), 'i')
          .replaceAll(RegExp(r'[ôö]'), 'o')
          .replaceAll(RegExp(r'[ûüù]'), 'u')
          .replaceAll(RegExp(r'\s+'), ' ');
}
