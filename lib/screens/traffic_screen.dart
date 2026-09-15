import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../main.dart' show tileDownloadService;
import '../config/carte.dart' show bornesAfrique;
import '../models/route_result.dart';
import '../models/search_result.dart';
import '../services/compass_service.dart';
import '../services/diagnostics_service.dart';
import '../services/itineraire_service.dart';
import '../services/location_service.dart';
import '../services/route_service.dart';
import '../services/search_service.dart';
import '../services/supabase_service.dart';
import '../services/traffic_service.dart';
import '../services/traffic_stats_service.dart';
import '../services/vue_itineraire.dart' show calculerVueItineraire;
import '../theme/kinflow_theme.dart';
import '../utils/formatage.dart' show formaterDistance, formaterDuree, formaterHeure;
import '../utils/geo.dart' show deltaRotation, distanceALignes, distanceMetres, normaliserDegre, projeterSurAlignes, rotationTrace;
import '../widgets/traffic_map.dart';
import '../widgets/traffic_panel.dart';
import '../widgets/traffic_questionnaire.dart';
import '../widgets/traffic_state_sheet.dart';
import 'diagnostics_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class TrafficScreen extends StatefulWidget {
  const TrafficScreen({super.key});

  @override
  State<TrafficScreen> createState() => _TrafficScreenState();
}

/// Écran principal : carte de trafic + itinéraires + signalements.
///
/// Toute la logique opérationnelle (position, boussole, navigation, itinéraire,
/// déviation, signalements, recherche) est regroupée par domaine pour rester
/// lisible alors que l'interface reste un [Stack] de couches superposées.
class _TrafficScreenState extends State<TrafficScreen>
    with TickerProviderStateMixin {
  // ---------------------------------------------------------------------------
  // Services
  // ---------------------------------------------------------------------------

  final MapController mapController = MapController();
  final LocationService locationService = LocationService();
  final TrafficService trafficService = TrafficService();
  final SearchService searchService = SearchService();
  final CompassService compassService = CompassService();
  final RouteService routeService = RouteService();
  final ItineraireService itineraireService = ItineraireService();

  // ---------------------------------------------------------------------------
  // État de la carte
  // ---------------------------------------------------------------------------

  bool cartePrete = false;
  bool afficherPositionUtilisateur = false;
  bool chargementPosition = false;
  bool afficherLignesTrafic = true;

  /// Quand vrai, le panneau inférieur (boutons « Ma position »…) est replié :
  /// seule la barre d'état (recentrer + polylignes + rue/avenue) reste visible
  /// tout en bas, pour agrandir le champ de vision sur la carte.
  bool _panneauRetraissi = false;

  Position? positionActuelle;
  LatLng? lieuRecherche;
  LatLng? epingle;

  // Actions contextuelles attachées à un point touché.
  LatLng? pointActions;
  bool actionsSurEpingle = false;
  bool actionsSurPosition = false;
  bool afficherActionsPosition = false;

  bool carteSurLieuRecherche = false;
  bool carteSurDestination = false;
  String? dernierLieuRecherche;

  // ---------------------------------------------------------------------------
  // Boussole (oriente uniquement le marqueur utilisateur)
  // ---------------------------------------------------------------------------

  double direction = 0;
  StreamSubscription<double?>? _compassSub;
  DateTime? _dernierUpdateBoussole;
  bool _boussoleAnnoncee = false;

  // ---------------------------------------------------------------------------
  // Flux de position (GPS continu)
  // ---------------------------------------------------------------------------

  StreamSubscription<Position>? positionStream;

  /// Dernière position GPS acceptée par le filtre anti-bruit, horodatée.
  /// À l'arrêt le GPS dérive de quelques mètres : tant que le téléphone n'a
  /// pas réellement avancé, on ne bouge pas le point bleu d'une fix à l'autre.
  (LatLng, DateTime)? _positionAcceptee;

  /// Vitesse effective minimale (m/s) en dessous de laquelle une fix n'est
  /// pas considérée comme un réel déplacement. On mesure la distance depuis
  /// la dernière position acceptée sur le temps écoulé (≃ vitesse de marche
  /// lente), car la vitesse GPS brute est souvent annoncée 0,0 en marchant —
  /// ce qui figeait le point bleu et bloquait la règle 10°/5 m.
  static const double _seuilVitesseEffectiveMs = 0.45;

  /// Seuil (mètres) : en dessous d'une réelle avancée, un déplacement GPS
  /// plus court que ce seuil alors que la vitesse effective est quasi nulle
  /// est traité comme du bruit de mesure et ignoré.
  static const double _seuilBruitPositionMetres = 5.0;

  /// Distance minimale (mètres) d'un itinéraire exploitable. En dessous de ce
  /// seuil le trajet est jugé trop court (départ et arrivée quasi confondus) :
  /// le calcul est refusé avec le motif « distance trop courte ».
  static const double _distanceMinItineraireMetres = 100.0;

  // ---------------------------------------------------------------------------
  // Mode navigation : la carte suit la position et pivote selon le cap
  // ---------------------------------------------------------------------------

  bool modeNavigation = false;
  double? capUtilisateur;
  Timer? _repriseNavTimer;

  bool _centrerQuandPrete = false;
  bool _centrerPremiereFois = false;
  VoidCallback? _centrerApres; // Rappel différé lorsque la carte n'était pas prête

  /// Ajustement de la vue sur un itinéraire demandé alors que la carte
  /// n'était pas encore prête (FMTC en cours d'initialisation) : rejoué
  /// dès que le rendu est disponible, au lieu d'être perdu silencieusement.
  List<LatLng>? _vueItineraireEnAttente;
  VoidCallback? _apresVueItineraireEnAttente;

  // Animation caméra pilotée par un ticker (centrage, vue d'ensemble).
  Ticker? _suiviTicker;
  LatLng? _suiviCentre;
  double? _suiviZoom;
  double? _suiviRotation;
  Offset _suiviOffset = Offset.zero;
  DateTime? _suiviDebut;
  Duration _suiviDuree = const Duration(milliseconds: 1800);
  LatLng? _debutCentre;
  double _debutZoom = 0;
  double _debutRotation = 0;
  VoidCallback? _apresSuivi;

  // ---------------------------------------------------------------------------
  // Itinéraire
  // ---------------------------------------------------------------------------

  RouteResult? _itineraire;
  bool _chargementItineraire = false;

  /// Vrai quand le moteur local a dû chercher au-delà du premier palier de
  /// routes (les 5 premières lignes ne convenant pas) : l'indicateur de
  /// calcul affiche alors « Réflexion profonde... ».
  bool _rechercheItineraireElargie = false;

  /// Vrai du début du calcul de l'itinéraire jusqu'à son terme (tracé
  /// affiché, annulation ou échec) : toute l'activité de la carte (routes,
  /// POIs, tuiles, polylignes) est suspendue pour laisser la priorité au
  /// calcul moteur local + secours OSRM.
  bool _travaillerCarteSuspendu = false;

  LatLng? _arriveeItineraire;
  final List<LatLng> _etapes = [];
  bool _lignesTraficAvantItineraire = true;

  /// Segments (id OSM) du réseau chargé qui forment le tracé bleu → vert,
  /// fournis par le moteur local : la carte n'affiche QUE ces polylignes
  /// colorées pendant l'itinéraire (rien n'est re-tracé).
  List<int>? _itineraireSegmentIds;

  /// Zones de trafic signalées, reçues de la carte : elles orientent le
  /// moteur local (éviter les bouchons) quand OSRM est injoignable.
  List<ZoneTrafic> _zonesTrafic = [];

  int _versionZonesTrafic = 0;

  bool actionsSurDestination = false;
  bool actionsSurEtape = false;
  bool _dialogueDeviationOuvert = false;
  int _generationItineraire = 0;

  /// Bannière de l'itinéraire : distance et durée restantes affichées. Elles
  /// ne changent pas en continu : elles restent figées entre deux paliers,
  /// recalculées seulement à chaque 1/5 du trajet (20 %, 40 %, 60 %, 80 %,
  /// arrivée). Discret : seuls les chiffres bougent, aucun message.
  double _banniereDistanceRestante = 0;
  double _banniereDureeRestante = 0;
  static const List<double> _paliersBanniere = [0.8, 0.6, 0.4, 0.2, 0.0];
  int _bannierePalier = 0;

  /// Étape(s) en place AVANT la recherche en cours : si l'utilisateur annule
  /// le calcul (croix de l'indicateur), on les restaure pour ne pas laisser
  /// un drapeau sans tracé recalculé.
  List<LatLng> _etapesAvantRecherche = const [];

  // ---------------------------------------------------------------------------
  // Signalement
  // ---------------------------------------------------------------------------

  String etatActuel = "Aucun signalement";
  bool _propositionSignalementOuverte = false;
  bool afficherQuestionnaire = false;

  // ---------------------------------------------------------------------------
  // Quartier / rue du point bleu (géocodage inverse de la position courante)
  // ---------------------------------------------------------------------------

  String _ruePosition = '';
  String _avenuePosition = '';
  Position? _derniereZonePosition;
  DateTime? _dernierGeocodageZone;

  Future<void> _mettreAJourZonePosition(Position? position) async {
    if (position == null) return;
    final precedente = _derniereZonePosition;
    if (precedente != null) {
      final metres = const Distance().distance(
        LatLng(precedente.latitude, precedente.longitude),
        LatLng(position.latitude, position.longitude),
      );
      final dernier = _dernierGeocodageZone;
      if (metres < 100 &&
          dernier != null &&
          DateTime.now().difference(dernier).inMinutes < 2) {
        return;
      }
      if (metres < 20) return;
    }
    _dernierGeocodageZone = DateTime.now();
    // Position « demandée » mise à jour IMMÉDIATEMENT (avant l'await) : les
    // fixes GPS qui arrivent pendant la requête comparent à ce nouveau point,
    // ils ne re-spawnent donc pas 50 requêtes identiques en parallèle.
    _derniereZonePosition = position;
    try {
      final voies = await searchService.voiesRueAvenueProches(
        position.latitude,
        position.longitude,
      );
      if (!mounted) return;
      if (voies.rue.isNotEmpty || voies.avenue.isNotEmpty) {
        setState(() {
          _ruePosition = voies.rue;
          _avenuePosition = voies.avenue;
        });
        return;
      }
      // Repli sur l'ancien comportement : Nominatim donne une seule voie.
      final info = await searchService.obtenirInfosLieu(
        position.latitude,
        position.longitude,
      );
      if (!mounted) return;
      final nomVoie = info?.rue ?? '';
      final estAvenue = nomVoie
          .toLowerCase()
          .startsWith('av');
      setState(() {
        _ruePosition = estAvenue ? '' : nomVoie;
        _avenuePosition = estAvenue ? nomVoie : '';
      });
    } catch (_) {}
  }


  // ---------------------------------------------------------------------------
  // Téléchargement de tuiles (barre de progression en haut de carte)
  // ---------------------------------------------------------------------------

  double _tileProgress = 0;
  String _tileStatus = '';

  StreamSubscription<double>? _tileProgressSub;
  StreamSubscription<String>? _tileStatusSub;

  // ---------------------------------------------------------------------------
  // Cycle de vie
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    Journal.i('ECRAN', 'Écran de trafic ouvert');
    demarrerBoussole();
    verifierDernierSignalement();
    chargerEtatActuel();
    _ecouterTelechargementTuiles();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activerGpsPourTrafic();
    });
  }

  /// Au premier affichage du trafic, s'assure que le GPS du téléphone est
  /// allumé : s'il est coupé, ouvre les réglages pour forcer l'utilisateur
  /// à l'activer (comme pour la position).
  ///
  /// Le point bleu (position + suivi GPS en continu) ne se déclenche
  /// JAMAIS ici : il faut que l'utilisateur appuie sur « Ma position ».
  Future<void> _activerGpsPourTrafic() async {
    if (!mounted) return;
    final active = await locationService.verifierActiverService();
    if (!mounted) return;
    if (!active) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Allumez votre GPS pour voir le trafic en temps réel.",
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _repriseNavTimer?.cancel();
    _suiviTicker?.dispose();
    positionStream?.cancel();
    _compassSub?.cancel();
    _tileProgressSub?.cancel();
    _tileStatusSub?.cancel();
    compassService.dispose();
    super.dispose();
  }

  void _ecouterTelechargementTuiles() {
    _tileProgressSub = tileDownloadService.progress.listen((p) {
      if (mounted) setState(() => _tileProgress = p);
    });
    _tileStatusSub = tileDownloadService.status.listen((s) {
      if (mounted) setState(() => _tileStatus = s);
    });
  }

  // ---------------------------------------------------------------------------
  // Boussole
  // ---------------------------------------------------------------------------

  void demarrerBoussole() {
    _compassSub = compassService.direction.listen((value) {
      if (value != null && !_boussoleAnnoncee) {
        _boussoleAnnoncee = true;
        Journal.i('BOUSSOLE', 'Boussole active', {'cap_initial_deg': value});
      }
      if (value == null) return;
      final maintenant = DateTime.now();
      if (_dernierUpdateBoussole != null &&
          maintenant.difference(_dernierUpdateBoussole!).inMilliseconds < 200) {
        return;
      }
      _dernierUpdateBoussole = maintenant;
      setState(() {
        // La boussole n'oriente que le marqueur utilisateur. Elle ne pilote
        // jamais la rotation de la carte : seule la direction réelle de
        // déplacement (course GPS) est autorisée à la faire pivoter.
        direction = value;
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Signalement de l'état de la route
  // ---------------------------------------------------------------------------

  Future<void> chargerEtatActuel() async {
    final etat = await trafficService.chargerEtat();
    if (!mounted || etat == null) return;
    setState(() => etatActuel = etat);
  }

  Future<void> verifierDernierSignalement() async {
    final heure = await trafficService.chargerHeure();
    if (!mounted) return;

    if (heure != null && !trafficService.peutModifier(heure)) {
      Journal.i(
        'SIGNALEMENT',
        'Droit de signaler non disponible : feuille d\'état non proposée',
      );
    } else {
      Journal.i(
        'SIGNALEMENT',
        'Proposition de l\'état de route à l\'ouverture de la carte',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ouvrirEtatRoutes();
      });
    }
  }

  /// Réouvre automatiquement la fenêtre d'état de route dès que le délai de
  /// re-signalement (15 min) est écoulé, sans intervention de l'utilisateur.
  /// Appelée périodiquement tant que la carte est affichée.
  Future<void> verifierReouvertureSignalement() async {
    if (_propositionSignalementOuverte) return;
    final heure = await trafficService.chargerHeure();
    if (!mounted) return;
    if (heure == null || !trafficService.peutModifier(heure)) return;
    Journal.i(
      'SIGNALEMENT',
      'Délai écoulé : réouverture automatique de la feuille d\'état',
    );
    ouvrirEtatRoutes();
  }

  /// Ouvre la feuille d'état de route (modal moderne). Une seule feuille à la
  /// fois à l'écran.
  Future<void> ouvrirEtatRoutes({String? dernierEtat}) async {
    if (_propositionSignalementOuverte) return;
    _propositionSignalementOuverte = true;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (contextFeuille) => TrafficStateSheet(
        dernierEtat: dernierEtat,
        onChoix: enregistrerSignalement,
      ),
    );

    _propositionSignalementOuverte = false;
  }

  Future<void> enregistrerSignalement(String etat) async {
    Journal.i('SIGNALEMENT', 'Enregistrement de l\'état de la route', {
      'etat': etat,
    });

    // La feuille se ferme aussitôt le choix fait : le reste (envoi serveur,
    // fix GPS éventuel) se déroule en arrière-plan sans bloquer la carte.
    if (mounted) Navigator.of(context).pop();

    await trafficService.enregistrerEtat(etat);

    // Position connue ? On envoie directement. Sinon, on tente un dernier
    // fix GPS avant de renoncer.
    var position = positionActuelle;
    if (position == null) {
      Journal.a(
        'SIGNALEMENT',
        'Aucune position capturée : tentative de fix GPS avant envoi.',
      );
      position = await locationService.obtenirPosition();
      if (position != null && mounted) {
        setState(() => positionActuelle = position);
      }
    }

    if (position != null) {
      await SupabaseService().signalerEtat(
        etat: etat,
        latitude: position.latitude,
        longitude: position.longitude,
        cap: position.heading,
      );
      Journal.s('SIGNALEMENT', 'Signalement envoyé au serveur', {
        'lat': position.latitude,
        'lon': position.longitude,
      });
      if (mounted) {
        setState(() => _versionZonesTrafic++);
      }
    } else {
      Journal.a(
        'SIGNALEMENT',
        'Signalement NON envoyé au serveur : position GPS inconnue.',
      );
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Position GPS requise'),
            content: const Text(
              'Pour que votre signalement soit partagé avec les autres '
              'conducteurs, activez d\'abord le GPS en appuyant sur '
              'le bouton « Ma position ».',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }

    if (!mounted) return;
    setState(() => etatActuel = etat);
  }

  // ---------------------------------------------------------------------------
  // Position utilisateur
  // ---------------------------------------------------------------------------

  Future<void> obtenirPosition() async {
    if (chargementPosition) {
      Journal.a('POSITION', 'Demande ignorée : un fix est déjà en cours');
      return;
    }

    setState(() => chargementPosition = true);
    final aucunMarqueurAvant =
        positionActuelle == null && lieuRecherche == null;

    positionActuelle = await locationService.obtenirPosition();
    if (!mounted) return;

    if (positionActuelle == null) {
      Journal.e('POSITION', 'Aucun fix GPS utilisable : recentrage annulé');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Impossible de trouver votre position. Vérifiez votre GPS.",
          ),
        ),
      );
    }

    setState(() => chargementPosition = false);

    if (positionActuelle != null) {
      setState(() => afficherPositionUtilisateur = true);
      if (positionStream == null) {
        Journal.i('POSITION', 'Démarrage du suivi GPS en continu');
      }
      _mettreAJourZonePosition(positionActuelle);
      suivrePosition();
    }

    if (positionActuelle != null) {
      centrerSurPosition(
        premierePosition: aucunMarqueurAvant,
        apres: activerSuiviNavigation,
      );
    }
  }

  /// Démarre le flux GPS continu, met à jour la position et surveille la
  /// déviation par rapport à l'itinéraire éventuel.
  void suivrePosition() {
    // Journalisation throttlée : le flux peut envoyer plusieurs fixes par
    // seconde ; on ne consigne que les changements significatifs.
    DateTime? dernierFixJournalise;
    Position? dernierePositionJournalisee;

    void journaliserFix(Position position) {
      final maintenant = DateTime.now();
      final precedente = dernierePositionJournalisee;
      var significatif = false;
      if (precedente != null) {
        final metres = const Distance().distance(
          LatLng(precedente.latitude, precedente.longitude),
          LatLng(position.latitude, position.longitude),
        );
        significatif =
            metres > 15 ||
            (position.speed >= 1.0 &&
                (position.heading - precedente.heading).abs() > 20);
      }
      if (!significatif) {
        final dernier = dernierFixJournalise;
        if (dernier != null && maintenant.difference(dernier).inSeconds < 10) {
          return;
        }
      }
      dernierFixJournalise = maintenant;
      dernierePositionJournalisee = position;
      Journal.i('POSITION', 'Nouveau fix GPS reçu', {
        'precision_m': position.accuracy,
        'vitesse_ms': position.speed,
        'cap_deg': position.heading,
      });
    }

    positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1,
          ),
        ).listen((Position position) {
          journaliserFix(position);
          if (!mounted) return;

          // Filtre anti-bruit : fix rejetée quand le téléphone est à l'arrêt
          // (ou quasi immobile). Le GPS dérive de quelques mètres sans bouger :
          // l'accepter ferait sautiller le point bleu et zigzaguer la caméra.
          // On se base sur la VITESSE EFFECTIVE (dérivée de la distance /
          // temps) et non sur position.speed, souvent 0,0 à la marche lente.
          final pointFix = LatLng(position.latitude, position.longitude);
          final positionAcceptee =
              _positionAcceptee ?? (pointFix, DateTime.now());
          _positionAcceptee = positionAcceptee;
          final dureeSec = DateTime.now()
              .difference(positionAcceptee.$2)
              .inMilliseconds /
              1000.0;
          final distanceDepuisAcceptee =
              const Distance().distance(positionAcceptee.$1, pointFix);
          final vitesseEffectiveMs = dureeSec > 0
              ? distanceDepuisAcceptee / dureeSec
              : 0;
          if (distanceDepuisAcceptee < _seuilBruitPositionMetres &&
              vitesseEffectiveMs < _seuilVitesseEffectiveMs) {
            return;
          }
          _positionAcceptee = (pointFix, DateTime.now());

          setState(() {
            positionActuelle = position;

            // Tout fix ACCEPTÉ ici est un réel déplacement (vitesse effective
            // ≥ 0,45 m/s) : le cap GPS est alors exploitable pour la règle
            // d'orientation 10°/5 m, y compris à la marche.
            if (position.heading >= 0) {
              capUtilisateur = position.heading;
            }

            // Les boutons d'action attachés à la position suivent le point bleu.
            if (actionsSurPosition) {
              pointActions = LatLng(position.latitude, position.longitude);
            }
          });

          _verifierDeviation(position);
          _mettreAJourZonePosition(position);
        }, onError: (Object e, StackTrace st) {
          // Permission révoquée en cours de route, GPS coupé… : le flux
          // rejette une erreur. Sans ce garde-fou, elle remontait en erreur
          // non gérée (ZonedGuarded) et l'app était consignée en plantage.
          Journal.e('POSITION', 'Flux GPS interrompu', {'erreur': '$e'});
          debugPrint('[KinFlow] Flux GPS interrompu: $e');
          positionStream?.cancel();
          positionStream = null;
          if (mounted) setState(() => chargementPosition = false);
        }, cancelOnError: true);
  }

  // ---------------------------------------------------------------------------
  // Déviation hors itinéraire
  // ---------------------------------------------------------------------------

  static const double _seuilDeviationMetres = 30;
  static const double _precisionGpsMaxMetres = 25;
  static const int _confirmationsDeviation = 3;
  int _pointsHorsTraceConsecutifs = 0;
  bool _deviationRefusee = false;

  /// Index du premier point de l'itinéraire encore à afficher : quand
  /// l'utilisateur suit réellement le tracé, la portion déjà parcourue
  /// (derrière lui) est masquée. -1 = itinéraire entier visible.
  int _debutVisuelItineraire = -1;

  void _verifierDeviation(Position position) {
    final itineraire = _itineraire;
    if (itineraire == null ||
        _chargementItineraire ||
        _dialogueDeviationOuvert ||
        _deviationRefusee ||
        carteSurLieuRecherche ||
        !mounted) {
      return;
    }

    if (position.accuracy > _precisionGpsMaxMetres) return;

    final point = LatLng(position.latitude, position.longitude);
    if (distanceALignes(point, itineraire.points) <
        _seuilDeviationMetres) {
      _mettreAJourProgression(position);
      _pointsHorsTraceConsecutifs = 0;
      return;
    }

    _pointsHorsTraceConsecutifs++;
    if (_pointsHorsTraceConsecutifs < _confirmationsDeviation) return;
    _pointsHorsTraceConsecutifs = 0;

    Journal.a('ITINERAIRE', 'Itinéraire quitté : dialogue de recalcul proposé');

    _dialogueDeviationOuvert = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (contextDialogue) => AlertDialog(
        title: const Text("Itinéraire quitté"),
        content: const Text(
          "Vous vous êtes éloigné de l'itinéraire tracé. Voulez-vous calculer "
          "un nouvel itinéraire depuis votre position actuelle ?",
        ),
        actions: [
          TextButton(
            onPressed: () {
              _deviationRefusee = true;
              Navigator.of(contextDialogue).pop();
            },
            child: const Text("Non"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(contextDialogue).pop();
              final destination = _arriveeItineraire ?? itineraire.points.last;
              _etapesAvantRecherche = List.of(_etapes);
              calculerItineraire(point, destination);
            },
            child: const Text("Recalculer"),
          ),
        ],
      ),
    ).whenComplete(() {
      _dialogueDeviationOuvert = false;
    });
  }

  /// Met à jour la progression le long de l'itinéraire : calcule l'index du
  /// premier point qui se trouve DEVANT l'utilisateur, puis masque tout ce qui
  /// le précède ([_debutVisuelItineraire]). La progression ne recule jamais :
  /// un fix GPS imprécis ne doit pas réafficher une portion déjà parcourue.
  /// Un itinéraire recalculé remet le tracé entier en place.
  void _mettreAJourProgression(Position position) {
    final itineraire = _itineraire;
    if (itineraire == null || itineraire.points.length < 2) return;

    final p = LatLng(position.latitude, position.longitude);
    final points = itineraire.points;

    // Index du point de l'itinéraire le plus proche de la position.
    var meilleur = 0;
    var minD = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final d = distanceMetres(p, points[i]);
      if (d < minD) {
        minD = d;
        meilleur = i;
      }
    }

    // Une fois passé, l'utilisateur ne « revient » pas en arrière : on ne
    // réaffiche jamais la portion déjà consommée. On avance d'un point de
    // marge pour que la ligne reste bien visible juste devant.
    final nouveau = meilleur < points.length - 2 ? meilleur : points.length - 1;
    if (nouveau > _debutVisuelItineraire) {
      if (!mounted) return;
      setState(() => _debutVisuelItineraire = nouveau);
    }
  }

  // ---------------------------------------------------------------------------
  // Suivi navigation
  // ---------------------------------------------------------------------------

  void activerSuiviNavigation() {
    _repriseNavTimer?.cancel();
    _repriseNavTimer = null;

    if (!mounted ||
        !afficherPositionUtilisateur ||
        carteSurLieuRecherche ||
        modeNavigation) {
      return;
    }

    Journal.i(
      'NAVIGATION',
      'Suivi navigation activé : la carte suit la position',
    );
    setState(() => modeNavigation = true);
  }

  void interrompreSuiviNavigation() {
    _repriseNavTimer?.cancel();

    if (!modeNavigation) return;

    Journal.a('NAVIGATION', 'Suivi interrompu par un geste manuel');
    setState(() => modeNavigation = false);
  }

  // ---------------------------------------------------------------------------
  // Recentrage / animation caméra
  // ---------------------------------------------------------------------------

  void centrerSurPosition({bool premierePosition = false, VoidCallback? apres}) {
    if (positionActuelle == null) return;

    Journal.i('CARTE', 'Recentrage sur la position utilisateur demandé', {
      'vue_afrique_avant': premierePosition,
    });

    if (!cartePrete) {
      _centrerQuandPrete = true;
      _centrerPremiereFois = premierePosition;
      _centrerApres = apres;
      return;
    }

    _centrerQuandPrete = false;
    _centrerApres = null;

    _animerVueAfriquePuis(
      LatLng(positionActuelle!.latitude, positionActuelle!.longitude),
      17,
      aucunePositionAvant: premierePosition,
      apres: apres,
    );
  }

  void _animerVueAfriquePuis(
    LatLng cible,
    double zoom, {
    double? rotation,
    bool aucunePositionAvant = false,
    VoidCallback? apres,
  }) {
    if (!cartePrete) return;

    if (!aucunePositionAvant) {
      _animerCameraVers(
        cible,
        zoom,
        rotation ?? mapController.camera.rotation,
        duree: const Duration(milliseconds: 1800),
        apres: apres,
      );
      return;
    }

    final fit = CameraFit.bounds(
      bounds: bornesAfrique,
      padding: const EdgeInsets.all(24),
    ).fit(mapController.camera);
    _animerCameraVers(
      fit.center,
      fit.zoom,
      fit.rotation,
      duree: const Duration(milliseconds: 1400),
      apres: () {
        _animerCameraVers(
          cible,
          zoom,
          rotation ?? mapController.camera.rotation,
          duree: const Duration(milliseconds: 2400),
          apres: apres,
        );
      },
    );
  }

  void glisserVersPosition({VoidCallback? apres}) {
    if (positionActuelle == null) return;
    _animerCameraVers(
      LatLng(positionActuelle!.latitude, positionActuelle!.longitude),
      17,
      mapController.camera.rotation,
      apres: apres,
    );
  }

  /// Bouton « Ma position » : recentre la carte sur le point bleu puis
  /// (hors itinéraire) active le suivi navigation — la carte suit le point
  /// bleu et pivote selon la course GPS (seuils mètres/degrés).
  ///
  /// Si le suivi est déjà actif, il est relancé proprement (session remise
  /// à zéro, décalage écran reglissé vers le bas) au lieu de ne rien faire :
  /// le bouton garde ainsi toujours un effet visible.
  void recentrerSurPositionEtSuivre() {
    if (positionActuelle == null) {
      obtenirPosition();
      return;
    }

    if (modeNavigation) {
      // Suivi déjà actif : on le coupe puis on le relance à la frame suivante
      // pour recadrer la caméra sur le point bleu. Un itinéraire affiché ne
      // bloque plus la reprise : la rotation selon la course GPS continue de
      // fonctionner le long du tracé.
      interrompreSuiviNavigation();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) activerSuiviNavigation();
      });
      return;
    }

    // Suivi inactif : centrage animé vers la position, puis activation du
    // suivi. Le suivi reste possible avec un itinéraire affiché.
    glisserVersPosition(
      apres: activerSuiviNavigation,
    );
  }

  void deplacerCarteDoucement(LatLng position, double zoom) {
    _animerCameraVers(position, zoom, mapController.camera.rotation);
  }

  void _animerCameraVers(
    LatLng centre,
    double zoom,
    double rotation, {
    Offset offset = Offset.zero,
    Duration duree = const Duration(milliseconds: 1800),
    VoidCallback? apres,
  }) {
    if (!cartePrete) return;
    final camera = mapController.camera;
    _debutCentre = camera.center;
    _debutZoom = camera.zoom;
    _debutRotation = camera.rotation;
    _suiviDebut = DateTime.now();
    _suiviDuree = duree;
    _suiviCentre = centre;
    _suiviZoom = zoom;
    _suiviRotation = rotation;
    _suiviOffset = offset;
    _apresSuivi = apres;
    _suiviTicker ??= createTicker(_surTickSuivi);
    if (!_suiviTicker!.isActive) _suiviTicker!.start();
  }

  void _surTickSuivi(Duration _) {
    if (!mounted || !cartePrete) return;
    final camera = mapController.camera;
    final debutCentre = _debutCentre ?? camera.center;
    final debutZoom = _debutZoom;
    final debutRotation = _debutRotation;
    final centreCible = _suiviCentre ?? camera.center;
    final zoomCible = _suiviZoom ?? camera.zoom;
    final rotationCible = _suiviRotation ?? camera.rotation;

    final dureeEcoulee = DateTime.now()
        .difference(_suiviDebut ?? DateTime.now())
        .inMilliseconds;
    var t = dureeEcoulee / _suiviDuree.inMilliseconds;
    if (t >= 1.0) t = 1.0;

    final k = Curves.easeInOutCubic.transform(t);

    final centre = LatLng(
      debutCentre.latitude + (centreCible.latitude - debutCentre.latitude) * k,
      debutCentre.longitude +
          (centreCible.longitude - debutCentre.longitude) * k,
    );
    final zoom = debutZoom + (zoomCible - debutZoom) * k;
    final delta = deltaRotation(debutRotation, rotationCible);
    final rotation = normaliserDegre(debutRotation + delta * k);

    mapController.move(centre, zoom, offset: _suiviOffset);
    mapController.rotate(rotation);

    if (t >= 1.0) {
      mapController.move(centreCible, zoomCible, offset: _suiviOffset);
      mapController.rotate(rotationCible);
      _suiviTicker?.stop();
      final action = _apresSuivi;
      _apresSuivi = null;
      if (action != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => action());
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Bouton « Ma position » / bascule lieu
  // ---------------------------------------------------------------------------

  /// Le point vert actuellement visible sur la carte : la destination de
  /// l'itinéraire si elle existe, sinon le lieu recherché (pin vert). Null
  /// si aucun des deux n'est présent.
  LatLng? _pointVertSurCarte() {
    if (_arriveeItineraire != null) return _arriveeItineraire;
    return lieuRecherche;
  }

  void basculerPosition() {
    // Rôle unique : tourner la carte vers le point vert ou revenir au point
    // bleu (position utilisateur).
    if (!afficherPositionUtilisateur || positionActuelle == null) return;
    final pointVert = _pointVertSurCarte();
    if (pointVert == null) return;

    if (carteSurDestination || carteSurLieuRecherche) {
      // On regardait le point vert : on revient sur le point bleu.
      afficherPositionUtilisateur = true;
      setState(() {
        carteSurDestination = false;
        carteSurLieuRecherche = false;
      });
      recentrerSurPositionEtSuivre();
    } else {
      // On regardait le point bleu : on va voir le point vert.
      deplacerCarteDoucement(pointVert, mapController.camera.zoom);
      setState(() {
        if (identical(_arriveeItineraire, pointVert)) {
          carteSurDestination = true;
          carteSurLieuRecherche = false;
        } else {
          carteSurLieuRecherche = true;
          carteSurDestination = false;
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Recherche de lieu
  // ---------------------------------------------------------------------------

  Future<void> ouvrirRecherche() async {
    Journal.i('RECHERCHE', 'Ouverture de la recherche de lieu');
    if (_itineraire != null && _etapes.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Supprimez l'étape ou l'itinéraire avant de chercher un autre lieu.",
          ),
        ),
      );
      return;
    }
    final resultat = await Navigator.push<SearchResult>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => const SearchScreen(),
      ),
    );
    if (resultat == null || !mounted) return;

    final position = LatLng(resultat.latitude, resultat.longitude);
    final aucunPointAvant = positionActuelle == null && lieuRecherche == null;

    Journal.i('RECHERCHE', 'Lieu sélectionné', {
      'nom': resultat.nom,
      'latitude': position.latitude,
      'longitude': position.longitude,
    });

    _repriseNavTimer?.cancel();
    _repriseNavTimer = null;

    setState(() {
      lieuRecherche = position;
      dernierLieuRecherche = resultat.nom;
      carteSurLieuRecherche = true;
      afficherActionsPosition = true;
      pointActions = position;
      actionsSurEpingle = false;
      actionsSurDestination = false;
      actionsSurEtape = false;
      actionsSurPosition = false;
      modeNavigation = false;
    });

    _animerVueAfriquePuis(position, 16, aucunePositionAvant: aucunPointAvant);
  }

  // ---------------------------------------------------------------------------
  // Itinéraire : démarrage, étape, calcul, annulation
  // ---------------------------------------------------------------------------

  Future<void> demarrerItineraire(LatLng cible) async {
    final position = positionActuelle;
    if (position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Activez d'abord votre position pour définir un itinéraire.",
          ),
        ),
      );
      return;
    }
    final depart = LatLng(position.latitude, position.longitude);
    _etapesAvantRecherche = List.of(_etapes);
    _etapes.clear();
    await calculerItineraire(depart, cible);
  }

  Future<void> ajouterEtape(LatLng point) async {
    final destination = _arriveeItineraire;
    final precedent = _itineraire;
    if (_chargementItineraire || destination == null || precedent == null) {
      return;
    }
    if (_etapes.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Une seule étape est autorisée. Supprimez-la d'abord."),
        ),
      );
      return;
    }
    setState(() {
      pointActions = null;
      afficherActionsPosition = false;
      actionsSurEpingle = false;
      actionsSurPosition = false;
      actionsSurDestination = false;
      actionsSurEtape = false;
      lieuRecherche = null;
      carteSurLieuRecherche = false;
      _etapesAvantRecherche = List.of(_etapes);
      _etapes.add(point);
    });
    // Le départ de l'itinéraire reste celui qui était déjà affiché : ajouter
    // une étape insère le point entre départ et arrivée, sans ré-ancrer le
    // parcours sur la position GPS courante (ce qui allongeait le trajet).
    final depart = precedent.points.first;
    await calculerItineraire(depart, destination);
  }

  Future<void> calculerItineraire(LatLng depart, LatLng arrivee) async {
    if (_chargementItineraire) return;
    final premierItineraire = _itineraire == null;

    setState(() {
      _chargementItineraire = true;
      _rechercheItineraireElargie = false;
      _travaillerCarteSuspendu = true;
      afficherActionsPosition = false;
      actionsSurEpingle = false;
      actionsSurPosition = false;
      // Pendant la recherche et l'affichage de l'itinéraire, les polylignes
      // de trafic sont masquées : seul le tracé de l'itinéraire est visible.
      // On mémorise l'état précédent pour le restaurer à la fin (recalcul
      // compris : seul le premier passage écrase la valeur mémorisée).
      if (premierItineraire) {
        _lignesTraficAvantItineraire = afficherLignesTrafic;
      }
      afficherLignesTrafic = false;
    });

    final generation = _generationItineraire;

    Journal.i('ITINERAIRE', 'Calcul d\'itinéraire lancé', {
      'depart':
          '${depart.latitude.toStringAsFixed(5)}, ${depart.longitude.toStringAsFixed(5)}',
      'arrivee':
          '${arrivee.latitude.toStringAsFixed(5)}, ${arrivee.longitude.toStringAsFixed(5)}',
      'etapes': _etapes.length,
    });

    // Les deux moteurs partent en parallèle. Le moteur LOCAL est prioritaires :
    // il calcule sur les MÊMES lignes de circulation que celles affichées sur
    // la carte (segments déjà téléchargés/affichés, servis par le cache), et
    // son coût = distance × état du trafic choisit naturellement le tracé le
    // plus « vert ». Le tracé suit donc exactement les routes colorées.
    // OSRM (qui suit son propre réseau et ignore les embouteillages signalés)
    // n'est qu'un secours quand le réseau local ne couvre pas le parcours.
    RouteResult? resultat;

    final calculLocal = itineraireService.calculer(
      depart,
      arrivee,
      zones: _zonesTrafic,
      etapes: List.of(_etapes),
      onRechercheElargie: () {
        if (mounted) {
          setState(() => _rechercheItineraireElargie = true);
        }
      },
    );

    final calculOsrm = routeService.calculer(
      depart,
      arrivee,
      etapes: List.of(_etapes),
    );

    resultat = await _prefererLocal(calculLocal, calculOsrm);

    if (!mounted) return;

    if (generation != _generationItineraire) {
      setState(() {
        _chargementItineraire = false;
        _travaillerCarteSuspendu = false;
      });
      return;
    }

    // Un trajet plus court que la distance minimale est refusé : départ et
    // arrivée quasi confondus, navigation sans objet. Motif « distance trop
    // courte », avec l'état de la carte restauré comme en cas d'échec.
    if (resultat != null &&
        resultat.distanceMeters < _distanceMinItineraireMetres) {
      Journal.e('ITINERAIRE', 'Distance trop courte', {
        'distanceMeters': resultat.distanceMeters,
        'minimumMeters': _distanceMinItineraireMetres,
      });
      setState(() {
        _chargementItineraire = false;
        _travaillerCarteSuspendu = false;
        afficherLignesTrafic = _lignesTraficAvantItineraire;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Distance trop courte pour l'itinéraire."),
        ),
      );
      return;
    }

    setState(() {
      _chargementItineraire = false;
      _travaillerCarteSuspendu = false;
      if (resultat != null) {
        _itineraire = resultat;
        _itineraireSegmentIds = resultat.segmentsIds.isEmpty
            ? null
            : resultat.segmentsIds;
        _arriveeItineraire = arrivee;
        // La vue d'ensemble montre déjà le point vert (destination) en haut :
        // le bouton « Ma position » doit savoir qu'on regarde la destination,
        // sinon son premier appui fait un saut inutile (il croit qu'on
        // regardait la position).
        carteSurDestination = true;
        carteSurLieuRecherche = false;
        _debutVisuelItineraire = -1;
        _banniereDistanceRestante = resultat.distanceMeters;
        _banniereDureeRestante = resultat.durationSeconds;
        _bannierePalier = 0;
        // L'épingle qui a servi de destination (ou d'étape) est consommée
        // par l'itinéraire : elle disparaît et ne laisse que le point vert
        // de destination (ou le drapeau d'étape) à sa place.
        final pin = epingle;
        if (pin != null &&
            (pin == arrivee || _etapes.any((e) => e == pin))) {
          epingle = null;
        }
        pointActions = null;
        actionsSurEpingle = false;
        actionsSurDestination = false;
        actionsSurEtape = false;
        afficherActionsPosition = false;
        if (_etapes.isEmpty) {
          lieuRecherche = null;
          carteSurLieuRecherche = false;
        }
        _dialogueDeviationOuvert = false;
        _deviationRefusee = false;
        _pointsHorsTraceConsecutifs = 0;
        _repriseNavTimer?.cancel();
        _repriseNavTimer = null;
        modeNavigation = false;
      }
    });

    if (resultat == null) {
      Journal.e('ITINERAIRE', 'Calcul impossible : aucun itinéraire obtenu');
      // La recherche a échoué, aucun itinéraire affiché : on rend au bouton
      // son état précédent et on relance le travail de la carte.
      setState(() {
        afficherLignesTrafic = _lignesTraficAvantItineraire;
        _travaillerCarteSuspendu = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Impossible de calculer l'itinéraire. Vérifiez votre connexion.",
          ),
        ),
      );
      return;
    }

    // Après le tracé, on montre la vue d'ensemble de l'itinéraire SANS
    // reprendre le suivi navigation automatiquement : le suivi se relance
    // quand l'utilisateur l'active (bouton « Ma position ») ou commence à
    // marcher. Un suivi automatique réécrivait la caméra à chaque frame et
    // « résistait » à tous les gestes (double-clic de zoom, pincement) tant
    // qu'on restait sur la vue d'ensemble.
    _ajusterVueSurItineraire(resultat.points);
  }

  /// Plafond d'attente pour OSRM, utilisé uniquement en secours. Un réseau
  /// sain répond en 1 à 3 s ; depuis l'Afrique centrale, les serveurs publics
  /// OSRM sont souvent lents ou géographiquement limités, on laisse plus de
  /// marge que sur une connexion européenne.
  static const _dureeMaxAttenteOsrm = Duration(seconds: 20);

  /// Le moteur local ([local]) est le moteur PRINCIPAL : il tourne sur les
  /// segments de circulation déjà chargés (mêmes lignes que celles affichées)
  /// et privilégie naturellement le tracé le plus fluide. OSRM ([osrm]) n'est
  /// attendu qu'en secours, si le réseau local ne couvre pas le parcours.
  /// Si les deux échouent, renvoie null.
  Future<RouteResult?> _prefererLocal(
    Future<RouteResult?> local,
    Future<RouteResult?> osrm,
  ) async {
    final resultatLocal = await local.catchError((e) {
      debugPrint('[KinFlow] Calcul itinéraire local échoué: $e');
      Journal.e('ITINERAIRE', 'Erreur du moteur local', {'erreur': '$e'});
      return null as RouteResult?;
    });
    if (resultatLocal != null) {
      // OSRM tournait en parallèle ; on ne l'attend plus, son résultat
      // éventuel est jeté (et ses erreurs avalées).
      unawaited(osrm.catchError((_) => null as RouteResult?));
      Journal.s(
        'ITINERAIRE',
        'Itinéraire calculé sur les lignes de circulation',
        {
          'points': resultatLocal.points.length,
          'distance_m': resultatLocal.distanceMeters.round(),
          'duree_s': resultatLocal.durationSeconds.round(),
        },
      );
      return resultatLocal;
    }

    Journal.a(
      'ITINERAIRE',
      'Réseau routier local insuffisant, OSRM en secours',
    );
    RouteResult? resultatOsrm;
    try {
      resultatOsrm = await osrm.timeout(_dureeMaxAttenteOsrm);
    } on TimeoutException {
      Journal.a(
        'ITINERAIRE',
        'OSRM (secours) trop lent, aucun itinéraire obtenu',
      );
    } catch (e) {
      debugPrint('[KinFlow] Calcul itinéraire OSRM échoué: $e');
      Journal.e('ITINERAIRE', 'Erreur du serveur OSRM', {'erreur': '$e'});
    }
    if (resultatOsrm != null) {
      Journal.s('ITINERAIRE', 'Itinéraire obtenu via OSRM (secours)', {
        'points': resultatOsrm.points.length,
        'distance_m': resultatOsrm.distanceMeters.round(),
        'duree_s': resultatOsrm.durationSeconds.round(),
      });
    }
    return resultatOsrm;
  }

  /// Les zones de trafic (« signalements collaboratifs ») sont reçues par la
  /// carte : le moteur local (principal) s'en sert pour pondérer le coût des
  /// rues. On ne recalcule plus l'itinéraire à chaque mise à jour — un
  /// recalcul systématique gaspillerait du réseau en petit débit.
  void _appliquerZonesTrafic(List<ZoneTrafic> zones) {
    _zonesTrafic = zones;
  }

  void _ajusterVueSurItineraire(List<LatLng> points, {VoidCallback? apres}) {
    if (points.isEmpty) return;
    if (!cartePrete) {
      // La carte n'est pas encore rendue (initialisation FMTC en cours,
      // parfois longue sur réseau lent) : mémoriser la demande et la rejouer
      // quand la carte est prête. Sans ce report, l'ajustement vertical
      // bleu bas / vert haut n'était jamais appliqué sur ce trajet.
      _vueItineraireEnAttente = List.of(points);
      _apresVueItineraireEnAttente = apres;
      return;
    }

    Journal.i('ITINERAIRE', 'Ajustement de la vue sur le parcours complet', {
      'nombre_points': points.length,
    });

    final itineraireVue = _itineraire;
    final pointsValides =
        points.where((p) => p.latitude.abs() <= 90 && p.longitude.abs() <= 180).toList();
    if (pointsValides.length < 2) return;

    final depart = pointsValides.first;
    final arrivee = pointsValides.last;
    final rotationCible = rotationTrace(depart, arrivee);

    // Cadrage pur (centre, zoom, rotation) calculé par [calculerVueItineraire]
    // : toute la géométrie vit dans vue_itineraire.dart, ici on ne fait que
    // l'animer. Null = cas dégénéré (portée < 5 m, carte pas encore
    // dimensionnée) : repli sur une animation vers le départ.
    final vue = calculerVueItineraire(
      camera: mapController.camera,
      points: points,
      debutRoute: itineraireVue?.debutRoute ?? 0,
      finRoute: itineraireVue?.finRoute ?? points.length - 1,
    );

    if (vue == null) {
      _animerCameraVers(
        depart,
        mapController.camera.zoom.clamp(16.0, 19.0).toDouble(),
        rotationCible,
        duree: const Duration(milliseconds: 1200),
        apres: apres,
      );
      return;
    }

    final estCourt = distanceMetres(depart, arrivee) < 200;
    final dureeMs = estCourt ? 700 : 1200;

    try {
      _animerCameraVers(
        vue.centre,
        vue.zoom,
        vue.rotation,
        duree: Duration(milliseconds: dureeMs),
        apres: apres,
      );
    } catch (_) {
      _animerCameraVers(
        depart,
        vue.zoom,
        vue.rotation,
        duree: Duration(milliseconds: dureeMs),
        apres: apres,
      );
    }
  }

  void annulerItineraire() {
    Journal.i('ITINERAIRE', 'Itinéraire annulé par l\'utilisateur');
    setState(() {
      _generationItineraire++;
      lieuRecherche = _arriveeItineraire;
      _itineraire = null;
      _itineraireSegmentIds = null;
      _arriveeItineraire = null;
      _debutVisuelItineraire = -1;
      _etapes.clear();
      _vueItineraireEnAttente = null;
      _apresVueItineraireEnAttente = null;
      actionsSurDestination = false;
      actionsSurEtape = false;
      _travaillerCarteSuspendu = false;
      afficherLignesTrafic = _lignesTraficAvantItineraire;
    });
  }

  /// Annule la recherche d'itinéraire en cours (croix de l'indicateur de
  /// calcul) : l'indicateur disparaît, le travail de la carte reprend, et le
  /// calcul déjà lancé en arrière-plan est ignoré à son retour (génération
  /// avancée). Le pin de destination reste posé : on peut relancer depuis là.
  void _annulerRechercheItineraire() {
    Journal.i('ITINERAIRE', 'Recherche d\'itinéraire annulée par l\'utilisateur');
    setState(() {
      _generationItineraire++;
      _chargementItineraire = false;
      _travaillerCarteSuspendu = false;
      _vueItineraireEnAttente = null;
      _apresVueItineraireEnAttente = null;
      afficherLignesTrafic = _lignesTraficAvantItineraire;
      // On revient à l'état d'avant la recherche : si on ajoutait une étape,
      // le drapeau posé disparaît (aucun tracé n'a été recalculé avec elle).
      _etapes
        ..clear()
        ..addAll(_etapesAvantRecherche);
      _etapesAvantRecherche = const [];
      actionsSurEtape = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Interactions sur la carte
  // ---------------------------------------------------------------------------

  /// Toucher sur la carte : sélection d'un pin existant, sinon infos lieu.
  void _onMapTap(LatLng point) {
    final cible = _pointPresse(point);
    if (cible != null) {
      setState(() {
        pointActions = cible;
        actionsSurEpingle = cible == epingle;
        actionsSurDestination =
            _itineraire != null &&
            cible == _arriveeItineraire &&
            !actionsSurEpingle;
        actionsSurEtape =
            _etapes.isNotEmpty && cible == _etapes.first && !actionsSurEpingle;
        actionsSurPosition = false;
        afficherActionsPosition = true;
      });
      return;
    }

    if (afficherPositionUtilisateur && positionActuelle != null) {
      final pEcran = mapController.camera.latLngToScreenPoint(point);
      final posEcran = mapController.camera.latLngToScreenPoint(
        LatLng(positionActuelle!.latitude, positionActuelle!.longitude),
      );
      final dx = pEcran.x - posEcran.x;
      final dy = pEcran.y - posEcran.y;
      if (dx.abs() < 32 && (dy > -52 && dy < 24)) {
        setState(() {
          pointActions = LatLng(
            positionActuelle!.latitude,
            positionActuelle!.longitude,
          );
          actionsSurPosition = true;
          actionsSurEpingle = false;
          afficherActionsPosition = true;
        });
        return;
      }
    }

    if (afficherActionsPosition) {
      setState(() {
        afficherActionsPosition = false;
        pointActions = null;
        actionsSurEpingle = false;
        actionsSurPosition = false;
      });
    } else {
      afficherInfosLieu(point.latitude, point.longitude);
    }
  }

  LatLng? _pointPresse(LatLng point) {
    // Destination et étape d'abord : en cas de pins qui se chevauchent,
    // ce sont elles qui ont la priorité de sélection.
    final cibles = <LatLng?>[
      _itineraire != null ? _arriveeItineraire : null,
      _etapes.isNotEmpty ? _etapes.first : null,
      lieuRecherche,
      epingle,
    ];
    for (final candidat in cibles) {
      if (candidat == null) continue;
      final pointEcran = mapController.camera.latLngToScreenPoint(point);
      final candidatEcran = mapController.camera.latLngToScreenPoint(candidat);
      final dx = pointEcran.x - candidatEcran.x;
      final dy = pointEcran.y - candidatEcran.y;
      // Le pin est dessiné avec sa POINTE à l'ancre géo, mais son corps
      // (le rond d'en haut) s'étend vers le haut d'environ 40-48 px. On
      // tolère donc un tap sur tout le corps de l'icône, pas seulement
      // sur l'ancre, sinon « taper l'épingle » ne la sélectionne pas.
      if (dx.abs() < 32 && (dy > -52 && dy < 24)) {
        return candidat;
      }
    }
    return null;
  }

  void _onDefinirItineraire() {
    final point = pointActions;
    if (point != null && !_chargementItineraire) {
      if (_itineraire != null) {
        ajouterEtape(point);
      } else {
        demarrerItineraire(point);
      }
    }
  }

  /// Affiche une petite fenêtre avec les coordonnées géographiques exactes
  /// du point bleu de position. Les coordonnées en vert se copient d'un
  /// simple appui, sans bouton dédié.
  void _voirDetailsPosition() {
    final position = positionActuelle;
    if (position == null || !mounted) return;
    _voirDetailsCoordonnees(
      LatLng(position.latitude, position.longitude),
      'Ma position',
    );
  }

  /// Affiche une petite fenêtre avec les coordonnées géographiques exactes
  /// du point vert de destination de l'itinéraire.
  void _voirDetailsDestination() {
    final destination = _arriveeItineraire;
    if (destination == null || !mounted) return;
    _voirDetailsCoordonnees(destination, 'Destination');
  }

  void _voirDetailsCoordonnees(LatLng point, String titre) {
    final latitude = point.latitude.toStringAsFixed(6);
    final longitude = point.longitude.toStringAsFixed(6);
    final coordonnees = '$latitude, $longitude';

    final sombre = Theme.of(context).brightness == Brightness.dark;
    final vert = _couleurLatitude();
    final bleu = _couleurLongitude();

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: sombre ? KinColors.surfaceSombre : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          titre,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infosRow('Latitude', latitude, couleurValeur: vert),
            _infosRow('Longitude', longitude, couleurValeur: bleu),
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                Clipboard.setData(ClipboardData(text: coordonnees));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Coordonnées copiées')),
                );
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: sombre
                      ? Colors.white10
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: SelectableText.rich(
                        TextSpan(
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          children: [
                            TextSpan(
                              text: latitude,
                              style: TextStyle(color: vert),
                            ),
                            const TextSpan(text: ', '),
                            TextSpan(
                              text: longitude,
                              style: TextStyle(color: bleu),
                            ),
                          ],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Icon(
                      Icons.copy,
                      size: 16,
                      color: vert,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Quitter'),
          ),
        ],
      ),
    );
  }

  void _onSupprimer() {
    var recalculerSansEtape = false;
    setState(() {
      carteSurDestination = false;
      if (actionsSurPosition) {
        afficherPositionUtilisateur = false;
        positionStream?.cancel();
        positionStream = null;
        actionsSurPosition = false;
        _generationItineraire++;
        _itineraire = null;
        _itineraireSegmentIds = null;
        _arriveeItineraire = null;
        _debutVisuelItineraire = -1;
        _etapes.clear();
        _travaillerCarteSuspendu = false;
        afficherLignesTrafic = _lignesTraficAvantItineraire;
      } else if (actionsSurDestination) {
        _generationItineraire++;
        _itineraire = null;
        _itineraireSegmentIds = null;
        _arriveeItineraire = null;
        _debutVisuelItineraire = -1;
        _etapes.clear();
        actionsSurDestination = false;
        _travaillerCarteSuspendu = false;
        afficherLignesTrafic = _lignesTraficAvantItineraire;
      } else if (actionsSurEtape) {
        _etapes.clear();
        actionsSurEtape = false;
        recalculerSansEtape =
            _arriveeItineraire != null && positionActuelle != null;
      } else if (actionsSurEpingle) {
        epingle = null;
        actionsSurEpingle = false;
      } else {
        lieuRecherche = null;
        dernierLieuRecherche = null;
        carteSurLieuRecherche = false;
      }
      pointActions = null;
      afficherActionsPosition = false;
    });
    if (recalculerSansEtape) {
      final destination = _arriveeItineraire!;
      final pos = positionActuelle!;
      _etapesAvantRecherche = List.of(_etapes);
      calculerItineraire(LatLng(pos.latitude, pos.longitude), destination);
    }
  }

  void _onEpingleAvecCoordonnees(double lat, double lon) {
    setState(() {
      epingle = LatLng(lat, lon);
      lieuRecherche = null;
      dernierLieuRecherche = null;
      carteSurLieuRecherche = false;
      // Une épingle fraîchement posée ne garde pas d'ancienne feuille
      // d'actions ouverte sur un autre point.
      pointActions = null;
      afficherActionsPosition = false;
      actionsSurEpingle = false;
      actionsSurPosition = false;
      actionsSurDestination = false;
      actionsSurEtape = false;
    });
  }

  /// Affiche les informations d'un lieu (bâtiment) au toucher prolongé.
  Future<void> afficherInfosLieu(double lat, double lon) async {
    final info = await searchService.obtenirInfosLieu(lat, lon);
    if (!mounted) return;

    if (info == null || !info.estBatiment) return;

    final sombre = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          info.nom.isNotEmpty ? info.nom : "Lieu",
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: sombre ? KinColors.texteSombre : KinColors.texteClair,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (info.type.isNotEmpty) _infosRow("Type", info.typeFr),
                if (info.adresse.isNotEmpty) _infosRow("Adresse", info.adresse),
                _infosCoordonnees(lat.toStringAsFixed(6), lon.toStringAsFixed(6)),
              ],
            ),
          ),
        ),
        actions: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _onEpingleAvecCoordonnees(lat, lon);
                },
                child: Text(
                  "Épingler",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: sombre
                        ? KinColors.texteSombre
                        : KinColors.texteClair,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  "Fermer",
                  style: TextStyle(
                    fontSize: 14,
                    color: sombre
                        ? KinColors.texteSecondaireSombre
                        : KinColors.texteSecondaireClair,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infosRow(String label, String value, {Color? couleurValeur}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).brightness == Brightness.dark
                ? KinColors.texteSombre
                : KinColors.texteClair,
          ),
          children: [
            TextSpan(
              text: "$label : ",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(
              text: value,
              style: couleurValeur != null
                  ? TextStyle(
                      color: couleurValeur,
                      fontWeight: FontWeight.w600,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Couleur de la latitude dans les coordonnées : verte.
  Color _couleurLatitude() =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF4CD98E)
          : KinColors.primaryFonce;

  /// Couleur de la longitude dans les coordonnées : bleue.
  Color _couleurLongitude() =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF64B5F6)
          : const Color(0xFF1565C0);

  /// Ligne « Coordonnées » du panneau lieu : la latitude en vert et la
  /// longitude en bleu signale que la ligne est interactive ; appuyer
  /// dessus copie les coordonnées (aucun bouton dédié).
  Widget _infosCoordonnees(String latitude, String longitude) {
    final coordonnees = '$latitude, $longitude';
    final sombre = Theme.of(context).brightness == Brightness.dark;
    final vert = _couleurLatitude();
    final bleu = _couleurLongitude();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          Clipboard.setData(ClipboardData(text: coordonnees));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Coordonnées copiées')),
          );
        },
        child: RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 13,
              color: sombre ? KinColors.texteSombre : KinColors.texteClair,
            ),
            children: [
              const TextSpan(
                text: "Coordonnées : ",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              TextSpan(
                text: latitude,
                style: TextStyle(
                  color: vert,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const TextSpan(text: ', '),
              TextSpan(
                text: longitude,
                style: TextStyle(
                  color: bleu,
                  fontWeight: FontWeight.w600,
                ),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.copy,
                    size: 14,
                    color: vert.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Interface
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () {
            Journal.i('ECRAN', 'Ouverture des réglages');
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            );
          },
          icon: const Icon(Icons.settings),
          tooltip: 'Réglages',
        ),
        title: Image.asset(
          Theme.of(context).brightness == Brightness.dark
              ? "assets/kinflow_dark.jpg"
              : "assets/kinflow.jpg",
          height: 70,
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: () {
              Journal.i('ECRAN', 'Ouverture du profil');
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
            icon: const Icon(Icons.person),
            tooltip: 'Profil',
          ),
        ],
      ),
      body: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          _construireCorpsCarte(context),
          if (_chargementItineraire) _construireIndicateurItineraire(),
          if (_itineraire != null) _construireBanniereItineraire(),
          if (afficherQuestionnaire)
            Positioned.fill(
              child: TrafficQuestionnaire(
                onChoix: (etat) => enregistrerSignalement(etat),
              ),
            ),
        ],
      ),
    );
  }

  /// Corps : carte pleine, barre d'état + boutons rapides, panneau d'actions.
  /// En mode replié le panneau de boutons disparaît du flux : la carte
  /// s'agrandit pour occuper l'espace libéré, il ne reste que la poignée et
  /// la barre d'état (recentrer + rue/avenue + polylignes) en bas.
  Widget _construireCorpsCarte(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              TrafficMap(
                mapController: mapController,
                positionActuelle: afficherPositionUtilisateur
                    ? positionActuelle
                    : null,
                lieuRecherche: lieuRecherche,
                afficherLignesTrafic: afficherLignesTrafic,
                suspendreTravailCarte: _travaillerCarteSuspendu,
                onMapTap: _onMapTap,
                onMapReady: () {
                  setState(() => cartePrete = true);
                  if (_centrerQuandPrete && positionActuelle != null) {
                    final apres = _centrerApres;
                    _centrerApres = null;
                    centrerSurPosition(
                      premierePosition: _centrerPremiereFois,
                      apres: apres,
                    );
                  }
                  if (_vueItineraireEnAttente != null) {
                    final points = _vueItineraireEnAttente!;
                    final apres = _apresVueItineraireEnAttente;
                    _vueItineraireEnAttente = null;
                    _apresVueItineraireEnAttente = null;
                    _ajusterVueSurItineraire(points, apres: apres);
                  }
                },
                epingle: epingle,
                onPoserEpingle: (point) =>
                    _onEpingleAvecCoordonnees(point.latitude, point.longitude),
                pointActions: pointActions,
                actionsSurEpingle: actionsSurEpingle,
                versionZonesTrafic: _versionZonesTrafic,
                onZonesTrafic: _appliquerZonesTrafic,
                itinerairePoints: _itineraire?.points,
                itineraireSeverites: _itineraire?.severites,
                itineraireSegmentIds: _itineraireSegmentIds,
                itineraireDebutRoute: _itineraire?.debutRoute ?? 0,
                itineraireDebutVisuel: _debutVisuelItineraire,
                itineraireFinRoute: _itineraire?.finRoute ?? -1,
                pointDestination: _itineraire != null
                    ? _arriveeItineraire
                    : null,
                pointEtape: _etapes.isNotEmpty ? _etapes.first : null,
                modeNavigation: modeNavigation,
                capUtilisateur: afficherPositionUtilisateur
                    ? capUtilisateur
                    : null,
                onNavigationInterrompue: interrompreSuiviNavigation,
                modeSombre: Theme.of(context).brightness == Brightness.dark,
                onUserInteract: () => _suiviTicker?.stop(),
                afficherActions: afficherActionsPosition,
                seulementSupprimer:
                    actionsSurPosition ||
                    actionsSurDestination ||
                    actionsSurEtape,
                libelleActionPrincipale: _itineraire != null
                    ? "Ajouter à l'itinéraire"
                    : 'Définir itinéraire',
                onDefinirItineraire: _onDefinirItineraire,
                desactiverItineraire:
                    _chargementItineraire,
                onSupprimer: _onSupprimer,
                onVoirDetails: actionsSurPosition
                    ? _voirDetailsPosition
                    : actionsSurDestination
                        ? _voirDetailsDestination
                        : null,
              ),
              if (_tileProgress > 0 && _tileProgress < 100)
                _construireBarreProgressionTuiles(),
            ],
          ),
        ),

        _construirePoigneePanneau(),

        _construireBarreEtat(
          context,
          positionActuelle != null &&
              afficherPositionUtilisateur &&
              (_arriveeItineraire != null || lieuRecherche != null),
        ),

        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          clipBehavior: Clip.hardEdge,
          child: _panneauRetraissi
              ? const SizedBox.shrink()
              : TrafficPanel(
                  chargementPosition: chargementPosition,
                  onPosition: obtenirPosition,
                  onRecherche: ouvrirRecherche,
                  onMonApplication: () {
                    Journal.i(
                      'DIAGNOSTIC',
                      'Ouverture de la fenêtre « Mon application »',
                    );
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const DiagnosticsScreen(),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Poignée horizontale centrée : glisser vers le haut déplie, vers le bas replie.
  Widget _construirePoigneePanneau() {
    final sombre = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (details) {
        final vitesse = details.primaryVelocity ?? 0;
        if (vitesse < 0 && _panneauRetraissi) {
          setState(() => _panneauRetraissi = false);
        } else if (vitesse > 0 && !_panneauRetraissi) {
          setState(() => _panneauRetraissi = true);
        }
      },
      child: Container(
        height: 20,
        width: double.infinity,
        alignment: Alignment.center,
        color: sombre ? const Color(0xFF17181C) : Colors.white,
        child: Container(
          width: 44,
          height: 5,
          decoration: BoxDecoration(
            color: sombre ? Colors.white38 : Colors.black26,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }

  /// Barre de progression affichée pendant un téléchargement de cartes.
  Widget _construireBarreProgressionTuiles() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        color: KinColors.primaryFonce,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: _tileProgress / 100,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
              minHeight: 3,
            ),
            const SizedBox(height: 2),
            Text(
              _tileStatus,
              style: const TextStyle(color: Colors.white, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Indicateur « Calcul de l'itinéraire... » lors du chargement, qui devient
  /// « Réflexion profonde... » quand la première fournée de routes ne convient
  /// pas et que le moteur élargit sa recherche. Une croix à droite permet
  /// d'annuler la recherche en cours.
  Widget _construireIndicateurItineraire() {
    final sombre = Theme.of(context).brightness == Brightness.dark;
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: sombre ? KinColors.surfaceSombre : Colors.white,
          elevation: 4,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 2, top: 2, bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: KinColors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _rechercheItineraireElargie
                      ? "Réflexion profonde..."
                      : "Calcul de l'itinéraire...",
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: KinColors.texteClair,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _annulerRechercheItineraire,
                  icon: const Icon(Icons.close, size: 20),
                  color: sombre ? Colors.white70 : Colors.black54,
                  tooltip: 'Annuler la recherche',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Bannière du trajet en cours : « Itinéraire tracé », heure d'arrivée
  /// estimée (distance · durée) et pastille discrète quand une étape est
  /// ajoutée au parcours. Apparition douce (fondu + glissement).
  ///
  /// Distance, durée et heure d'arrivée restent figées entre deux paliers et
  /// se recalculent seulement à chaque 1/5 du trajet (20 %, 40 %, 60 %,
  /// 80 %, arrivée). Seuls les chiffres changent : pas de message.
  Widget _construireBanniereItineraire() {
    _mettreAJourBanniere();
    final sombre = Theme.of(context).brightness == Brightness.dark;
    final couleurTitre = sombre ? Colors.white : KinColors.texteClair;
    final couleurSecondaire = sombre
        ? KinColors.texteSecondaireSombre
        : KinColors.texteSecondaireClair;
    final couleurArrivee = sombre ? const Color(0xFF4CD98E) : KinColors.primaryFonce;
    final arrivee = DateTime.now()
        .add(Duration(seconds: _banniereDureeRestante.round()));
    final avecEtape = _etapes.isNotEmpty;

    return Positioned(
      top: 8,
      left: 12,
      right: 12,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, -10 * (1 - t)),
              child: child,
            ),
          ),
          child: Material(
            color: sombre ? KinColors.surfaceSombre : Colors.white,
            elevation: 4,
            shadowColor: Colors.black.withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: sombre
                            ? const [Color(0xFF4CD98E), KinColors.primary]
                            : [KinColors.primaryClair, KinColors.primaryFonce],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.route, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Itinéraire tracé',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: couleurTitre,
                            ),
                          ),
                          if (avecEtape) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: KinColors.accent.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    MdiIcons.flagCheckered,
                                    size: 12,
                                    color: KinColors.accentTranche,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '1 étape',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: sombre
                                          ? const Color(0xFFFFC94D)
                                          : KinColors.accentTranche,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.schedule,
                            size: 13,
                            color: KinColors.accent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Arrivée à ${formaterHeure(arrivee)}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: couleurArrivee,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '·',
                            style: TextStyle(color: couleurSecondaire),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${formaterDistance(_banniereDistanceRestante)} · '
                            '${formaterDuree(_banniereDureeRestante)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: couleurSecondaire,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: annulerItineraire,
                    icon: const Icon(Icons.close, size: 18),
                    color: couleurSecondaire,
                    tooltip: 'Annuler l\'itinéraire',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Met à jour les valeurs restantes affichées dans la bannière, mais
  /// uniquement quand un palier est franchi : tout les 1/5 du trajet (20 %,
  /// 40 %, 60 %, 80 %, arrivée). Entre deux paliers les chiffres restent
  /// figés. Discret : aucun message, seuls les nombres changent.
  void _mettreAJourBanniere() {
    final itineraire = _itineraire;
    if (itineraire == null || itineraire.distanceMeters <= 0) return;
    final distanceRestante = _distanceRestanteMetres();
    final fractionRestante = distanceRestante / itineraire.distanceMeters;
    if (fractionRestante <= _paliersBanniere[_bannierePalier]) {
      _banniereDistanceRestante = distanceRestante;
      _banniereDureeRestante = itineraire.durationSeconds * fractionRestante;
      if (_bannierePalier < _paliersBanniere.length - 1) _bannierePalier++;
    }
  }

  /// Distance (mètres) restant à parcourir jusqu'à l'arrivée, calculée en
  /// projetant la position courante sur le tracé de l'itinéraire. Sans
  /// position valide (trajet pas commencé), renvoie la distance totale.
  double _distanceRestanteMetres() {
    final itineraire = _itineraire;
    final pos = positionActuelle;
    if (itineraire == null) return 0;
    final points = itineraire.points;
    if (points.length < 2 || pos == null) return itineraire.distanceMeters;

    final p = LatLng(pos.latitude, pos.longitude);

    // Longueur cumulée le long de la polyligne (= chainage « traveled »).
    final cumuls = <double>[0];
    double total = 0;
    for (var i = 0; i < points.length - 1; i++) {
      total += distanceMetres(points[i], points[i + 1]);
      cumuls.add(total);
    }

    // Projette la position sur chaque segment et retient le point du tracé
    // le plus proche, mesuré en distance parcourue depuis le départ.
    var parcouru = 0.0;
    final proj = projeterSurAlignes(p, points);
    if (proj != null) {
      parcouru = cumuls[proj.index] +
          proj.t * (cumuls[proj.index + 1] - cumuls[proj.index]);
    }

    return (total - parcouru).clamp(0.0, itineraire.distanceMeters);
  }

  /// Barre inférieure : état en cours, bouton recentrer et bouton trafic.
  Widget _construireBarreEtat(BuildContext context, bool boutonActif) {
    final sombre = Theme.of(context).brightness == Brightness.dark;
    final couleurTexte = sombre ? Colors.white : Colors.black;
    return Container(
      width: double.infinity,
      color: sombre
          ? const Color(0xCC17181C)
          : Colors.white.withValues(alpha: 0.95),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      child: Row(
        children: [
          FloatingActionButton(
            heroTag: 'position',
            backgroundColor: !boutonActif
                ? Colors.grey
                : ((carteSurLieuRecherche || carteSurDestination)
                      ? Colors.blue
                      : KinColors.primary),
            onPressed: boutonActif ? basculerPosition : null,
            child: const Icon(Icons.restart_alt, color: Colors.white),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'Rue : ${_ruePosition.isNotEmpty ? _ruePosition : '—'}',
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: couleurTexte,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Av : ${_avenuePosition.isNotEmpty ? _avenuePosition : '—'}',
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: couleurTexte,
                    ),
                  ),
                ],
              ),
            ),
          ),
          FloatingActionButton(
            heroTag: 'lignes',
            backgroundColor: _itineraire != null || _chargementItineraire
                ? Colors.grey.withValues(alpha: 0.5)
                : (afficherLignesTrafic ? KinColors.primary : Colors.grey),
            onPressed: (_itineraire != null || _chargementItineraire)
                ? null
                : () {
                    setState(
                      () => afficherLignesTrafic = !afficherLignesTrafic,
                    );
                  },
            child: const Icon(Icons.polyline, color: Colors.white),
          ),
        ],
      ),
    );
  }
}
