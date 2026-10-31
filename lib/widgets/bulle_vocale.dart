import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';
import '../theme/kinflow_theme.dart';
import 'avatar_animal.dart';

/// Bulle d'un message vocal, au format « WhatsApp » :
///
///  - une FORME D'ONDE (barres suivant l'amplitude de la voix) remplace la
///    ligne plate : ce qui est déjà écouté s'éclaire, le reste demeure terne ;
///  - un POINT DE LECTURE glisse de gauche à droite et peut être saisi pour
///    avancer ou reculer dans l'audio ; pendant le glissement, une bulle
///    affiche le temps visé et l'audio suit en direct (comme WhatsApp) ;
///  - le TEMPS ÉCOULÉ s'affiche à gauche, la DURÉE TOTALE à droite ;
///  - un bouton de VITESSE bascule directement ×1 → ×1,5 → ×2 → ×1.
///  - le ROND DE L'ANIMAL est posé À L'INTÉRIEUR de la bulle, juste à gauche
///    du triangle de lecture, pour un vocal reçu COMME pour un vocal envoyé ;
///    pendant la lecture, l'animal reste visible et une petite icône
///    « personne qui parle » s'ajoute dans le rond. Une seule bulle joue à la
///    fois, et un appui en fin de piste relance depuis le début.
///
/// L'audio est lu soit depuis un fichier local (message en cours d'envoi), soit
/// depuis une URL signée résolue à la volée (message déjà reçu).
class BulleVocale extends StatefulWidget {
  const BulleVocale({
    super.key,
    this.cheminLocal,
    this.resoudreSource,
    required this.dureeMs,
    required this.moi,
    required this.heure,
    this.indicateur,
    this.formes,
    this.graine,
    this.avatarId,
    this.userId,
    this.onAvatarTap,
  });

  /// Fichier déjà présent sur l'appareil (optimiste : message que je viens
  /// d'enregistrer, lu immédiatement sans passer par le réseau).
  final String? cheminLocal;

  /// Résout la source jouable (URL signée, chemin distant…) pour les messages
  /// déjà stockés côté serveur.
  final Future<String?> Function()? resoudreSource;

  final int dureeMs;
  final bool moi;
  final String heure;
  final Widget? indicateur;

  /// Amplitude de la voix relevée à l'enregistrement (0..1, une valeur par
  /// barre). Null ou vide = pas de données : une forme d'onde stable est alors
  /// dessinée à partir de [graine], pour que la bulle ne soit jamais une ligne
  /// plate.
  final List<double>? formes;

  /// Identifiant stable du message : graine de la forme d'onde de secours, afin
  /// qu'elle reste identique d'un affichage à l'autre.
  final String? graine;

  /// Avatar animal de la personne qui parle : son rond s'affiche À L'INTÉRIEUR
  /// de la bulle, à gauche du triangle de lecture. Renseigné dans les deux sens
  /// (mon animal pour mes vocaux, le sien pour les vocaux reçus).
  final String? avatarId;

  /// Identifiant de la personne qui parle : sert à charger son grade et à
  /// l'afficher sur l'animal de la bulle.
  final String? userId;

  /// Appui sur l'animal : ouvre la fiche de la personne en grand (grade
  /// détaillé). Null quand l'animal n'est pas cliquable.
  final VoidCallback? onAvatarTap;

  @override
  State<BulleVocale> createState() => _BulleVocaleState();
}

class _BulleVocaleState extends State<BulleVocale> {
  /// Vitesses proposées par le bouton, dans l'ordre de défilement.
  static const List<double> _vitesses = [1.0, 1.5, 2.0];

  /// Nombre de barres de la forme d'onde de secours.
  static const int _barresParDefaut = 34;

  /// Bulle qui joue actuellement : une seule à la fois (comme WhatsApp). Elle
  /// sert aussi à savoir quelle icône « personne qui parle » afficher.
  static _BulleVocaleState? _celleQuiJoue;

  final AudioPlayer _lecteur = AudioPlayer();
  bool _lectureEnCours = false;

  /// Évite deux appuis rapprochés de lancer deux lectures concurrentes.
  bool _transition = false;
  bool _chargementSource = false;
  String? _source;
  bool _sourceEstUrl = false;

  /// Vrai dès que [AudioPlayer.setSource] a été appelé pour [_source] : évite
  /// de recharger l'audio à chaque pause/reprise et permet de SEEKer sans
  /// démarrer la lecture.
  bool _sourceChargee = false;

  /// Vrai quand la lecture est allée au bout : le prochain appui sur lecture
  /// doit repartir de zéro, car certains lecteurs restent alors « collés » à
  /// la dernière milliseconde.
  bool _termine = false;

  Duration _position = Duration.zero;
  Duration _duree = Duration.zero;
  double _vitesse = 1.0;

  /// Fraction (0..1) visée pendant un glissement sur la forme d'onde : la tête
  /// de lecture suit le doigt avant que l'audio ne soit réellement déplacé
  /// (le seek n'est appliqué qu'au relâchement, pour ne pas hacher la lecture).
  double? _apercuFraction;

  late List<double> _formes;

  StreamSubscription<PlayerState>? _etatSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _dureeSub;

  @override
  void initState() {
    super.initState();
    _duree = Duration(milliseconds: widget.dureeMs.clamp(0, 3600000));
    _formes = _formesDAfficher();
    _chercherFichierLocal();
    _etatSub = _lecteur.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      final joue = s == PlayerState.playing;
      if (joue) {
        _celleQuiJoue = this;
      } else if (_celleQuiJoue == this) {
        // Pause, arrêt ou fin : plus personne ne parle.
        _celleQuiJoue = null;
      }
      setState(() => _lectureEnCours = joue);
      if (s == PlayerState.completed) {
        setState(() {
          _position = Duration.zero;
          _termine = true;
        });
      }
    });
    _posSub = _lecteur.onPositionChanged.listen((d) {
      if (!mounted || _apercuFraction != null) return;
      setState(() {
        _position = d;
        // Filet de sécurité : certaines plateformes n'émettent pas
        // `completed`. On marque nous-mêmes la fin pour que l'appui suivant
        // relance au lieu de rester bloqué sur la dernière milliseconde.
        final total = _dureeEffective;
        if (total > Duration.zero && d >= total) _termine = true;
      });
    });
    _dureeSub = _lecteur.onDurationChanged.listen((d) {
      if (!mounted || d == Duration.zero) return;
      setState(() => _duree = d);
    });
  }

  // --- Forme d'onde ---------------------------------------------------------

  /// Barres réellement affichées : celles de l'enregistrement si on les a, une
  /// forme d'onde stable sinon.
  List<double> _formesDAfficher() {
    final fournies = widget.formes;
    if (fournies != null && fournies.isNotEmpty) {
      return [for (final v in fournies) v.clamp(0.0, 1.0)];
    }
    // Forme de secours : même message, même dessin (empreinte stable, et non
    // `String.hashCode` qui peut varier d'une exécution à l'autre).
    final graine = widget.graine ?? '${widget.dureeMs}|${widget.heure}';
    final rnd = math.Random(_empreinte(graine));
    final brut = [
      for (var i = 0; i < _barresParDefaut; i++) 0.18 + rnd.nextDouble() * 0.82,
    ];
    // Léger lissage : une voix ne saute pas brutalement d'une barre à l'autre.
    return [
      for (var i = 0; i < brut.length; i++)
        (((i > 0 ? brut[i - 1] : brut[i]) +
                    brut[i] +
                    (i < brut.length - 1 ? brut[i + 1] : brut[i])) /
                3)
            .clamp(0.12, 1.0),
    ];
  }

  /// Empreinte FNV-1a : stable entre plateformes et exécutions.
  static int _empreinte(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  // --- Lecture --------------------------------------------------------------

  /// Vérifie (sans réseau) si le fichier local existe encore : il permet une
  /// lecture immédiate, même hors connexion, pour un envoi tout juste fait.
  Future<void> _chercherFichierLocal() async {
    final local = widget.cheminLocal;
    if (local == null || local.isEmpty) return;
    if (await File(local).exists()) {
      if (!mounted) return;
      setState(() {
        _source = local;
        _sourceEstUrl = false;
        _sourceChargee = false;
      });
    }
  }

  /// Résolution réseau en cours : les seeks rapprochés du glissement
  /// (toutes les 140 ms) ne doivent pas lancer plusieurs résolutions
  /// concurrentes — elles partageraient le même [_chargementSource] et la
  /// seconde conclurait à tort « vocal indisponible ». On attend la même
  /// résolution pour tous les appelants.
  Future<void>? _resolutionEnCours;

  /// Résout la source réseau (URL signée) à la demande, uniquement au premier
  /// appui sur lecture (ou premier déplacement) : pas d'appel inutile pour les
  /// bulles jamais écoutées.
  Future<void> _resoudreSourceDistante() {
    if (_source != null) return Future.value();
    final deja = _resolutionEnCours;
    if (deja != null) return deja;
    final futur = _chargerSourceDistante();
    _resolutionEnCours = futur.whenComplete(() => _resolutionEnCours = null);
    return _resolutionEnCours!;
  }

  Future<void> _chargerSourceDistante() async {
    final resolver = widget.resoudreSource;
    if (resolver == null) return;
    setState(() => _chargementSource = true);
    String? src;
    try {
      src = await resolver();
    } catch (e) {
      Journal.e('SOCIAL', 'Résolution de l\'adresse du vocal échouée', {
        'erreur': '$e',
      });
      src = null;
    }
    if (!mounted) return;
    setState(() {
      _chargementSource = false;
      if (src != null && src.isNotEmpty) {
        _source = src;
        _sourceEstUrl = src.startsWith('http://') || src.startsWith('https://');
        _sourceChargee = false;
      }
    });
    if (src == null || src.isEmpty) {
      Journal.a('SOCIAL', 'Adresse du vocal introuvable (URL signée)');
      _signaler('Message vocal indisponible.');
    }
  }

  /// Charge la source si nécessaire. Retourne false (après avoir prévenu
  /// l'utilisateur) si aucun audio n'est jouable.
  Future<bool> _preparerSource() async {
    if (_source == null) {
      await _chercherFichierLocal();
      if (_source == null) await _resoudreSourceDistante();
    }
    final src = _source;
    if (src == null) {
      // S'il y avait une source à résoudre, [_resoudreSourceDistante] a déjà
      // prévenu l'utilisateur : on n'ajoute pas une seconde alerte.
      if (widget.resoudreSource == null) {
        _signaler('Message vocal indisponible.');
      }
      return false;
    }
    if (_sourceChargee) return true;
    try {
      await _lecteur.setSource(
        _sourceEstUrl ? UrlSource(src) : DeviceFileSource(src),
      );
      _sourceChargee = true;
      // Le débit se perd à chaque (re)chargement : on le réapplique.
      await _appliquerVitesse();
      return true;
    } catch (e) {
      Journal.e('SOCIAL', 'Chargement du vocal impossible', {
        'erreur': '$e',
        'url': _sourceEstUrl ? 'oui' : 'non',
      });
      _signaler('Lecture impossible.');
      return false;
    }
  }

  /// Vrai quand la tête de lecture a atteint la fin (ou presque) : un appui
  /// doit alors RELANCER la lecture au lieu de la mettre en pause.
  bool get _auBout {
    final total = _dureeEffective;
    if (total <= Duration.zero) return false;
    return _termine || _position >= total - const Duration(milliseconds: 250);
  }

  /// Met en pause les autres bulles : une seule lecture à la fois.
  void _prendreLaParole() {
    final autre = _celleQuiJoue;
    if (autre != null && autre != this) {
      unawaited(autre._pauseDepuisUneAutreBulle());
    }
    _celleQuiJoue = this;
  }

  Future<void> _pauseDepuisUneAutreBulle() async {
    try {
      await _lecteur.pause();
    } catch (_) {}
    if (mounted) setState(() => _lectureEnCours = false);
  }

  Future<void> _basculerLecture() async {
    if (_transition) return;
    _transition = true;
    try {
      // Fin de piste : on repart de zéro. On ne se fie pas uniquement à
      // l'événement `completed` (absent sur certaines plateformes), sinon le
      // bouton restait bloqué en pause et le même vocal était impossible à
      // réécouter.
      if (_auBout) {
        _termine = false;
        _lectureEnCours = false;
        if (mounted) setState(() => _position = Duration.zero);
        if (!await _preparerSource()) return;
        final src = _source;
        if (src == null) return;
        _prendreLaParole();
        try {
          // `play` recharge la source et repart du début : plus fiable que
          // `resume` après la fin (le lecteur peut rester « collé »).
          await _lecteur.play(
            _sourceEstUrl ? UrlSource(src) : DeviceFileSource(src),
          );
          _sourceChargee = true;
          await _appliquerVitesse();
        } catch (e) {
          Journal.e('SOCIAL', 'Relecture du vocal impossible', {
            'erreur': '$e',
          });
          _signaler('Lecture impossible.');
        }
        return;
      }

      if (_lectureEnCours) {
        try {
          await _lecteur.pause();
        } catch (_) {}
        return;
      }

      if (!await _preparerSource()) return;
      _prendreLaParole();
      _termine = false;
      await _lecteur.resume();
    } catch (e) {
      Journal.e('SOCIAL', 'Lecture du vocal impossible', {'erreur': '$e'});
      _signaler('Lecture impossible.');
    } finally {
      _transition = false;
    }
  }

  /// Fait défiler ×1 → ×1,5 → ×2 → ×1 au simple appui.
  Future<void> _basculerVitesse() async {
    final index = _vitesses.indexOf(_vitesse);
    final suivant = _vitesses[(index + 1) % _vitesses.length];
    setState(() => _vitesse = suivant);
    await _appliquerVitesse();
  }

  Future<void> _appliquerVitesse() async {
    try {
      await _lecteur.setPlaybackRate(_vitesse);
    } catch (e) {
      // Certaines plateformes (web ancien) refusent le changement de débit :
      // dégradation silencieuse, l'audio continue simplement en ×1.
      Journal.a('SOCIAL', 'Vitesse de lecture refusée', {'erreur': '$e'});
    }
  }

  // --- Navigation dans l'audio ---------------------------------------------

  /// Dernier seek appliqué PENDANT un glissement : sert à limiter la cadence
  /// (~7 par seconde) pour que l'audio suive le doigt sans hachurer.
  DateTime? _dernierSeekGlisse;

  /// Déplace la lecture à [fraction] (0..1) de la piste.
  ///
  /// [silencieux] : utilisé pendant le glissement — un échec répété toutes les
  /// 140 ms ne doit pas inonder le journal. Le seek final (au relâchement)
  /// reste, lui, toujours signalé.
  Future<void> _seekVersFraction(
    double fraction, {
    bool silencieux = false,
  }) async {
    if (!await _preparerSource()) return;
    final total = _dureeEffective;
    if (total <= Duration.zero) return;
    final cible = Duration(
      milliseconds: (total.inMilliseconds * fraction.clamp(0.0, 1.0)).round(),
    );
    try {
      await _lecteur.seek(cible);
      // Se déplacer avant la fin remet la piste « en cours » : sans cela,
      // revenir en arrière après la fin laissait [_termine] à vrai et le
      // prochain appui sur lecture repartait de zéro au lieu de lire depuis
      // la position choisie.
      _termine = cible >= total;
      if (mounted) setState(() => _position = cible);
    } catch (e) {
      if (!silencieux) {
        Journal.a('SOCIAL', 'Déplacement dans le vocal impossible', {
          'erreur': '$e',
        });
      }
    }
  }

  /// Suit le doigt sur la forme d'onde : met à jour l'aperçu et déplace
  /// l'audio en direct (throttlé), au lieu d'attendre le relâchement. C'est le
  /// comportement de WhatsApp : on entend immédiatement l'endroit visé.
  void _apercevoir(double dx, double largeur) {
    if (largeur <= 0) return;
    final fraction = (dx / largeur).clamp(0.0, 1.0);
    setState(() => _apercuFraction = fraction);

    final maintenant = DateTime.now();
    final dernier = _dernierSeekGlisse;
    if (dernier != null &&
        maintenant.difference(dernier).inMilliseconds < 140) {
      return;
    }
    _dernierSeekGlisse = maintenant;
    unawaited(_seekVersFraction(fraction, silencieux: true));
  }

  void _validerApercu() {
    final fraction = _apercuFraction;
    _dernierSeekGlisse = null;
    if (fraction == null) return;
    setState(() => _apercuFraction = null);
    unawaited(_seekVersFraction(fraction));
  }

  /// Annule un aperçu sans déplacer la lecture (annulation du geste).
  void _annulerApercu() {
    _dernierSeekGlisse = null;
    setState(() => _apercuFraction = null);
  }

  void _signaler(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Rendu ----------------------------------------------------------------

  Duration get _dureeEffective => _duree.inMilliseconds == 0
      ? Duration(milliseconds: widget.dureeMs.clamp(0, 3600000))
      : _duree;

  double get _progression {
    final apercu = _apercuFraction;
    if (apercu != null) return apercu;
    final total = _dureeEffective.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  String _formaterDuree(Duration d) {
    final sec = d.inSeconds % 60;
    final min = d.inMinutes % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String get _libelleVitesse => _libelleVitessePour(_vitesse);

  String _libelleVitessePour(double vitesse) {
    final entier = vitesse == vitesse.roundToDouble();
    final texte = entier
        ? vitesse.toStringAsFixed(0)
        : vitesse.toStringAsFixed(1).replaceAll('.', ',');
    return '$texte×';
  }

  @override
  void dispose() {
    if (_celleQuiJoue == this) _celleQuiJoue = null;
    _etatSub?.cancel();
    _posSub?.cancel();
    _dureeSub?.cancel();
    _lecteur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moi = widget.moi;
    final fond = moi ? KinColors.vertArrivee : KinColors.bleu;
    final progression = _progression;
    final total = _dureeEffective;
    // Temps écoulé (ou temps VISÉ pendant un glissement) à gauche, durée
    // totale à droite : la disposition de WhatsApp.
    final positionVisible = _apercuFraction != null
        ? Duration(milliseconds: (total.inMilliseconds * progression).round())
        : _position;
    final texteEcoule = _formaterDuree(positionVisible);
    final texteTotal = _formaterDuree(total);
    // Le rond de l'animal est posé À L'INTÉRIEUR de la bulle, à gauche du
    // triangle de lecture, dans les deux sens : on lui réserve la place dans
    // la largeur maximale pour que la bulle ne déborde jamais de l'écran.
    const tailleAvatar = 34.0;
    const espaceAvatar = 8.0;
    final avatarId = widget.avatarId;
    final avecAvatar = avatarId != null && avatarId.isNotEmpty;
    // La largeur minimale ne doit jamais dépasser la largeur maximale (écrans
    // très étroits), sinon BoxConstraints lève une assertion.
    final largeurMax = math.max(
      0.0,
      MediaQuery.of(context).size.width * 0.75 -
          (avecAvatar ? tailleAvatar + espaceAvatar : 0.0),
    );
    const largeurMinSouhaitee = 196.0;

    final bulle = Container(
      margin: const EdgeInsets.fromLTRB(10, 3, 10, 3),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      constraints: BoxConstraints(
        maxWidth: largeurMax,
        minWidth: math.min(largeurMinSouhaitee, largeurMax),
      ),
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Rond de l'animal (le mien ou celui de l'ami(e)), PUIS le
              // triangle de lecture : l'ordre demandé, à gauche du contenu.
              if (avecAvatar) ...[
                _pastilleAnimal(tailleAvatar, fond),
                const SizedBox(width: espaceAvatar),
              ],
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: Colors.white24,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: _chargementSource
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _lectureEnCours ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                  onPressed: _chargementSource ? null : _basculerLecture,
                  tooltip: _lectureEnCours ? 'Pause' : 'Lire',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _formeOnde(progression),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          texteEcoule,
                          style: TextStyle(
                            fontSize: 11,
                            // Pendant un glissement, le temps affiché est le
                            // temps VISÉ : on le met en gras pour qu'il se
                            // distingue nettement du temps de lecture.
                            fontWeight: _apercuFraction != null
                                ? FontWeight.w800
                                : FontWeight.w400,
                            color: Colors.white70,
                          ),
                        ),
                        const Spacer(),
                        _boutonVitesse(),
                        const SizedBox(width: 8),
                        Text(
                          texteTotal,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.heure,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
              if (moi && widget.indicateur != null) ...[
                const SizedBox(width: 4),
                widget.indicateur!,
              ],
            ],
          ),
        ],
      ),
    );

    // Bulle alignée à droite (mes vocaux) ou à gauche (vocaux reçus). L'animal
    // est à l'intérieur : plus de colonne d'avatar à côté de la bulle.
    return Align(
      alignment: moi ? Alignment.centerRight : Alignment.centerLeft,
      child: bulle,
    );
  }

  /// Rond de la personne qui parle, posé DANS la bulle à gauche du triangle.
  ///
  /// Au repos, c'est l'animal (mon avatar ou celui de l'ami(e)). Pendant la
  /// lecture, l'animal RESTE visible et une petite icône « personne qui
  /// parle » (égaliseur) vient se poser en bas à droite du rond, dans un
  /// pastille blanche cerclée de la couleur de la bulle : on voit d'un coup
  /// d'œil qui parle sans perdre l'animal.
  Widget _pastilleAnimal(double taille, Color fond) {
    final animal = AvatarAnimalWidget(
      taille: taille,
      avatarId: widget.avatarId,
      userId: widget.userId,
    );
    final pastille = widget.onAvatarTap == null
        ? animal
        : GestureDetector(onTap: widget.onAvatarTap, child: animal);
    if (!_lectureEnCours) return pastille;
    final tailleBadge = taille * 0.46;
    return SizedBox(
      width: taille,
      height: taille,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          pastille,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: tailleBadge,
              height: tailleBadge,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: fond, width: 1.5),
              ),
              child: Icon(
                Icons.graphic_eq,
                size: tailleBadge * 0.62,
                color: fond,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Forme d'onde interactive : taper ou glisser dessus déplace la lecture.
  /// Pendant le glissement, l'audio suit en direct et une petite étiquette
  /// affiche le temps visé au-dessus du point de lecture (comme WhatsApp).
  Widget _formeOnde(double progression) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final largeur = constraints.maxWidth;
        final apercu = _apercuFraction;
        final fraction = apercu ?? progression;
        const largeurEtiquette = 44.0;
        final gauche = (fraction * largeur - largeurEtiquette / 2)
            .clamp(0.0, math.max(0.0, largeur - largeurEtiquette))
            .toDouble();
        final tempsVise = Duration(
          milliseconds: (_dureeEffective.inMilliseconds * fraction).round(),
        );

        return Stack(
          // L'étiquette dépasse légèrement au-dessus de l'onde : la bulle ne
          // rogne pas ses enfants, elle reste visible pendant le geste.
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _apercevoir(d.localPosition.dx, largeur),
              onTapUp: (_) => _validerApercu(),
              onTapCancel: _annulerApercu,
              onHorizontalDragStart: (d) =>
                  _apercevoir(d.localPosition.dx, largeur),
              onHorizontalDragUpdate: (d) =>
                  _apercevoir(d.localPosition.dx, largeur),
              onHorizontalDragEnd: (_) => _validerApercu(),
              onHorizontalDragCancel: _annulerApercu,
              child: CustomPaint(
                size: Size(largeur, 30),
                painter: _PeintreFormeOnde(
                  formes: _formes,
                  progression: fraction,
                ),
              ),
            ),
            if (apercu != null)
              Positioned(
                left: gauche,
                top: -8,
                width: largeurEtiquette,
                child: IgnorePointer(
                  child: Container(
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _formaterDuree(tempsVise),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Pastille de vitesse : cycle direct ×1 → ×1,5 → ×2 → ×1 au tap.
  Widget _boutonVitesse() {
    return GestureDetector(
      onTap: _basculerVitesse,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          _libelleVitesse,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Dessine la forme d'onde : barres claires pour la partie écoutée, barres
/// ternes pour le reste, et un point de lecture qui marque la position.
class _PeintreFormeOnde extends CustomPainter {
  _PeintreFormeOnde({required this.formes, required this.progression});

  final List<double> formes;
  final double progression;

  @override
  void paint(Canvas canvas, Size size) {
    if (formes.isEmpty || size.width <= 0 || size.height <= 0) return;
    final n = formes.length;
    final pas = size.width / n;
    final largeurBarre = math.min(3.0, pas * 0.62);
    final hauteurUtile = size.height - 6;
    final centreY = size.height / 2;
    final xLecture = progression * size.width;

    final pinceauJoue = Paint()..color = Colors.white;
    final pinceauReste = Paint()..color = Colors.white38;
    for (var i = 0; i < n; i++) {
      final x = (i + 0.5) * pas;
      final hauteur = (formes[i] * hauteurUtile).clamp(3.0, hauteurUtile);
      final barre = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, centreY),
          width: largeurBarre,
          height: hauteur,
        ),
        Radius.circular(largeurBarre / 2),
      );
      canvas.drawRRect(barre, x <= xLecture ? pinceauJoue : pinceauReste);
    }

    // Point de lecture : petit disque blanc cerclé de sombre pour rester
    // visible aussi bien sur les barres claires que sur les ternes.
    final centre = Offset(xLecture, centreY);
    canvas.drawCircle(centre, 4.5, Paint()..color = Colors.white);
    canvas.drawCircle(
      centre,
      4.5,
      Paint()
        ..color = Colors.black26
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _PeintreFormeOnde ancien) =>
      ancien.progression != progression || !identical(ancien.formes, formes);
}
