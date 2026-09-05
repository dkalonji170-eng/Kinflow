import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:shared_preferences/shared_preferences.dart';

/// Niveau de gravité d'une entrée du journal de diagnostic.
enum NiveauJournal { info, succes, attention, erreur }

/// Une entrée du journal : horodatée, classée par module, lisible seule.
class EntreeJournal {
  EntreeJournal({
    required this.sequence,
    required this.horodatage,
    required this.module,
    required this.niveau,
    required this.message,
    this.details,
    this.precedente = false,
  });

  final int sequence;
  final DateTime horodatage;
  final String module;
  final NiveauJournal niveau;
  final String message;
  final Map<String, Object?>? details;

  /// Vrai si l'entrée vient de la session PRÉCÉDENTE (retrouvée sur disque
  /// après une relance ou un plantage violent de l'application).
  final bool precedente;

  String get heureFormatee {
    final h = horodatage.hour.toString().padLeft(2, '0');
    final m = horodatage.minute.toString().padLeft(2, '0');
    final s = horodatage.second.toString().padLeft(2, '0');
    final ms = horodatage.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  String get libelleNiveau => switch (niveau) {
        NiveauJournal.info => 'INFO',
        NiveauJournal.succes => 'OK',
        NiveauJournal.attention => 'ATTENTION',
        NiveauJournal.erreur => 'ERREUR',
      };

  String get detailsFormates {
    final d = details;
    if (d == null || d.isEmpty) return '';
    return d.entries.map((e) {
      final valeur = e.value;
      final texte = valeur is double
          ? valeur.toStringAsFixed(valeur.abs() < 100 ? 3 : 1)
          : '$valeur';
      return '${e.key}=$texte';
    }).join(', ');
  }

  Map<String, Object?> versJson() => {
        's': sequence,
        't': horodatage.toIso8601String(),
        'm': module,
        'n': niveau.index,
        'msg': message,
        if (details != null && details!.isNotEmpty) 'd': details,
      };

  static EntreeJournal? depuisJson(Object? brut) {
    if (brut is! Map) return null;
    final n = brut['n'];
    if (n is! int || n < 0 || n >= NiveauJournal.values.length) return null;
    final t = DateTime.tryParse('${brut['t']}');
    if (t == null) return null;
    final detailsBruts = brut['d'];
    return EntreeJournal(
      sequence: brut['s'] is int ? brut['s'] as int : 0,
      horodatage: t,
      module: '${brut['m']}',
      niveau: NiveauJournal.values[n],
      message: '${brut['msg']}',
      details: detailsBruts is Map
          ? detailsBruts.cast<String, Object?>()
          : null,
    );
  }
}

/// Boîte noire de l'application : tout ce qui se passe (écrans visités,
/// position GPS, carte, navigation, itinéraires, téléchargements, erreurs)
/// y est consigné pour la session courante ET sauvegardé sur disque :
/// si l'application plante violemment, les événements de la session
/// précédente sont retrouvés au prochain démarrage (marqués « S-1 »).
///
/// Utilisation : [Journal.i] (info), [Journal.s] (succès),
/// [Journal.a] (attention), [Journal.e] (erreur) — le premier argument est
/// le MODULE (POSITION, CARTE, NAVIGATION, ITINERAIRE...), toujours en
/// majuscules pour repérage rapide.
class Journal extends ChangeNotifier {
  Journal._() : _demarrage = DateTime.now() {
    _chargerSessionPrecedente();
  }
  static final Journal instance = Journal._();

  static const String _cleStockage = 'kinflow_journal_v1';

  /// Volume borné en mémoire : au-delà, les plus anciennes entrées sont
  /// abandonnées.
  static const int maxEntrees = 800;

  /// Délai entre deux écritures disque : évite d'écrire à chaque log.
  static const Duration _delaiSauvegarde = Duration(seconds: 5);

  /// Instant de lancement de l'application (pour la durée de session).
  final DateTime _demarrage;

  final List<EntreeJournal> _entrees = [];
  int _sequence = 0;

  Timer? _minuterieSauvegarde;
  bool _chargementEffectue = false;

  List<EntreeJournal> get entrees => List.unmodifiable(_entrees);

  bool get vide => _entrees.isEmpty;

  List<String> get modules {
    final listeModules = _entrees.map((e) => e.module).toSet().toList()
      ..sort();
    return listeModules;
  }

  /// Erreurs survenues depuis la dernière consultation de la fenêtre :
  /// alimente le badge rouge du bouton « Mon application ».
  int _erreursNonVues = 0;
  int get erreursNonVues => _erreursNonVues;

  /// Notification DIFFÉRÉE : les auditeurs (écran, badge) ne sont prévenus
  /// qu'après un court délai, jamais pendant une phase de build. C'est ce
  /// qui empêche l'ouverture de la fenêtre de geler l'application quand
  /// plusieurs événements arrivent en rafale.
  Timer? _notifTimer;

  void _planifierNotification() {
    _notifTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifTimer = null;
      notifyListeners();
    });
  }

  /// Anti-tempête : deux événements IDENTIQUES à moins de 300 ms d'écart ne
  /// sont consignés qu'une fois. Protège d'une boucle d'erreurs qui se
  /// re-logge elle-même et sature le journal.
  EntreeJournal? _derniereEntreeAjoutee;
  static const Duration _fenetreAntiTempete = Duration(milliseconds: 300);

  /// Appelé à l'ouverture de la fenêtre : les erreurs sont réputées vues.
  void marquerErreursVues() {
    if (_erreursNonVues == 0) return;
    _erreursNonVues = 0;
    _planifierNotification();
  }

  static void i(String module, String message,
          [Map<String, Object?>? details]) =>
      instance._ajouter(NiveauJournal.info, module, message, details);

  static void s(String module, String message,
          [Map<String, Object?>? details]) =>
      instance._ajouter(NiveauJournal.succes, module, message, details);

  static void a(String module, String message,
          [Map<String, Object?>? details]) =>
      instance._ajouter(NiveauJournal.attention, module, message, details);

  static void e(String module, String message,
          [Map<String, Object?>? details]) =>
      instance._ajouter(NiveauJournal.erreur, module, message, details);

  /// Anti-réentrance : _ajouter est entièrement synchrone ; si un appel
  /// imbriqué survient (ex. une exception pendant l'ajout déclenche elle-même
  /// un log de plantage), il est ignoré plutôt que d'empiler la pile.
  bool _ajoutEnCours = false;

  void _ajouter(
    NiveauJournal niveau,
    String module,
    String message,
    Map<String, Object?>? details,
  ) {
    if (_ajoutEnCours) return;
    _ajoutEnCours = true;
    try {
      final entree = EntreeJournal(
        sequence: _sequence++,
        horodatage: DateTime.now(),
        module: module.toUpperCase(),
        niveau: niveau,
        message: message,
        details: details,
      );

      final precedente = _derniereEntreeAjoutee;
      if (precedente != null &&
          precedente.module == entree.module &&
          precedente.niveau == entree.niveau &&
          precedente.message == entree.message &&
          precedente.detailsFormates == entree.detailsFormates &&
          entree.horodatage.difference(precedente.horodatage) <
              _fenetreAntiTempete) {
        return;
      }
      _derniereEntreeAjoutee = entree;

      _entrees.add(entree);
      if (niveau == NiveauJournal.erreur) _erreursNonVues++;
      while (_entrees.length > maxEntrees) {
        _entrees.removeAt(0);
      }
      _planifierSauvegarde();
      _planifierNotification();
    } finally {
      _ajoutEnCours = false;
    }
  }

  void vider() {
    if (_entrees.isEmpty) return;
    _entrees.clear();
    _erreursNonVues = 0;
    _derniereEntreeAjoutee = null;
    unawaited(_supprimerSauvegarde());
    _planifierNotification();
  }

  // ---------------------------------------------------------------------
  // Persistance sur disque (survit à un plantage violent)
  // ---------------------------------------------------------------------

  Future<void> _chargerSessionPrecedente() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final brut = prefs.getString(_cleStockage);
      _chargementEffectue = true;
      if (brut == null || brut.isEmpty) return;
      final liste = json.decode(brut);
      if (liste is! List) return;
      final retrouvees = <EntreeJournal>[];
      for (final element in liste) {
        final entree = EntreeJournal.depuisJson(element);
        if (entree == null) continue;
        retrouvees.add(entree);
      }
      if (retrouvees.isEmpty) return;
      // Les entrées d'avant s'insèrent AVANT celles de la session courante ;
      // numérotées en négatif (-n ... -1) pour rester triées et reconnaissables.
      var seq = -retrouvees.length;
      for (var i = 0; i < retrouvees.length; i++) {
        final entree = retrouvees[i];
        retrouvees[i] = EntreeJournal(
          sequence: seq++,
          horodatage: entree.horodatage,
          module: entree.module,
          niveau: entree.niveau,
          message: entree.message,
          details: entree.details,
          precedente: true,
        );
      }
      _entrees.insertAll(0, retrouvees);
      _planifierNotification();
    } catch (_) {
      _chargementEffectue = true;
    }
  }

  void _planifierSauvegarde() {
    _minuterieSauvegarde ??=
        Timer(_delaiSauvegarde, () {
          _minuterieSauvegarde = null;
          unawaited(_sauvegarder());
        });
  }

  Future<void> _sauvegardeImmediat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cleStockage,
        json.encode([
          for (final e in _entrees.where((e) => !e.precedente))
            e.versJson(),
        ]),
      );
    } catch (_) {
      // Le stockage peut être indisponible : le journal reste en mémoire.
    }
  }

  Future<void> _sauvegarder() async {
    if (!_chargementEffectue) {
      // Attendre que la restauration ait lu l'ancien contenu avant d'écrire,
      // sinon on écraserait la session précédente trop tôt.
      _planifierSauvegarde();
      return;
    }
    await _sauvegardeImmediat();
  }

  Future<void> _supprimerSauvegarde() async {
    try {
      _minuterieSauvegarde?.cancel();
      _minuterieSauvegarde = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cleStockage);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Export texte : conçu pour être collé tel quel à un analyseur
  // ---------------------------------------------------------------------

  /// Exporte tout le journal en texte brut ordonné : fiche d'environnement,
  /// compteurs par module, résumé des erreurs, session précédente puis la
  /// chronologie complète. Prêt à être copié et partagé pour analyse.
  String exporterTexte() {
    final maintenant = DateTime.now();
    final duree = maintenant.difference(_demarrage);
    final courantes =
        _entrees.where((e) => !e.precedente).toList(growable: false);
    final precedentes =
        _entrees.where((e) => e.precedente).toList(growable: false);

    var nbErreurs = 0;
    var nbAlertes = 0;
    for (final e in courantes) {
      if (e.niveau == NiveauJournal.erreur) nbErreurs++;
      if (e.niveau == NiveauJournal.attention) nbAlertes++;
    }

    final tampon = StringBuffer()
      ..writeln(
          '================ KINFLOW — RAPPORT DE DIAGNOSTIC ================')
      ..writeln('Généré le     : $maintenant')
      ..writeln(
          'App lancée le : $_demarrage (durée de session : ${duree.inMinutes} min)')
      ..writeln('Environnement : ${_decrireEnvironnement()}')
      ..writeln(
          'Événements    : ${courantes.length} dans cette session '
          '(+${precedentes.length} de la session précédente)')
      ..writeln(
          'Santé         : $nbErreurs erreur(s), $nbAlertes alerte(s), '
          '${courantes.length - nbErreurs - nbAlertes} info(s)/succès')
      ..writeln();

    tampon.writeln('--- COMPTEURS PAR MODULE (session courante) ---');
    final comptes = <String, int>{};
    for (final e in courantes) {
      comptes[e.module] = (comptes[e.module] ?? 0) + 1;
    }
    final modulesTries = comptes.keys.toList()..sort();
    for (final m in modulesTries) {
      tampon.writeln('  ${m.padRight(14)} ${comptes[m]}');
    }
    if (modulesTries.isEmpty) tampon.writeln('  (aucun)');
    tampon.writeln();

    tampon.writeln('--- LES ROUGES : ERREURS DE CETTE SESSION ---');
    final erreurs = courantes
        .where((e) => e.niveau == NiveauJournal.erreur)
        .toList(growable: false);
    if (erreurs.isEmpty) {
      tampon.writeln('  (aucune erreur enregistrée)');
    } else {
      for (final e in erreurs) {
        _ecrireLigne(tampon, e, '  ');
      }
    }
    tampon.writeln();

    tampon.writeln(
        '--- ALERTES DE CETTE SESSION (orange : ça marche, mais attention) ---');
    final alertes = courantes
        .where((e) => e.niveau == NiveauJournal.attention)
        .toList(growable: false);
    if (alertes.isEmpty) {
      tampon.writeln('  (aucune alerte)');
    } else {
      for (final e in alertes) {
        _ecrireLigne(tampon, e, '  ');
      }
    }
    tampon.writeln();

    tampon.writeln(
        '--- SESSION PRÉCÉDENTE (retrouvée sur disque après relance/plantage) ---');
    if (precedentes.isEmpty) {
      tampon.writeln('  (rien : la session précédente s\'est fermée proprement'
          ' ou aucune sauvegarde)');
    } else {
      for (final e in precedentes) {
        _ecrireLigne(tampon, e, '  ');
      }
    }
    tampon.writeln();

    tampon.writeln(
        '================ CHRONOLOGIE COMPLÈTE (ancien -> récent) ================');
    for (final entree in _entrees) {
      _ecrireLigne(tampon, entree, '');
    }
    return tampon.toString();
  }

  /// Décrit l'environnement d'exécution : plateforme, langue, écran.
  String _decrireEnvironnement() {
    final morceaux = <String>[];
    try {
      final plateforme = defaultTargetPlatform.name;
      morceaux.add(plateforme.replaceFirst('TargetPlatform.', ''));
    } catch (_) {}
    try {
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      morceaux.add('locale=${dispatcher.locale}');
      final vue = dispatcher.views.isEmpty ? null : dispatcher.views.first;
      if (vue != null) {
        morceaux.add(
          'ecran=${vue.physicalSize.width.round()}x'
          '${vue.physicalSize.height.round()}px@${vue.devicePixelRatio}x',
        );
      }
    } catch (_) {}
    return morceaux.isEmpty ? 'inconnu' : morceaux.join(', ');
  }

  void _ecrireLigne(StringBuffer tampon, EntreeJournal entree, String marge) {
    tampon.write(marge);
    tampon.write(entree.sequence.toString().padLeft(4, '0'));
    tampon.write(entree.precedente ? '(S-1) ' : ' ');
    tampon.write(entree.heureFormatee);
    tampon.write(' │ ');
    tampon.write(entree.libelleNiveau.padRight(8));
    tampon.write(' │ ');
    tampon.write(entree.module.padRight(11));
    tampon.write(' │ ');
    tampon.write(entree.message);
    final details = entree.detailsFormates;
    if (details.isNotEmpty) tampon.write('  [$details]');
    tampon.writeln();
  }
}
