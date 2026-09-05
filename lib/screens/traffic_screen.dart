import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart' show tileDownloadService;
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
import '../theme/kinflow_theme.dart';
import '../widgets/traffic_map.dart';
import '../widgets/traffic_panel.dart';
import '../widgets/traffic_questionnaire.dart';
import '../widgets/traffic_state_sheet.dart';
import 'diagnostics_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

/// Bornes de la vue « Afrique » affichée tant qu'aucune position n'est connue.
final LatLngBounds _limitesAfrique = LatLngBounds(
  const LatLng(-35.0, -18.0),
  const LatLng(37.5, 52.0),
);

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

  // ---------------------------------------------------------------------------
  // Mode navigation : la carte suit la position et pivote selon le cap
  // ---------------------------------------------------------------------------

  bool modeNavigation = false;
  double capUtilisateur = 0;
  Timer? _repriseNavTimer;

  bool _centrerQuandPrete = false;
  bool _centrerPremiereFois = false;

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

  List<ZoneTrafic> _zonesTrafic = [];
  RouteResult? _itineraire;
  bool _chargementItineraire = false;
  LatLng? _arriveeItineraire;
  final List<LatLng> _etapes = [];
  bool _lignesTraficAvantItineraire = true;

  int _versionZonesTrafic = 0;
  bool actionsSurDestination = false;
  bool actionsSurEtape = false;
  bool _dialogueDeviationOuvert = false;
  int _generationItineraire = 0;

  // ---------------------------------------------------------------------------
  // Signalement
  // ---------------------------------------------------------------------------

  String etatActuel = "Aucun signalement";
  bool _propositionSignalementOuverte = false;
  bool afficherQuestionnaire = false;
  Timer? _verifSignalementTimer;

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
  /// à l'activer (comme pour la position). Une fois activé, relance un fix.
  Future<void> _activerGpsPourTrafic() async {
    if (!mounted) return;
    final active = await locationService.verifierActiverService();
    if (!mounted) return;
    if (active) {
      if (positionActuelle == null) {
        obtenirPosition();
      }
    } else {
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
      centrerSurPosition(premierePosition: aucunMarqueurAvant);
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

          setState(() {
            positionActuelle = position;

            // Seule la course GPS en déplacement réel (> 1 m/s) alimente le cap.
            final vitesse = position.speed;
            if (vitesse >= 1.0 && position.heading >= 0) {
              capUtilisateur = position.heading;
            }

            // Les boutons d'action attachés à la position suivent le point bleu.
            if (actionsSurPosition) {
              pointActions = LatLng(position.latitude, position.longitude);
            }
          });

          _verifierDeviation(position);
          _mettreAJourZonePosition(position);
        });
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
    if (_distanceALItineraire(point, itineraire.points) <
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

  /// Distance minimale entre [p] et la polyligne [points], en mètres
  /// (projection orthogonale sur chaque segment).
  double _distanceALItineraire(LatLng p, List<LatLng> points) {
    var minD = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      final cosLat = math.cos(b.latitude * math.pi / 180);
      final ax = (b.longitude - a.longitude) * cosLat;
      final ay = b.latitude - a.latitude;
      final bx = (p.longitude - a.longitude) * cosLat;
      final by = p.latitude - a.latitude;
      final len2 = ax * ax + ay * ay;
      if (len2 <= 0) continue;
      final t = ((bx * ax + by * ay) / len2).clamp(0.0, 1.0);
      final projLat = a.latitude + t * (b.latitude - a.latitude);
      final projLon = a.longitude + t * (b.longitude - a.longitude);
      final dLat = (p.latitude - projLat) * 111320;
      final dLon = (p.longitude - projLon) * 111320 * cosLat;
      final d = math.sqrt(dLat * dLat + dLon * dLon);
      if (d < minD) minD = d;
    }
    return minD;
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
      final d = _distanceMetres(p, points[i]);
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

  double _distanceMetres(LatLng a, LatLng b) {
    final cosLat = math.cos(b.latitude * math.pi / 180);
    final dLat = (a.latitude - b.latitude) * 111320;
    final dLon = (a.longitude - b.longitude) * 111320 * cosLat;
    return math.sqrt(dLat * dLat + dLon * dLon);
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

  void centrerSurPosition({bool premierePosition = false}) {
    if (positionActuelle == null) return;

    Journal.i('CARTE', 'Recentrage sur la position utilisateur demandé', {
      'vue_afrique_avant': premierePosition,
    });

    if (!cartePrete) {
      _centrerQuandPrete = true;
      _centrerPremiereFois = premierePosition;
      return;
    }

    _centrerQuandPrete = false;

    _animerVueAfriquePuis(
      LatLng(positionActuelle!.latitude, positionActuelle!.longitude),
      17,
      aucunePositionAvant: premierePosition,
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
      bounds: _limitesAfrique,
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

  double _normaliserDegre(double deg) {
    final r = deg % 360;
    return r < 0 ? r + 360 : r;
  }

  double _deltaRotation(double de, double vers) {
    var d = (vers - de) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
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
    final delta = _deltaRotation(debutRotation, rotationCible);
    final rotation = _normaliserDegre(debutRotation + delta * k);

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

  void basculerPosition() {
    // Retour depuis le lieu consulté vers la position utilisateur.
    if (carteSurLieuRecherche && lieuRecherche != null) {
      if (positionActuelle != null) {
        Journal.i(
          'POSITION',
          'Bouton « Ma position » : retour depuis le lieu consulté',
        );
        afficherPositionUtilisateur = true;
        glisserVersPosition();
        setState(() {
          carteSurLieuRecherche = false;
          carteSurDestination = false;
        });
      } else {
        Journal.i(
          'POSITION',
          'Bouton « Ma position » : aucune position connue, demande GPS',
        );
        obtenirPosition();
      }
      return;
    }

    // Bascule entre le point bleu (ma position) et le pin vert (destination).
    final destination = _arriveeItineraire;
    if (_itineraire != null && destination != null) {
      if (carteSurDestination) {
        // On regardait le pin vert : on revient sur le point bleu.
        Journal.i('POSITION', 'Bascule : retour sur le point bleu');
        if (positionActuelle != null) {
          afficherPositionUtilisateur = true;
          glisserVersPosition();
        } else {
          obtenirPosition();
          return;
        }
        setState(() => carteSurDestination = false);
      } else {
        // On regardait le point bleu : on va voir le pin vert (destination).
        Journal.i('POSITION', 'Bascule : vue sur le pin vert (destination)');
        deplacerCarteDoucement(destination, mapController.camera.zoom);
        setState(() => carteSurDestination = true);
      }
      return;
    }

    // Aucun itinéraire actif : comportement de recentrage simple.
    if (lieuRecherche != null) {
      _repriseNavTimer?.cancel();
      _repriseNavTimer = null;
      Journal.i('CARTE', 'Recentrage sur le lieu consulté');
      deplacerCarteDoucement(lieuRecherche!, mapController.camera.zoom);
      setState(() {
        carteSurLieuRecherche = true;
        carteSurDestination = false;
      });
    } else if (positionActuelle != null) {
      Journal.i('POSITION', 'Bouton « Ma position » : recentrage simple');
      afficherPositionUtilisateur = true;
      glisserVersPosition();
      setState(() {
        carteSurLieuRecherche = false;
        carteSurDestination = false;
      });
    } else {
      Journal.i(
        'POSITION',
        'Bouton « Ma position » : position inconnue, demande GPS',
      );
      obtenirPosition();
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
      _etapes.add(point);
    });
    final depart = positionActuelle != null
        ? LatLng(positionActuelle!.latitude, positionActuelle!.longitude)
        : precedent.points.first;
    await calculerItineraire(depart, destination);
  }

  Future<void> calculerItineraire(LatLng depart, LatLng arrivee) async {
    if (_chargementItineraire) return;

    setState(() {
      _chargementItineraire = true;
      afficherActionsPosition = false;
      actionsSurEpingle = false;
      actionsSurPosition = false;
      // Pendant la recherche et l'affichage de l'itinéraire, les polylignes
      // de trafic sont masquées : seul le tracé de l'itinéraire est visible.
      // On mémorise l'état précédent pour le restaurer à la fin (recalcul
      // compris : seul le premier passage écrase la valeur mémorisée).
      if (_itineraire == null && !_chargementItineraire) {
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

    // Le moteur local (Overpass + Dijkstra) et OSRM tournent en parallèle :
    // le premier résultat validé est utilisé. L'autre tâche continue en
    // arrière‑plan (son résultat est ignoré via _generationItineraire).
    RouteResult? resultat;

    final calculLocal = itineraireService.calculer(
      depart,
      arrivee,
      zones: _zonesTrafic,
      etapes: List.of(_etapes),
    );

    final calculOsrm = routeService.calculer(
      depart,
      arrivee,
      etapes: List.of(_etapes),
    );

    resultat = await _premierResultat(calculLocal, calculOsrm);

    if (!mounted) return;

    if (generation != _generationItineraire) {
      setState(() => _chargementItineraire = false);
      return;
    }

    setState(() {
      _chargementItineraire = false;
      if (resultat != null) {
        _itineraire = resultat;
        _arriveeItineraire = arrivee;
        _debutVisuelItineraire = -1;
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
      // son état précédent.
      afficherLignesTrafic = _lignesTraficAvantItineraire;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Impossible de calculer l'itinéraire. Vérifiez votre connexion.",
          ),
        ),
      );
      return;
    }

    _ajusterVueSurItineraire(resultat.points);
  }

  /// Renvoie le premier [RouteResult] non nul parmi [a] et [b], quel que soit
  /// l'ordre de complétion. Si les deux échouent, renvoie null.
  Future<RouteResult?> _premierResultat(
    Future<RouteResult?> a,
    Future<RouteResult?> b,
  ) async {
    final completer = Completer<RouteResult?>();
    var restant = 2;
    RouteResult? premier;

    void terminer() {
      restant--;
      if (!completer.isCompleted) {
        if (premier != null || restant == 0) {
          completer.complete(premier);
        }
      }
    }

    a.then((r) {
      if (r != null && premier == null) {
        premier = r;
        Journal.s('ITINERAIRE', 'Itinéraire calculé par le moteur local', {
          'points': r.points.length,
          'distance_m': r.distanceMeters.round(),
          'duree_s': r.durationSeconds.round(),
        });
      }
      terminer();
    }).catchError((e) {
      debugPrint('[KinFlow] Calcul itinéraire local échoué: $e');
      Journal.e('ITINERAIRE', 'Erreur du moteur local', {'erreur': '$e'});
      terminer();
    });

    b.then((r) {
      if (r != null && premier == null) {
        premier = r;
        Journal.s('ITINERAIRE', 'Itinéraire obtenu via OSRM', {
          'points': r.points.length,
          'distance_m': r.distanceMeters.round(),
          'duree_s': r.durationSeconds.round(),
        });
      }
      terminer();
    }).catchError((e) {
      debugPrint('[KinFlow] Calcul itinéraire OSRM échoué: $e');
      Journal.e('ITINERAIRE', 'Erreur du serveur OSRM', {'erreur': '$e'});
      terminer();
    });

    return completer.future;
  }

  void _ajusterVueSurItineraire(List<LatLng> points) {
    if (!cartePrete || points.isEmpty) return;

    Journal.i('ITINERAIRE', 'Ajustement de la vue sur le parcours complet', {
      'nombre_points': points.length,
    });

    final valides =
        points.where((p) => p.latitude.abs() <= 90 && p.longitude.abs() <= 180).toList();
    if (valides.isEmpty) return;

    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    var minLon = double.infinity;
    var maxLon = double.negativeInfinity;
    for (final p in valides) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }

    final cosLat = math.cos((minLat + maxLat) * 0.5 * math.pi / 180);
    final porteeLat = (maxLat - minLat) * 111320;
    final porteeLon = (maxLon - minLon) * 111320 * cosLat;
    final porteeMetres = math.max(porteeLat, porteeLon);
    if (!minLat.isFinite || !maxLat.isFinite || porteeMetres < 5) {
      _animerCameraVers(
        valides.first,
        16,
        mapController.camera.rotation,
        duree: const Duration(milliseconds: 1200),
      );
      return;
    }

    final depart = valides.first;
    final arrivee = valides.last;
    final margeLat = (maxLat - minLat) * 0.35 + 0.0015;
    final margeLon = (maxLon - minLon) * 0.35 + 0.0015;
    if (depart.latitude <= arrivee.latitude) {
      minLat -= margeLat;
    } else {
      maxLat += margeLat;
    }
    if (depart.longitude <= arrivee.longitude) {
      minLon -= margeLon;
    } else {
      maxLon += margeLon;
    }

    final dLat = arrivee.latitude - depart.latitude;
    final dLon = arrivee.longitude - depart.longitude;
    final bearingDeg = math.atan2(dLon, dLat) * 180.0 / math.pi;
    final rotationCible = (90.0 - bearingDeg) % 360.0;

    final estCourt = porteeMetres < 200;
    final dureeMs = estCourt ? 700 : 1200;

    try {
      final fit = CameraFit.bounds(
        bounds: LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon)),
        padding: const EdgeInsets.only(left: 70, right: 70, top: 80, bottom: 120),
      ).fit(mapController.camera.withRotation(rotationCible));

      _animerCameraVers(
        fit.center,
        fit.zoom,
        rotationCible,
        duree: Duration(milliseconds: dureeMs),
      );
    } catch (e) {
      _animerCameraVers(
        valides.first,
        16,
        mapController.camera.rotation,
        duree: Duration(milliseconds: dureeMs),
      );
    }
  }

  void annulerItineraire() {
    Journal.i('ITINERAIRE', 'Itinéraire annulé par l\'utilisateur');
    setState(() {
      _generationItineraire++;
      lieuRecherche = _arriveeItineraire;
      _itineraire = null;
      _arriveeItineraire = null;
      _debutVisuelItineraire = -1;
      _etapes.clear();
      actionsSurDestination = false;
      actionsSurEtape = false;
      afficherLignesTrafic = _lignesTraficAvantItineraire;
    });
  }

  String _formatDistance(double metres) {
    if (metres >= 1000) {
      return '${(metres / 1000).toStringAsFixed(1)} km';
    }
    return '${metres.round()} m';
  }

  String _formatDuree(double secondes) {
    final minutes = (secondes / 60).round();
    if (minutes < 60) return '$minutes min';
    final heures = minutes ~/ 60;
    final restantes = minutes % 60;
    return restantes == 0 ? '$heures h' : '$heures h $restantes';
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
  /// du point bleu de position, et deux boutons « Copier » et « Quitter ».
  void _voirDetailsPosition() {
    final position = positionActuelle;
    if (position == null || !mounted) return;

    final latitude = position.latitude.toStringAsFixed(6);
    final longitude = position.longitude.toStringAsFixed(6);
    final coordonnees = '$latitude, $longitude';

    final sombre = Theme.of(context).brightness == Brightness.dark;

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: sombre ? KinColors.surfaceSombre : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Ma position',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infosRow('Latitude', latitude),
            _infosRow('Longitude', longitude),
            const SizedBox(height: 8),
            Container(
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
              child: SelectableText(
                coordonnees,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: sombre ? KinColors.texteSombre : KinColors.texteClair,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: coordonnees));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Coordonnées copiées')),
                  );
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copier'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Quitter'),
              ),
            ],
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
        _arriveeItineraire = null;
        _debutVisuelItineraire = -1;
        _etapes.clear();
        afficherLignesTrafic = _lignesTraficAvantItineraire;
      } else if (actionsSurDestination) {
        _generationItineraire++;
        _itineraire = null;
        _arriveeItineraire = null;
        _debutVisuelItineraire = -1;
        _etapes.clear();
        actionsSurDestination = false;
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
      calculerItineraire(LatLng(pos.latitude, pos.longitude), destination);
    }
  }

  void _onEpingleAvecCoordonnees(double lat, double lon) {
    setState(() {
      epingle = LatLng(lat, lon);
      lieuRecherche = null;
      dernierLieuRecherche = null;
      carteSurLieuRecherche = false;
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
                _infosRow(
                  "Coordonnées",
                  "${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}",
                ),
              ],
            ),
          ),
        ),
        actions: [
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
    );
  }

  Widget _infosRow(String label, String value) {
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
            TextSpan(text: value),
          ],
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
                onMapTap: _onMapTap,
                onMapReady: () {
                  setState(() => cartePrete = true);
                  if (_centrerQuandPrete && positionActuelle != null) {
                    centrerSurPosition(premierePosition: _centrerPremiereFois);
                  }
                },
                epingle: epingle,
                pointActions: pointActions,
                actionsSurEpingle: actionsSurEpingle,
                versionZonesTrafic: _versionZonesTrafic,
                onZonesTrafic: (zones) => _zonesTrafic = zones,
                itinerairePoints: _itineraire?.points,
                itineraireSeverites: _itineraire?.severites,
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
          positionActuelle != null && _itineraire != null,
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

  /// Indicateur « Calcul de l'itinéraire... » lors du chargement.
  Widget _construireIndicateurItineraire() {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: Theme.of(context).brightness == Brightness.dark
              ? KinColors.surfaceSombre
              : Colors.white,
          elevation: 4,
          borderRadius: BorderRadius.circular(24),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: KinColors.primary,
                  ),
                ),
                SizedBox(width: 10),
                Text(
                  "Calcul de l'itinéraire...",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: KinColors.texteClair,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Bannière du trajet en cours (distance + durée + annulation).
  Widget _construireBanniereItineraire() {
    final itineraire = _itineraire!;
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: Theme.of(context).brightness == Brightness.dark
              ? KinColors.surfaceSombre
              : Colors.white,
          elevation: 4,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.route, color: KinColors.primary, size: 20),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatDistance(itineraire.distanceMeters),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: KinColors.texteClair,
                      ),
                    ),
                    Text(
                      _formatDuree(itineraire.durationSeconds),
                      style: const TextStyle(
                        fontSize: 11,
                        color: KinColors.texteSecondaireClair,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: annulerItineraire,
                  icon: const Icon(Icons.close, size: 18),
                  color: KinColors.texteSecondaireClair,
                  tooltip: 'Annuler l\'itinéraire',
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
