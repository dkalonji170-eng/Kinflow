import 'dart:async';
import 'dart:math'
    show Point, cos, exp, max, min;
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_map/flutter_map.dart' hide LatLngTween;
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import '../config/carte.dart' show bornesAfrique, zoomMinGlobal;
import '../main.dart'
    show tileDownloadService, waitForFmtc, initFmtc, fmtcSucceeded;
import '../models/road_segment.dart';
import '../models/traffic_state.dart';
import '../theme/kinflow_theme.dart';
import '../utils/geo.dart' show deltaRotation, distanceMetresHaversine, normaliserDegre;
import '../utils/latlng_tween.dart';
import '../services/poi_service.dart'
    show
        Poi,
        PoiService,
        CircuitBreakerPois,
        iconePoi,
        maxPoisVisiblesParType,
        prioritePoi,
        zoomMinPois,
        zoomNomPois;
import '../services/rendu_itineraire.dart' show decouperItineraireParEtat;
import '../services/road_service.dart';
import '../services/diagnostics_service.dart';
import '../services/data_usage_service.dart';
import '../services/tile_prefetch_service.dart';
import '../services/traffic_simulator.dart';
import '../services/traffic_stats_service.dart';
import '../services/supabase_service.dart';
import '../services/orientation_navigation.dart';
import 'map_controls.dart';
import 'map_painters.dart' show PeintreEpingle, PeintreEtape;


class _SegmentsParZone {
  final List<RoadSegment> segments;

  /// Borne géographique de chaque segment, calculée UNE fois à l'indexation :
  /// la recalculer à chaque reconstruction des polylignes parcourrait tous
  /// les points de toutes les routes à chaque frame de chargement.
  final List<LatLngBounds> bornes;
  final LatLngBounds bounds;
  final bool detailsComplets;
  final Map<int, List<int>> grille;
  _SegmentsParZone(this.segments, this.bounds, this.detailsComplets)
      : bornes = [for (final s in segments) _boundsGeom(s.points)],
        grille = _indexerSegments(segments);
}

const double _rayonLabel = 40.0;

/// Plafond de tronçons dessinés simultanément : au-delà, les classes de rue
/// les moins importantes sont abandonnées. Sans ce garde-fou, une vue dense
/// de Kinshasa au zoom ≥ 15 produit des dizaines de milliers de polylignes
/// repeintes à CHAQUE frame — c'est ce qui rendait la carte inexploitable.
const int _maxPolylignes = 1600;

/// Plafond réduit pendant la nuit (00h → 6h) : le trafic est absent, inutile
/// de peindre toutes les ruelles. Division du coût de rendu par ~2, les
/// grands axes restent prioritaires (tri par classe de rue inchangé).
const int _maxPolylignesNuit = 800;

/// Fenêtre nocturne 00h → 6h (le pic du matin démarre vers 5h00 dans le
/// simulateur) : toutes les rues passent en vert uniforme et le travail de
/// la carte est réduit tant que la ville dort.
bool _estNuit() {
  final h = DateTime.now().hour;
  return h >= 0 && h < 6;
}

/// Mode navigation : raideur du lissage exponentiel caméra (par seconde).
const double _navFacteurLissage = 5.0;

/// Mode navigation : raideur du lissage exponentiel de la ROTATION (par
/// seconde). Volontairement doux : la carte doit pivoter en glissant, même
/// quand le cap GPS varie vite ou bruite (le seuil bas de 10° déclenche des
/// recadrages fréquents, un raideur élevée les rendrait secoués).
const double _navFacteurLissageRotation = 1.5;

/// Mode navigation : écart angulaire minimal (degrés) entre la rotation
/// caméra courante et le cap filtré pour reprogrammer une adaptation
/// continue de l'orientation. Sous ce seuil la carte reste figée : le filtre
/// circulaire du cap suffit déjà à éliminer le bruit, il ne faut pas en
/// plus faire « danser » la caméra sur des micro-variations.
const double _seuilRotationContinueDegres = 4.0;

/// Mode navigation : part de la hauteur d'écran séparant le centre réel de
/// la caméra du point utilisateur (placé plus bas, vers le tiers inférieur).
const double _navProportionDecalage = 0.22;

const double _tailleCellule = 0.01;
const double _grilleMinLat = -5.0;
const double _grilleMinLon = 15.05;
const int _grilleMaxCols = 64;

int _celluleLat(double lat) =>
    ((lat - _grilleMinLat) / _tailleCellule).floor();
int _celluleLon(double lon) =>
    ((lon - _grilleMinLon) / _tailleCellule).floor();
int _cleCellule(int r, int c) => r * _grilleMaxCols + c;

LatLngBounds _boundsGeom(List<LatLng> points) {
  var minLat = double.infinity;
  var maxLat = double.negativeInfinity;
  var minLon = double.infinity;
  var maxLon = double.negativeInfinity;
  for (final p in points) {
    if (p.latitude < minLat) minLat = p.latitude;
    if (p.latitude > maxLat) maxLat = p.latitude;
    if (p.longitude < minLon) minLon = p.longitude;
    if (p.longitude > maxLon) maxLon = p.longitude;
  }
  return LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));
}

Map<int, List<int>> _indexerSegments(List<RoadSegment> segments) {
  final grille = <int, List<int>>{};
  for (var i = 0; i < segments.length; i++) {
    final b = _boundsGeom(segments[i].points);
    final rMin = _celluleLat(b.south);
    final rMax = _celluleLat(b.north);
    final cMin = _celluleLon(b.west);
    final cMax = _celluleLon(b.east);
    for (var r = rMin; r <= rMax; r++) {
      for (var c = cMin; c <= cMax; c++) {
        grille.putIfAbsent(_cleCellule(r, c), () => []).add(i);
      }
    }
  }
return grille;
  }

/// Styles de fond de carte, choisis indépendamment du thème clair/sombre
/// de l'application.
enum _ModeCarte {
  claire,
  sombre,
  satellite,
  positron,
  darkMatter,
  voyager,
  topo;
}

const String _urlTuiles =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

// La carte sombre utilise les mêmes tuiles OSM que la carte claire, mais
// avec une désaturation + assombrissement appliqués en temps réel.
const String _urlTuilesSombre = _urlTuiles;

const String _urlTuilesSatellite =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

const String _urlTuilesPositron =
    'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png';

const String _urlTuilesDarkMatter =
    'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';

const String _urlTuilesVoyager =
    'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';

const String _urlTuilesTopo =
    'https://tile.opentopomap.org/{z}/{x}/{y}.png';

const Map<String, double> _zoomMinParClasse = {
  'motorway': 6.0,
  'motorway_link': 6.0,
  'trunk': 7.0,
  'trunk_link': 7.0,
  'primary': 10.0,
  'primary_link': 10.0,
  'secondary': 12.0,
  'secondary_link': 12.0,
  'tertiary': 14.0,
  'tertiary_link': 14.0,
  'unclassified': 14.0,
  'road': 14.0,
  'residential': 15.0,
  'living_street': 15.0,
  'service': 15.0,
};

class TrafficMap extends StatefulWidget {

  final MapController mapController;

  final Position? positionActuelle;

  final LatLng? lieuRecherche;

  final bool afficherLignesTrafic;

  /// Vrai pendant le calcul d'un itinéraire : toute l'activité de la carte
  /// (polylignes de trafic, chargement des routes, POIs, zones, prefetch de
  /// tuiles et leurs timers) est suspendue pour laisser toute la bande
  /// passante et le CPU au calcul. Le rendu du fond de carte et les
  /// interactions (recentrage, zoom) restent normaux.
  final bool suspendreTravailCarte;

  final VoidCallback onMapReady;

  final void Function(LatLng point)? onMapTap;

  final bool afficherActions;

  final bool seulementSupprimer;

  final VoidCallback? onDefinirItineraire;

  final VoidCallback? onSupprimer;

  /// Affiche les détails (coordonnées) du point bleu de position.
  final VoidCallback? onVoirDetails;

  final VoidCallback? onUserInteract;

  final LatLng? epingle;

  /// Appelé quand l'utilisateur pose l'épingle de prévisualisation qui suit
  /// le centre de l'écran (bouton « Poser ») : fournit la coordonnée
  /// géographique actuellement au centre de la carte.
  final ValueChanged<LatLng>? onPoserEpingle;

  final LatLng? pointActions;

  /// Le menu d'actions est attaché à l'épingle rouge existante : dans ce cas
  /// aucun marqueur vert de destination n'est dessiné par-dessus elle.
  final bool actionsSurEpingle;

  /// Incrémenté à chaque signalement pour rafraîchir les statistiques.
  final int versionZonesTrafic;

  /// Notifie l'écran des zones de trafic calculées (utilisées ensuite pour
  /// pondérer le calcul d'itinéraire avec l'état réel des routes).
  final ValueChanged<List<ZoneTrafic>>? onZonesTrafic;

  final List<LatLng>? itinerairePoints;

  /// Sévérité du trafic (0..3) par point d'[itinerairePoints], fournie par le
  /// moteur local : permet de colorer la ligne tronçon par tronçon.
  final List<double>? itineraireSeverites;

  /// Index du premier point d'[itinerairePoints] posé sur la chaussée : la
  /// ligne colorée démarre là ; ce qui précède (point réel → route) est
  /// dessiné en pointillés noirs, comme Yango pour un départ dans un
  /// bâtiment ou une parcelle.
  final int itineraireDebutRoute;

  /// Index du premier point d'[itinerairePoints] encore VISIBLE. Pendant le
  /// suivi réel, la portion déjà parcourue (derrière l'utilisateur) est
  /// masquée. -1 = itinéraire entier affiché.
  final int itineraireDebutVisuel;

  /// Index du dernier point d'[itinerairePoints] sur la chaussée (-1 = le
  /// dernier point) : les pointillés noirs reprennent ensuite jusqu'à
  /// l'arrivée réelle.
  final int itineraireFinRoute;

  /// Segments (id OSM) du réseau routier qui forment le tracé bleu → vert,
  /// renseignés par le moteur local. Quand ils sont présents, la carte
  /// n'affiche QUE ces polylignes colorées déjà chargées (l'itinéraire EST
  /// la ligne de circulation) et masque tout le reste. Null sans itinéraire
  /// ou en repli OSRM.
  final List<int>? itineraireSegmentIds;

  /// Pin vert de la destination de l'itinéraire en cours (null sinon) :
  /// reste visible même quand un autre lieu est ensuite recherché.
  final LatLng? pointDestination;

  /// Pin vert de l'étape obligatoire de l'itinéraire (null sinon).
  final LatLng? pointEtape;

  /// Libellé du bouton principal des actions : « Définir itinéraire » au
  /// départ, « Ajouter à l'itinéraire » une fois un trajet affiché.
  final String libelleActionPrincipale;

  /// Quand vrai, le bouton d'itinéraire est grisé et inutilisable :
  /// pendant le calcul ou tant qu'un itinéraire est affiché.
  final bool desactiverItineraire;

  /// Mode navigation : la caméra suit en continu la position utilisateur et
  /// la carte se réoriente par RECADRAGES événementiels : quand le cap de
  /// déplacement s'écarte d'au moins 10° ET qu'au moins 5 m ont été parcourus
  /// depuis le dernier recadrage, la direction redevient le haut de l'écran.
  /// Le point utilisateur ne tourne pas : c'est bien la carte qui tourne
  /// autour de lui.
  final bool modeNavigation;

  /// Cap de l'utilisateur en degrés (0 = Nord, sens horaire), issu
  /// exclusivement de la course GPS pendant un déplacement réel. Il alimente
  /// le contrôleur d'orientation (filtrage + double seuil) qui déclenche les
  /// recadrages (voir [_surTickNavigation]).
  final double? capUtilisateur;

  /// Appelé quand un geste manuel (glissement) interrompt le suivi
  /// navigation : permet à l'écran de désactiver le mode.
  final VoidCallback? onNavigationInterrompue;

  /// Thème sombre de l'application : synchronise automatiquement la carte.
  final bool modeSombre;


  const TrafficMap({

    super.key,

    required this.mapController,

    required this.positionActuelle,

    required this.lieuRecherche,

    this.afficherLignesTrafic = true,

    this.suspendreTravailCarte = false,

    required this.onMapReady,

    this.onMapTap,

    this.afficherActions = false,

    this.seulementSupprimer = false,

    this.onDefinirItineraire,

    this.onSupprimer,

    this.onVoirDetails,

    this.onUserInteract,

    this.epingle,

    this.onPoserEpingle,

    this.pointActions,

    this.actionsSurEpingle = false,

    this.versionZonesTrafic = 0,

    this.onZonesTrafic,

    this.itinerairePoints,

    this.itineraireSeverites,

    this.itineraireDebutRoute = 0,

    this.itineraireDebutVisuel = -1,

    this.itineraireFinRoute = -1,

    this.itineraireSegmentIds,

    this.pointDestination,

    this.pointEtape,

    this.libelleActionPrincipale = 'Définir itinéraire',

    this.desactiverItineraire = false,

    this.modeNavigation = false,

    this.capUtilisateur,

    this.onNavigationInterrompue,

    this.modeSombre = false,

  });


  @override
  State<TrafficMap> createState() =>
      _TrafficMapState();

}



class _TrafficMapState extends State<TrafficMap> with TickerProviderStateMixin {

  bool chargementCarte = true;
  bool _fmtcReady = false;
  bool _carteRendue = false;
  _ModeCarte _modeCarte = _ModeCarte.claire;
  final ScrollController _menuCartesScroll = ScrollController();
  FMTCTileProvider? _tileProvider;
  Timer? _timerConsoTuiles;
  int _tailleCachePrecedenteKiBToOctets = 0;

  /// Prétéléchargement des tuiles du couloir d'itinéraire : instance FMTC
  /// dédiée (annulée avant chaque nouvelle passe) et zooms de la vue
  /// d'ensemble, plafonnés pour ne jamais vider le réseau ni la batterie.
  static const String _instanceIdTuilesCouloir = 'kinflow_couloir_itineraire';
  static const List<int> _zoomsPrechargementCouloir = [11, 12, 13, 14, 15];
  static const int _maxTuilesTotalesCouloir = 600;

  /// Vrai quand le fond est sombre (carte sombre ou satellite) : sert aux
  /// réglages de contraste (contours, drapeaux) indépendants du thème.
  bool get _fondSombre =>
      _modeCarte == _ModeCarte.sombre ||
      _modeCarte == _ModeCarte.darkMatter ||
      _modeCarte == _ModeCarte.satellite;

  /// Plafond de tronçons dessinés selon l'heure : réduit de nuit pour
  /// alléger le rendu quand le trafic est inexistant.
  int get _plafondPolylignes => _estNuit() ? _maxPolylignesNuit : _maxPolylignes;

  String _lastStatus = '';
  double _downloadProgress = 0;

  StreamSubscription<String>? _statusSub;
  StreamSubscription<double>? _progressSub;

  bool _chargementTuilesActif = false;
  Timer? _timerFinChargement;
  DateTime? _dernierChargement;

  AnimationController? _positionAnimController;
  Animation<LatLng>? _positionAnimation;
  LatLng? _displayedPosition;

  AnimationController? _camAnim;
  VoidCallback? _apresAnimation;
  LatLng? _animDebutCentre;
  double _animDebutZoom = 0;
  double _animDebutRotation = 0;
  LatLng? _animCibleCentre;
  double _animCibleZoom = 0;
  double _animCibleRotation = 0;

  Ticker? _navTicker;
  Duration? _navDernierTick;
  double _navRotationCourante = 0;
  double _navZoomCible = 17;

  /// Proportion de décalage écran ACTUELLE : part de 0 à chaque démarrage du
  /// suivi puis glisse vers [_navProportionDecalage]. Appliquée d'un bloc,
  /// le décalage téléporterait le point utilisateur du centre de l'écran
  /// vers le bas dès la première frame (mouvement brusque).
  double _navProportionDecalageCourante = 0;

  /// Centre lissé du suivi, maintenu EN INTERNE : ne jamais relire
  /// camera.center pendant le suivi car il inclut déjà le décalage écran ;
  /// le relire créerait une boucle de rétroaction (oscillations).
  LatLng? _navCentreCourant;

  /// Rotation cible issue du dernier recadrage déclenché, animée ensuite
  /// par lissage jusqu'à convergence.
  double? _navRotationCible;

  /// Décide des recadrages d'orientation : double seuil (cap >= 10° ET
  /// distance >= 5 m depuis la dernière référence), cap filtré circulairement,
  /// validation de la précision GPS. Voir [ControleurOrientation].
  final ControleurOrientation _orientationNav = ControleurOrientation();

  /// Dernière mesure GPS traitée par [_orientationNav] : identifiée par
  /// l'objet [Position] lui-même pour ne filtrer qu'UNE fois par mesure
  /// (le filtre de cap est exponentiel, le nourrir à chaque frame avec la
  /// même valeur fausserait sa dynamique).
  Position? _navDerniereMesure;

  /// Position à laquelle la dernière adaptation CONTINUE de rotation a été
  /// appliquée : l'adaptation ne doit tourner la carte qu'après un réel
  /// déplacement ([seuilDistanceMetres]), sinon le cap filtré qui dérive à
  /// l'arrêt ferait pivoter la carte immobile.
  LatLng? _navDernierePositionRotationContinue;

  Timer? _longPressTimer;
  Timer? _zoomOutTimer;
  Timer? _singleTapTimer;
  bool _longPressActif = false;
  bool _doubleTapEnCours = false;
  DateTime? _pointerDownTime;
  Offset? _pointerDownPos;
  int _pointersDown = 0;

  /// Position de départ de CHAQUE pointeur actif : permet de détecter un
  /// glissement même pendant un pincement à deux doigts (le second doigt
  /// annule le suivi du premier, il faut donc suivre chaque doigt séparément
  /// pour interrompre le mode navigation).
  final Map<int, Offset> _departsPointeurs = {};
  bool _appuiBoutonAction = false;
  bool _pointeurBouge = false;

  /// Nombre de gestes utilisateur en cours (glisser, pincer, pivoter,
  /// double-clic de zoom). Tant qu'il est strictement positif, le ticker de
  /// suivi navigation suspend son écriture de la caméra : sans cela il
  /// réécrirait chaque frame au milieu du geste et « résisterait » au zoom.
  int _gestesActifs = 0;

  /// Mode pose d'épingle : une épingle de prévisualisation est collée au
  /// centre de l'écran et suit la carte tant que l'utilisateur ne l'a pas
  /// posée avec le bouton « Poser ».
  bool _modePoserEpingle = false;

  /// Opacité des boutons flottants (pose d'épingle, cartes) : pleine après
  /// une interaction, puis atténuée quand l'utilisateur reste longtemps sans
  /// les toucher.
  bool _boutonsVisibles = true;
  Timer? _timerBoutons;
  static const Duration _dureeAvantEstompage = Duration(seconds: 8);
  static const double _opaciteBoutonsInactifs = 0.35;

  final RoadService _roadService = RoadService();
  final TrafficSimulator _simulateur = TrafficSimulator();
  final TrafficStatsService _statsService = TrafficStatsService();
  final TilePrefetchService _prefetchService =
      TilePrefetchService(nomMagasin: 'kinshasa');

  /// Anti-spam molette : le zoom à la molette déclenche une rafale
  /// d'événements (un par cran) — on ne journalise qu'à la fin de la rafale.
  Timer? _debounceJournalMolette;
  List<Polyline> _polylignesTrafic = [];
  List<Polyline> _polylignesTraficCache = [];
  List<Polyline> _polylignesItineraire = [];

  /// Raccord en pointillés noirs reliant l'étape à l'itinéraire quand elle est
  /// posée hors réseau routier (bâtiment, parcelle). Vide sinon.
  List<Polyline> _raccordEtape = [];

  final Map<String, _SegmentsParZone> _segmentsCache = {};
  Timer? _debounceRoutes;
  Timer? _debounceRoutesPrefetch;
  Timer? _rafraichissementSimulation;
  Timer? _rafraichissementRoutes;
  Timer? _rafraichissementPrefetch;
  Timer? _rafraichissementStats;

  List<ZoneTrafic> _zonesTrafic = [];

  List<Poi> _pois = [];
  final Map<String, List<Poi>> _poiCache = {};
  Timer? _debouncePois;
  int _signatureZoom = -1;
  final PoiService _poiService = PoiService();

  /// Nombre d'échecs consécutifs de chargement des routes : sert au repli
  /// exponentiel (5 s, 15 s, 35 s, 75 s… plafonné) pour éviter de marteler
  /// Overpass quand le réseau est mauvais. Réinitialisé dès un succès.
  int _tentativesRoutes = 0;

  /// Nombre d'échecs consécutifs de chargement des POIs : même repli
  /// exponentiel que les routes (5 s → 15 s → 35 s… plafonné), pour ne pas
  /// asphyxier Overpass avec des retries rapprochés sur réseau instable.
  int _tentativesPois = 0;

  @override
  void initState() {
    super.initState();
    _initTileProvider();

    _statusSub = tileDownloadService.status.listen((status) {
      if (mounted) setState(() => _lastStatus = status);
    });

    _progressSub = tileDownloadService.progress.listen((pct) {
      if (mounted) setState(() => _downloadProgress = pct);
    });

    _rafraichissementSimulation = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _reconstruirePolylignes(),
    );

    _rafraichissementRoutes = Timer.periodic(
      const Duration(hours: 4),
      (_) => _chargerRoutes(),
    );

    _rafraichissementPrefetch = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _prefetchTuiles(),
    );

    _rafraichissementStats = Timer.periodic(
      const Duration(minutes: 3),
      (_) => _chargerZonesTrafic(),
    );

    _interactionSurBoutons();
  }

  @override
  void didUpdateWidget(TrafficMap oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Pendant le calcul d'un itinéraire, tout le travail de la carte
    // (polylignes, routes, POIs, zones, tuiles, timers) est suspendu.
    if (widget.suspendreTravailCarte &&
        !oldWidget.suspendreTravailCarte) {
      _mettreEnPauseTravailCarte();
    } else if (!widget.suspendreTravailCarte &&
        oldWidget.suspendreTravailCarte) {
      _reprendreTravailCarte();
    }

    if (widget.modeSombre != oldWidget.modeSombre) {
      final nouveauMode = widget.modeSombre
          ? _ModeCarte.sombre
          : _ModeCarte.claire;
      if (_modeCarte != nouveauMode &&
          _modeCarte != _ModeCarte.satellite) {
        setState(() => _modeCarte = nouveauMode);
        _reconstruirePolylignes();
      }
    }

    if (widget.versionZonesTrafic != oldWidget.versionZonesTrafic) {
      unawaited(_chargerZonesTrafic());
    }

    if (widget.modeNavigation != oldWidget.modeNavigation) {
      if (widget.modeNavigation) {
        _demarrerSuiviNavigation();
      } else {
        _arreterSuiviNavigation();
      }
    }

    if (!identical(oldWidget.itinerairePoints, widget.itinerairePoints)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _reconstruirePolylignes();
        if (widget.itinerairePoints == null ||
            widget.itinerairePoints!.length < 2) {
          // Itinéraire annulé : on recharge la vue pour afficher toutes les
          // rues de la zone courante.
          unawaited(_chargerRoutes());
        } else {
          // Nouveau tracé : on préchauffe les tuiles du fond de carte le
          // long du couloir pour éviter l'écran blanc de 1 à 2 s pendant
          // l'animation de la vue d'ensemble.
          unawaited(_prechargerTuilesCouloir(widget.itinerairePoints!));
        }
      });
    } else if (widget.itineraireDebutVisuel !=
        oldWidget.itineraireDebutVisuel) {
      // Le suivi réél a avancé : la portion parcourue derrière l'utilisateur
      // doit disparaître du rendu. On rebâtit juste les polylignes.
      _reconstruirePolylignes();
    }

    // Nouvelle étape posée (ou retirée) : son raccord en pointillés, si elle
    // est hors chaussée, doit être reconstruit même quand le tracé reste le
    // même objet.
    if (!identical(oldWidget.pointEtape, widget.pointEtape)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reconstruirePolylignes();
      });
    }

    // Bouton « lignes » réactivé : rien n'a été construit pendant qu'elles
    // étaient masquées, il faut rebâtir les polylignes de la vue courante.
    if (widget.afficherLignesTrafic && !oldWidget.afficherLignesTrafic) {
      _reconstruirePolylignes();
    }
    // Désactivé (pendant un itinéraire par exemple) : on cache les lignes
    // encore affichées et on les met de côté pour un retour instantané.
    if (!widget.afficherLignesTrafic && oldWidget.afficherLignesTrafic) {
      _reconstruirePolylignes();
    }

    // Nouvel itinéraire calculé (segments du tracé connus) : on précharge le
    // couloir bleu → vert dans le cache local pour pouvoir afficher le tracé
    // comme lignes de circulation colorées (rien n'est re-tracé).
    if (!identical(
        oldWidget.itineraireSegmentIds, widget.itineraireSegmentIds)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.itineraireSegmentIds != null &&
            widget.itineraireSegmentIds!.isNotEmpty) {
          unawaited(_prechargerCouloirItineraire());
        } else {
          _reconstruirePolylignes();
        }
      });
    }

    final newPos = widget.positionActuelle;
    if (newPos != null) {
      final newLatLng = LatLng(newPos.latitude, newPos.longitude);
      final oldPos = _displayedPosition;

      void nettoyerAnimation() {
        _positionAnimController?.stop();
        _positionAnimController?.dispose();
        _positionAnimController = null;
        _positionAnimation = null;
      }

      if (widget.modeNavigation) {
        // En navigation la caméra suit elle-même (ticker) : on pose le point
        // bleu directement sur la fix neuve. Le tween 300 ms déclenchait un
        // setState PAR TRAME → re-construction des couches polylignes
        // (600→1600) à chaque frame, d'où les ratés du point bleu quand le
        // trafic est affiché. La caméra lissée absorbe la discontinuité.
        nettoyerAnimation();
        _displayedPosition = newLatLng;
      } else if (oldPos == null) {
        _displayedPosition = newLatLng;
      } else {
        // Une nouvelle mesure GPS arrive parfois en plein milieu de
        // l'animation précédente (distanceFilter=1m en déplacement) :
        // reprendre depuis la POSITION VISIBLE ACTUELLE, pas depuis
        // l'ancienne cible, sinon le point bleu repart en arrière d'un coup
        // puis ré-accélère → zigzags « bizarres » pendant le déplacement.
        final animVisible = _positionAnimController;
        final enCours = animVisible?.isAnimating ?? false;
        final base = enCours && _positionAnimation != null
            ? _positionAnimation!.value
            : oldPos;

        nettoyerAnimation();
        _positionAnimController = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 300),
        );
        _positionAnimation = LatLngTween(
          begin: base,
          end: newLatLng,
        ).animate(CurvedAnimation(
          parent: _positionAnimController!,
          curve: Curves.easeOut,
        ));
        _positionAnimation!.addListener(() {
          if (mounted) setState(() {});
        });
        _positionAnimController!.forward();
        _displayedPosition = newLatLng;
      }

      _prefetchTuiles();
    }
  }

  void _demarrerLongPress(Offset position) {
    _longPressTimer?.cancel();
    _zoomOutTimer?.cancel();
    _longPressActif = false;
    _pointeurBouge = false;
    _pointerDownTime = DateTime.now();
    _pointerDownPos = position;

    _longPressTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _longPressActif = true;

      // Après une localisation, le suivi navigation réécrit la caméra à
      // chaque frame et ramène le zoom vers sa cible : sans interruption,
      // chaque pas de dézoom serait annulé aussitôt émis. Comme pour un
      // glissement manuel, l'appui long reprend la main sur la caméra.
      _camAnim?.dispose();
      _camAnim = null;
      widget.onNavigationInterrompue?.call();

      final center = widget.mapController.camera.pointToLatLng(
        Point(position.dx, position.dy),
      );

      _zoomOutTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) {
          final zoom = widget.mapController.camera.zoom;
          if (zoom > 2) {
            widget.mapController.move(center, zoom - 0.12);
          }
        },
      );
    });
  }

  void _annulerLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _zoomOutTimer?.cancel();
    _zoomOutTimer = null;

    if (!_longPressActif && !_pointeurBouge && _pointerDownPos != null && _pointerDownTime != null) {
      final duree = DateTime.now().difference(_pointerDownTime!);
      if (duree.inMilliseconds < 500 && !_doubleTapEnCours) {
        final point = widget.mapController.camera.pointToLatLng(
          Point(_pointerDownPos!.dx, _pointerDownPos!.dy),
        );
        _singleTapTimer = Timer(const Duration(milliseconds: 180), () {
          if (!mounted) return;
          // En mode pose d'épingle, un appui simple ne doit ni sélectionner
          // un pin ni ouvrir les infos d'un lieu : la carte sert uniquement
          // à être déplacée sous l'épingle de prévisualisation.
          if (!_modePoserEpingle) {
            widget.onMapTap?.call(point);
          }
          _singleTapTimer = null;
        });
      }
    }

    _longPressActif = false;
    _doubleTapEnCours = false;
    _pointeurBouge = false;
    _pointerDownTime = null;
    _pointerDownPos = null;
    // Défensif : si un bouton a été démonté en cours de geste, son Listener
    // enfant n'a pas pu remettre le flag à false — on le nettoie ici pour ne
    // jamais avaler les appuis suivants.
    _appuiBoutonAction = false;
  }

  void _annulerSansTap() {
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _zoomOutTimer?.cancel();
    _zoomOutTimer = null;
    _longPressActif = false;
    _doubleTapEnCours = false;
    _pointeurBouge = false;
    _pointerDownTime = null;
    _pointerDownPos = null;
    _appuiBoutonAction = false;
  }

  /// Coupe tout le travail périodique de la carte (polylignes, routes, POIs,
  /// zones, prefetch de tuiles) pendant le calcul d'un itinéraire : plus
  /// aucun timer ne se déclenche, les chargements en attente sont annulés.
  void _mettreEnPauseTravailCarte() {
    _rafraichissementSimulation?.cancel();
    _rafraichissementRoutes?.cancel();
    _rafraichissementPrefetch?.cancel();
    _rafraichissementStats?.cancel();
    _debounceRoutes?.cancel();
    _debounceRoutesPrefetch?.cancel();
    _debouncePois?.cancel();
  }

  /// Reprend le travail de la carte après le calcul : relance les timers et
  /// rebâtit la vue courante (polylignes, POIs, routes, zones) immédiatement.
  void _reprendreTravailCarte() {
    _rafraichissementSimulation = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _reconstruirePolylignes(),
    );
    _rafraichissementRoutes = Timer.periodic(
      const Duration(hours: 4),
      (_) => _chargerRoutes(),
    );
    _rafraichissementPrefetch = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _prefetchTuiles(),
    );
    _rafraichissementStats = Timer.periodic(
      const Duration(minutes: 3),
      (_) => _chargerZonesTrafic(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reconstruirePolylignes();
      unawaited(_chargerPois());
      unawaited(_chargerRoutes());
      unawaited(_chargerZonesTrafic());
    });
  }

  @override
  void dispose() {
    _rafraichissementSimulation?.cancel();
    _rafraichissementRoutes?.cancel();
    _rafraichissementPrefetch?.cancel();
    _rafraichissementStats?.cancel();
    _prefetchService.dispose();
    _debounceRoutes?.cancel();
    _debounceRoutesPrefetch?.cancel();
    _debouncePois?.cancel();
    _debounceJournalMolette?.cancel();
    _positionAnimController?.dispose();
    _camAnim?.dispose();
    _navTicker?.dispose();
    _timerFinChargement?.cancel();
    _timerConsoTuiles?.cancel();
    _timerConsoTuiles = null;
    _timerBoutons?.cancel();
    _annulerLongPress();
    _statusSub?.cancel();
    _progressSub?.cancel();
    _menuCartesScroll.dispose();
    super.dispose();
  }

  Future<void> _initTileProvider() async {
    if (!kIsWeb) {
      unawaited(initFmtc());
      try {
        await waitForFmtc.timeout(const Duration(seconds: 30));
      } catch (e) {
        debugPrint('[KinFlow] FMTC indisponible, carte en réseau seul: $e');
      }
    }
    if (mounted) {
      setState(() {
        _fmtcReady = true;
        if (kIsWeb || !fmtcSucceeded) {
          _tileProvider = null;
        } else {
          _tileProvider = FMTCTileProvider(
            stores: const {'kinshasa': BrowseStoreStrategy.readUpdateCreate},
            loadingStrategy: BrowseLoadingStrategy.cacheFirst,
            // Une tuile introuvable ou en erreur réseau renverrait une
            // exception remontant en erreur Flutter non gérée. On renvoie
            // une tuile transparente à la place : le rendu affiche le fond
            // gris via tileBuilder sans jamais planter.
            errorHandler: (_) => TileProvider.transparentImage,
          );
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onMapReady();
        if (mounted) {
          setState(() {
            _carteRendue = true;
          });
        }
        unawaited(_chargerRoutes());
        unawaited(_chargerPois());
        unawaited(_chargerZonesTrafic());
        _demarrerSuiviConsoTuiles();
      });
    }
  }

  /// Suivi temporaire de la consommation des cartes : la taille du cache FMTC
  /// grandit de tous les octets téléchargés depuis le réseau (tuiles à la
  /// volée, chargées en naviguant). On snapshot cette taille régulièrement et
  /// on comptabilise chaque augmentation dans « Cartes ».
  void _demarrerSuiviConsoTuiles() {
    if (!fmtcSucceeded || kIsWeb || _timerConsoTuiles != null) return;
    unawaited(_capturerTailleCache());
    _timerConsoTuiles = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_capturerTailleCache());
    });
  }

  bool _captureConsoTuilesEnCours = false;

  Future<void> _capturerTailleCache() async {
    if (_captureConsoTuilesEnCours) return;
    _captureConsoTuilesEnCours = true;
    try {
      final taille =
          await FMTCStore('kinshasa').stats.size;
      final octets = (taille * 1024).round();
      final delta = octets - _tailleCachePrecedenteKiBToOctets;
      if (delta > 0) {
        DataUsageService.instance.enregistrer(
          CategorieData.cartes,
          octetsRecus: delta,
        );
      }
      _tailleCachePrecedenteKiBToOctets = octets;
    } catch (_) {
      // Cache indisponible (pas encore prêt) : on ignore ce tick.
    } finally {
      _captureConsoTuilesEnCours = false;
    }
  }

  /// Charge les signalements récents et calcule les zones de trafic
  /// collaboratif (rayon qui grandit avec le nombre de témoins).
  Future<void> _chargerZonesTrafic() async {
    if (!_fmtcReady || !mounted) return;
    if (widget.suspendreTravailCarte) return;
    // Nuit : tout est vert, les signalements des autres ne changent rien à
    // l'affichage. On économise l'appel Supabase toutes les 3 minutes.
    if (_estNuit()) return;
    final brut = await SupabaseService().chargerSignalementsRecents();
    if (!mounted) return;
    final zones = _statsService.calculerZones(
      TrafficStatsService.depuisSupabase(brut),
    );
    setState(() => _zonesTrafic = zones);
    widget.onZonesTrafic?.call(zones);
    _reconstruirePolylignes();
  }

  /// Renvoie la zone la plus attestée dont un cône de vision couvre le point,
  /// ou null (aucune statistique fiable à cet endroit précis).
  /// La zone ne teinte plus un segment entier : seul le point couvert change
  /// de couleur, ce qui rend le rendu précis rue par rue.
  ZoneTrafic? _zonePourPoint(LatLng point) {
    if (_zonesTrafic.isEmpty) return null;
    for (final zone in _zonesTrafic) {
      if (zone.couvre(point)) return zone;
    }
    return null;
  }

  void _basculerModePoserEpingle() {
    _interactionSurBoutons();
    setState(() => _modePoserEpingle = !_modePoserEpingle);
    if (_modePoserEpingle) {
      // Pendant la pose, la carte doit rester entièrement libre sous
      // l'épingle : on coupe le suivi navigation et tout geste en attente.
      widget.onNavigationInterrompue?.call();
      _annulerSansTap();
    }
  }

  /// Réveille les boutons flottants (opacité pleine) et reprogramme leur
  /// estompage : appelé à chaque interaction de l'utilisateur avec la carte
  /// ou les boutons eux-mêmes.
  void _interactionSurBoutons() {
    _timerBoutons?.cancel();
    if (!_boutonsVisibles) {
      if (mounted) setState(() => _boutonsVisibles = true);
    }
    _timerBoutons = Timer(_dureeAvantEstompage, () {
      if (!mounted) return;
      if (_modePoserEpingle) {
        _interactionSurBoutons();
        return;
      }
      setState(() => _boutonsVisibles = false);
    });
  }

  /// Pose l'épingle de prévisualisation à la coordonnée géographique
  /// actuellement au centre de l'écran, puis quitte le mode pose.
  void _poserEpingle() {
    final centre = widget.mapController.camera.center;
    if (!centre.latitude.isFinite || !centre.longitude.isFinite) return;
    setState(() => _modePoserEpingle = false);
    widget.onPoserEpingle?.call(centre);
  }

  void _ouvrirMenuCartes() {
    if (!_fmtcReady || !mounted) return;
    _interactionSurBoutons();
    final sombre = _modeCarte == _ModeCarte.sombre;
    showModalBottomSheet<void>(
      context: context,
      // Contrôle la hauteur nous-mêmes : sans cela la feuille est plafonnée
      // et le geste de glissement sert à la fermer, pas à défiler la liste.
      isScrollControlled: true,
      backgroundColor:
          sombre ? KinColors.surfaceSombre : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: Scrollbar(
            thumbVisibility: true,
            controller: _menuCartesScroll,
            child: ListView(
              controller: _menuCartesScroll,
              padding: EdgeInsets.zero,
              children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Cartes',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: sombre ? KinColors.texteSombre : Colors.black87,
                  ),
                ),
              ),
              OptionModeCarte(
                icone: Icons.light_mode,
                libelle: 'Claire',
                selectionne: _modeCarte == _ModeCarte.claire,
                sombre: sombre,
                onTap: () => _choisirMode(_ModeCarte.claire),
              ),
              OptionModeCarte(
                icone: Icons.dark_mode,
                libelle: 'Sombre',
                selectionne: _modeCarte == _ModeCarte.sombre,
                sombre: sombre,
                onTap: () => _choisirMode(_ModeCarte.sombre),
              ),
              OptionModeCarte(
                icone: Icons.satellite_alt,
                libelle: 'Satellite',
                selectionne: _modeCarte == _ModeCarte.satellite,
                sombre: sombre,
                onTap: () => _choisirMode(_ModeCarte.satellite),
              ),
              OptionModeCarte(
                icone: Icons.wb_sunny,
                libelle: 'Positron',
                selectionne: _modeCarte == _ModeCarte.positron,
                sombre: sombre,
                onTap: () => _choisirMode(_ModeCarte.positron),
              ),
              OptionModeCarte(
                icone: Icons.nightlight_round,
                libelle: 'Dark Matter',
                selectionne: _modeCarte == _ModeCarte.darkMatter,
                sombre: sombre,
                onTap: () => _choisirMode(_ModeCarte.darkMatter),
              ),
OptionModeCarte(
              icone: Icons.explore,
              libelle: 'Voyager',
              selectionne: _modeCarte == _ModeCarte.voyager,
              sombre: sombre,
              onTap: () => _choisirMode(_ModeCarte.voyager),
            ),
              OptionModeCarte(
                icone: Icons.terrain,
                libelle: 'Topographique',
                selectionne: _modeCarte == _ModeCarte.topo,
                sombre: sombre,
                onTap: () => _choisirMode(_ModeCarte.topo),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _choisirMode(_ModeCarte mode) {
    Navigator.of(context).pop();
    if (mode == _modeCarte) return;
    setState(() => _modeCarte = mode);
    _reconstruirePolylignes();
    // En mode navigation la caméra est pilotée par le suivi : pas de
    // survol Afrique qui entrerait en conflit avec lui.
    if (mode == _ModeCarte.satellite &&
        _carteRendue &&
        !widget.modeNavigation) {
      _demarrerVueAfrique();
    }
  }

  void _demarrerVueAfrique() {
    final cible = CameraFit.bounds(
      bounds: bornesAfrique,
      padding: const EdgeInsets.all(24),
    ).fit(widget.mapController.camera);

    _apresAnimation = () {
      final position = widget.positionActuelle;
      if (position != null) {
        _animerCarteVers(
          LatLng(position.latitude, position.longitude),
          17,
          widget.mapController.camera.rotation,
          duree: const Duration(milliseconds: 2400),
        );
      }
    };

    _animerCarteVers(
      cible.center,
      cible.zoom,
      cible.rotation,
      duree: const Duration(milliseconds: 1400),
    );
  }

  void _animerCarteVers(
    LatLng centre,
    double zoom,
    double rotation, {
    Duration duree = const Duration(milliseconds: 1200),
  }) {
    final camera = widget.mapController.camera;
    _animDebutCentre = camera.center;
    _animDebutZoom = camera.zoom;
    _animDebutRotation = camera.rotation;
    _animCibleCentre = centre;
    _animCibleZoom = zoom;
    _animCibleRotation = rotation;

    _camAnim?.dispose();
    _camAnim = AnimationController(vsync: this, duration: duree);
    _camAnim!.addListener(_surTickCam);
    _camAnim!.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        final action = _apresAnimation;
        _apresAnimation = null;
        if (action != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => action());
        }
      }
    });
    _camAnim!.forward();
  }

  void _surTickCam() {
    final anim = _camAnim;
    if (anim == null) return;
    final k = Curves.easeInOutCubic.transform(anim.value);
    final centre = LatLng(
      _animDebutCentre!.latitude +
          (_animCibleCentre!.latitude - _animDebutCentre!.latitude) * k,
      _animDebutCentre!.longitude +
          (_animCibleCentre!.longitude - _animDebutCentre!.longitude) * k,
    );
    final zoom = _animDebutZoom + (_animCibleZoom - _animDebutZoom) * k;
    final delta = deltaRotation(_animDebutRotation, _animCibleRotation);
    final rotation = normaliserDegre(_animDebutRotation + delta * k);
    widget.mapController.move(centre, zoom);
    widget.mapController.rotate(rotation);
  }

  void _demarrerSuiviNavigation() {
    if (!widget.mapController.camera.center.latitude.isFinite) {
      // Caméra pas encore prête : nouvelle tentative à la frame suivante
      // tant que le mode est actif, au lieu d'un abandon silencieux.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.modeNavigation) _demarrerSuiviNavigation();
      });
      return;
    }
    _navRotationCourante = widget.mapController.camera.rotation;
    _navCentreCourant = widget.mapController.camera.center;
    // Le décalage écran repart toujours de zéro : l'entrée dans le suivi
    // se fait par un glissement progressif vers le bas, jamais par un saut.
    _navProportionDecalageCourante = 0;
    // Le zoom de départ est celui déjà affiché : après un centrage animé
    // (bouton position) il vaut 17, et après une interruption manuelle il
    // conserve le zoom choisi par l'utilisateur. Le suivi ne doit jamais
    // écraser un zoom choisi librement.
    _navZoomCible = widget.mapController.camera.zoom;
    _navDernierTick = null;
    _navRotationCible = null;
    _navDerniereMesure = null;
    _navDernierePositionRotationContinue = null;
    _gestesActifs = 0;
    // Nouvelle session de suivi : référentiel d'orientation remis à zéro.
    // La rotation affichée (vue d'ensemble d'un itinéraire, bouton
    // « Ma position ») devient la référence angulaire : le premier cap GPS
    // ne réaligne plus la carte d'un coup, seul un vrai déplacement la fera
    // pivoter (double seuil 10°/5 m).
    _orientationNav.reinitialiser(
      rotationInitialeDegres: widget.mapController.camera.rotation,
    );
    _navTicker ??= createTicker(_surTickNavigation);
    if (!_navTicker!.isActive) _navTicker!.start();
  }

  void _arreterSuiviNavigation() {
    _navTicker?.stop();
    _gestesActifs = 0;
    _navDernierTick = null;
    _navCentreCourant = null;
    _navDernierePositionRotationContinue = null;
  }

  /// Boucle de suivi navigation : la caméra glisse en continu vers la
  /// position utilisateur (décalée vers le bas de l'écran). L'orientation,
  /// elle, est événementielle, pilotée par [ControleurOrientation] :
  ///
  ///  - chaque NOUVELLE mesure GPS alimente le filtre circulaire du cap
  ///    puis le test à double seuil : delta >= 10° ET 5 m parcourus depuis
  ///    la dernière référence (référentiel glissant réarmé à chaque
  ///    recadrage) ;
  ///  - au déclenchement, la rotation cible devient `-cap` (direction vers
  ///    le haut) et la carte y pivote par lissage exponentiel — jamais par
  ///    un saut sec ;
  ///  - entre deux recadrages la rotation est totalement figée : les petites
  ///    variations de trajectoire et le bruit des capteurs ne font rien.
  void _surTickNavigation(Duration elapsed) {
    if (!mounted ||
        !widget.modeNavigation ||
        !_fmtcReady ||
        widget.positionActuelle == null) {
      return;
    }
    // Un geste utilisateur est en cours (pincement, pivotement, double-clic) :
    // on suspend l'écriture caméra du suivi pour ne pas lui faire opposition.
    if (_gestesActifs > 0) return;

    final dt = (_navDernierTick == null
            ? 16
            : (elapsed - _navDernierTick!).inMilliseconds)
        .clamp(1, 120)
        .toInt();
    _navDernierTick = elapsed;
    final k = 1 - exp(-_navFacteurLissage * dt / 1000);

    final camera = widget.mapController.camera;
    final mesure = widget.positionActuelle!;
    final cible = LatLng(mesure.latitude, mesure.longitude);

    // Analyse d'orientation : UNE fois par mesure GPS réellement nouvelle.
    if (!identical(mesure, _navDerniereMesure)) {
      _navDerniereMesure = mesure;
      final capBrut = widget.capUtilisateur;
      if (capBrut != null) {
        final rotationCibleRecadrage = _orientationNav.mettreAJour(
          capBrutDegres: capBrut,
          position: cible,
          precisionMetres: mesure.accuracy,
        );
        if (rotationCibleRecadrage != null) {
          Journal.i('NAVIGATION', 'Recadrage : la carte se réoriente', {
            'cap_deg': capBrut,
            'nouvelle_rotation': rotationCibleRecadrage,
            'precision_m': mesure.accuracy,
          });
          _navRotationCible = rotationCibleRecadrage;
        }
      }

      // Adaptation continue : au lieu d'attendre les seuls recadrages à
      // double seuil, la carte suit EN DOUCEUR la direction filtrée du
      // déplacement (le point de direction du trajet reste « droit », vers
      // le haut de l'écran). Le filtre circulaire du cap a déjà gommé le
      // bruit ; le seuil minimal ci-dessous empêche les micro-rotations
      // perpétuelles tant que la trajectoire ne va pas vraiment plus « au
      // haut » que la rotation affichée.
      //
      // GARDE-FOU : l'adaptation n'est appliquée qu'après un réel
      // déplacement depuis la dernière adaptation ([seuilDistanceMetres]).
      // Sans ce garde-fou, le cap filtré qui dérive lentement à l'arrêt
      // (GPS qui renvoie 0° à l'immobilité) ferait tourner la carte toute
      // seule, sans que le pied ait bougé.
      final capFiltre = _orientationNav.capFiltre;
      if (capFiltre != null) {
        final derniere = _navDernierePositionRotationContinue;
        final deplacementSuffisant = derniere == null ||
            distanceHaversineMetres(
              derniere.latitude,
              derniere.longitude,
              cible.latitude,
              cible.longitude,
            ) >=
                seuilDistanceMetres;
        if (deplacementSuffisant) {
          final cibleContinue = normaliserDegre(-capFiltre);
          final cibleEnCours = _navRotationCible ?? _navRotationCourante;
          if (deltaRotation(cibleEnCours, cibleContinue).abs() >=
              _seuilRotationContinueDegres) {
            _navRotationCible = cibleContinue;
            _navDernierePositionRotationContinue = cible;
          }
        }
      }
    }

    // Centre de départ : l'état interne lissé, JAMAIS camera.center (qui
    // contient le décalage écran et provoquerait des oscillations).
    final depart = _navCentreCourant ?? camera.center;
    _navCentreCourant = LatLng(
      depart.latitude + (cible.latitude - depart.latitude) * k,
      depart.longitude + (cible.longitude - depart.longitude) * k,
    );

    // Lissage du zoom.
    final zoom = camera.zoom + (_navZoomCible - camera.zoom) * k;

    // Lissage de la rotation vers la cible du dernier recadrage. Facteur
    // plus doux que la caméra : le pivotement doit rester confortable.
    var rotation = _navRotationCourante;
    final cibleRot = _navRotationCible;
    if (cibleRot != null) {
      final kRot = 1 - exp(-_navFacteurLissageRotation * dt / 1000);
      final delta = deltaRotation(rotation, cibleRot);
      if (delta.abs() > 0.3) {
        rotation = normaliserDegre(rotation + delta * kRot);
      } else {
        rotation = cibleRot;
        _navRotationCible = null;
      }
    }
    _navRotationCourante = rotation;

    // Décalage écran appliqué après contre-rotation par flutter_map : le
    // point utilisateur descend sous le centre quelle que soit
    // l'orientation. La proportion est lissée : elle monte de 0 vers sa
    // cible au démarrage du suivi au lieu d'être posée d'un bloc.
    _navProportionDecalageCourante +=
        (_navProportionDecalage - _navProportionDecalageCourante) * k;
    final decalage = Offset(
      0,
      camera.nonRotatedSize.y * _navProportionDecalageCourante,
    );

    // Zones mortes : on n'écrit dans la caméra que si quelque chose a
    // réellement changé (évite les micro-écritures qui font trembler).
    final bougeNecessaire =
        (_navCentreCourant!.latitude - camera.center.latitude).abs() >
                1e-9 ||
            (_navCentreCourant!.longitude - camera.center.longitude).abs() >
                1e-9 ||
            (zoom - camera.zoom).abs() > 0.001;
    if (bougeNecessaire) {
      widget.mapController.move(_navCentreCourant!, zoom, offset: decalage);
    }
    if ((rotation - camera.rotation).abs() > 0.05) {
      widget.mapController.rotate(rotation);
    }
  }

  void _surEvenementCarte(MapEvent event) {
    // Les mouvements émis par le suivi navigation (mapController) ne sont
    // pas des interactions : ils ne doivent pas relancer chargements et
    // débounces à chaque frame.
    if (event.source == MapEventSource.mapController) {
      return;
    }
    // Suivi des gestes : on suspend le ticker navigation de leur début à leur
    // fin (glisser, pincer, pivoter, double-clic de zoom) pour que la caméra
    // lui appartienne pleinement pendant le geste.
    if (event is MapEventMoveStart ||
        event is MapEventRotateStart ||
        event is MapEventDoubleTapZoomStart) {
      _gestesActifs++;
    } else if (event is MapEventMoveEnd ||
        event is MapEventRotateEnd ||
        event is MapEventDoubleTapZoomEnd) {
      if (_gestesActifs > 0) _gestesActifs--;
    }
    _journaliserGeste(event);
    // Pendant la navigation, un zoom manuel (pincement, molette, double-tap)
    // devient la nouvelle cible du suivi : le suivi continue de recentrer la
    // position mais respecte le niveau de zoom choisi par l'utilisateur. La
    // rotation courante est aussi resynchronisée pour ne pas contre-pivoter
    // une torsade à deux doigts ; le prochain recadrage réalignera la carte.
    if (widget.modeNavigation) {
      _navZoomCible = widget.mapController.camera.zoom;
      _navRotationCourante = widget.mapController.camera.rotation;
    }
    if (event is MapEventMove) {
      _surZoomChange();
      _debouncePois?.cancel();
      _debouncePois = Timer(const Duration(milliseconds: 550), () {
        if (mounted) unawaited(_chargerPois());
      });
      // Pendant le déplacement, on lance un prefetch des routes de la
      // zone vers laquelle on se dirige : les données arrivent avant
      // l'arrêt du geste et le cache est prêt au moment du rebuild.
      _debounceRoutesPrefetch?.cancel();
      _debounceRoutesPrefetch = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) unawaited(_prefetchRoutes());
      });
    }
    if (event is MapEventMoveEnd) {
      _debounceRoutes?.cancel();
      _debounceRoutes = Timer(const Duration(milliseconds: 900), () {
        if (mounted) unawaited(_chargerRoutes());
      });
      _debouncePois?.cancel();
      _debouncePois = Timer(const Duration(milliseconds: 1300), () {
        if (mounted) unawaited(_chargerPois());
      });
      _prefetchTuiles();
    }
  }

  /// Résumé d'un geste utilisateur sur la carte : une seule ligne par geste,
  /// écrite à sa FIN, avec le zoom et la rotation obtenus.
  void _journaliserGeste(MapEvent event) {
    final camera = widget.mapController.camera;
    if (event is MapEventMoveEnd) {
      Journal.i('CARTE', 'Geste carte terminé', {
        'type': 'glisser / pincer',
        'zoom': camera.zoom,
        'rotation_deg': camera.rotation,
      });
    } else if (event is MapEventRotateEnd) {
      Journal.i('CARTE', 'Pivotement manuel de la carte', {
        'rotation_deg': camera.rotation,
      });
    } else if (event is MapEventDoubleTapZoomEnd) {
      Journal.i('CARTE', 'Zoom par double appui', {'zoom': camera.zoom});
    } else if (event is MapEventScrollWheelZoom) {
      _debounceJournalMolette?.cancel();
      _debounceJournalMolette = Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        Journal.i('CARTE', 'Zoom à la molette', {
          'zoom': widget.mapController.camera.zoom,
        });
      });
    }
  }

  Future<void> _chargerPois() async {
    if (!_fmtcReady || !mounted) return;
    if (widget.suspendreTravailCarte) return;
    if (CircuitBreakerPois.ouvert) return;

    final camera = widget.mapController.camera;
    if (camera.zoom < zoomMinPois) {
      if (_pois.isNotEmpty) {
        setState(() => _pois = []);
      }
      return;
    }

    // Les POIs sont chargés par REGION VISIBLE (arrondie) plutôt que sur
    // toute la ville : Overpass traite une requête locale bien plus vite
    // qu'un balayage de Kinshasa entier, ce qui soulage les serveurs 429.
    final rond = _arrondirBoundsEtendu(camera.visibleBounds, 0.15);
    final cle = '${rond.south}|${rond.west}|${rond.north}|${rond.east}';

    final enCache = _poiCache[cle];
    if (enCache != null) {
      if (identical(enCache, _pois)) return;
      setState(() => _pois = enCache);
      return;
    }

    try {
      final pois = await _poiService.telechargerPois(rond);
      _tentativesPois = 0;
      _poiCache[cle] = pois;
      while (_poiCache.length > 30) {
        _poiCache.remove(_poiCache.keys.first);
      }
      if (mounted) {
        setState(() => _pois = pois);
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargement POI: $e');
      CircuitBreakerPois.enregistrerEchec();
      _debouncePois?.cancel();
      // Repli exponentiel (5 s, 15 s, 35 s, 75 s… plafonné à 120 s) : quand
      // Overpass souffre, on espace les tentatives au lieu de marteler.
      final delai = const Duration(seconds: 5) * (1 << min(_tentativesPois, 4));
      final delaiMs = min(delai.inMilliseconds, 120000);
      _tentativesPois++;
      _debouncePois = Timer(Duration(milliseconds: delaiMs), () {
        if (mounted) unawaited(_chargerPois());
      });
    }
  }

  void _surZoomChange() {
    if (!_carteRendue) return;
    final zoom = widget.mapController.camera.zoom;
    final signature = _seuilPoiParZoom(zoom) * 100 + _espacementPois(zoom).round();
    if (signature != _signatureZoom) {
      _signatureZoom = signature;
      if (mounted) setState(() {});
    }
  }

  int _seuilPoiParZoom(double zoom) {
    if (zoom < zoomMinPois) return -1;
    if (zoom < 14.5) return 10;
    if (zoom < 15.5) return 19;
    if (zoom < 16.5) return 23;
    return 25;
  }

  double _espacementPois(double zoom) {
    if (zoom >= 16.5) return 48;
    if (zoom >= 16) return 40;
    if (zoom >= 15) return 55;
    if (zoom >= 14.5) return 70;
    return 90;
  }

  List<Poi> _poisVisibles() {
    if (!_carteRendue) return const [];
    final camera = widget.mapController.camera;
    final zoom = camera.zoom;
    if (zoom < zoomMinPois) return const [];

    final seuil = _seuilPoiParZoom(zoom);
    if (seuil < 0) return const [];

    final espace = _espacementPois(zoom);

    final parType = <String, List<Poi>>{};
    for (final poi in _pois) {
      if (prioritePoi(poi.type) > seuil) continue;
      parType.putIfAbsent(poi.type, () => []).add(poi);
    }
    final types = parType.keys.toList()
      ..sort((a, b) => prioritePoi(a).compareTo(prioritePoi(b)));

    final visibles = <Poi>[];
    final poses = <Offset>[];
    final indices = <String, int>{};
    final places = <String, int>{};

    var aAvance = true;
    while (aAvance) {
      aAvance = false;
      for (final type in types) {
        final liste = parType[type]!;
        final i = indices[type] ?? 0;
        if (i >= liste.length) continue;
        indices[type] = i + 1;
        aAvance = true;
        if ((places[type] ?? 0) >= maxPoisVisiblesParType) continue;
        final poi = liste[i];
        final ecran = camera.latLngToScreenPoint(poi.point);
        final pos = Offset(ecran.x, ecran.y);
        var tropProche = false;
        for (final p in poses) {
          if ((p - pos).distance < espace) {
            tropProche = true;
            break;
          }
        }
        if (tropProche) continue;
        visibles.add(poi);
        poses.add(pos);
        places[type] = (places[type] ?? 0) + 1;
      }
    }
    return visibles;
  }

  Future<void> _chargerRoutes() async {
    if (!_fmtcReady || !mounted) return;
    if (widget.suspendreTravailCarte) return;

    final camera = widget.mapController.camera;
    if (camera.zoom < zoomMinGlobal) {
      if (_polylignesTrafic.isNotEmpty) {
        setState(() => _polylignesTrafic = []);
      }
      return;
    }

    // Pendant un itinéraire, la vue reste finie par le couloir : les
    // segments chargés ici alimentent uniquement le filtre du tracé
    // bleu → vert (cache partagé, donc aucun re-téléchargement).

    final detailsComplets = camera.zoom >= 15;
    // Étendre les bounds de 15 % pour que les petits panning après un
    // chargement soient déjà couverts par le cache.
    final rond = _arrondirBoundsEtendu(camera.visibleBounds, 0.15);

    // La zone visible (centrée sur la caméra) est la priorité : si une zone
    // déjà chargée la couvre, on redessine sans retélécharger.
    if (_aSegmentsPour(rond, detailsComplets)) {
      _reconstruirePolylignes();
      return;
    }

    // Pas de vidage avant le téléchargement : la zone vue n'est pas dans le
    // cache, mais les polylignes déjà affichées restent visibles pendant
    // l'attente (les zoommades rapides ne font pas clignoter la carte).
    // Le rebuild aura lieu quand les segments seront arrivés.
    try {
      final segments = await _roadService.obtenirRoutes(
        rond,
        detailsComplets: detailsComplets,
      );
      if (!mounted) return;

      _tentativesRoutes = 0;
      _segmentsCache[_cleSegments(rond, detailsComplets)] =
          _SegmentsParZone(segments, rond, detailsComplets);
      while (_segmentsCache.length > 40) {
        _segmentsCache.remove(_segmentsCache.keys.first);
      }
      Journal.i('CARTE', 'Coloration du trafic reconstruite', {
        'segments': segments.length,
        'zoom': camera.zoom,
        'details_complets': detailsComplets,
      });
      _reconstruirePolylignes();
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargement routes: $e');
      Journal.e('CARTE', 'Chargement des routes pour la carte échoué', {
        'erreur': '$e',
      });
      _reconstruirePolylignes();
      _debounceRoutes?.cancel();
      // Repli exponentiel : 5 s, 15 s, 35 s, 75 s… plafonné à 120 s. Tant que
      // le réseau est mauvais, on espace les tentatives au lieu de marteler.
      final delai =
          const Duration(seconds: 5) * (1 << min(_tentativesRoutes, 4));
      final delaiMs = min(delai.inMilliseconds, 120000);
      _tentativesRoutes++;
      _debounceRoutes = Timer(Duration(milliseconds: delaiMs), () {
        if (mounted) unawaited(_chargerRoutes());
      });
    }
  }

  /// Charge dans le cache local les segments traversés par l'itinéraire
  /// (le couloir bleu → vert), avec la même finesse que le moteur de calcul :
  /// court trajet → toutes classes de rues, longue distance → grands axes.
  /// Les zones déjà servies par [RoadService] (cache mémoire/disque partagé)
  /// ne déclenchent AUCUN téléchargement : disponible quasi instantanément.
  Future<void> _prechargerCouloirItineraire() async {
    if (!_fmtcReady || !mounted) return;
    if (widget.suspendreTravailCarte) return;
    final points = widget.itinerairePoints;
    if (points == null || points.length < 2) return;

    const marge = 0.03;
    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    var minLon = double.infinity;
    var maxLon = double.negativeInfinity;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    if (minLat > maxLat || minLon > maxLon) return;
    final couloir = LatLngBounds(
      LatLng(minLat - marge, minLon - marge),
      LatLng(maxLat + marge, maxLon + marge),
    );
    final lointain = (couloir.north - couloir.south) > 0.08 ||
        (couloir.east - couloir.west) > 0.08;
    final detailsComplets = !lointain;
    final rond = _arrondirBounds(couloir);

    if (_aSegmentsPour(rond, detailsComplets)) {
      _reconstruirePolylignes();
      return;
    }
    try {
      final segments = await _roadService.obtenirRoutes(
        couloir,
        detailsComplets: detailsComplets,
      );
      if (!mounted) return;
      _segmentsCache[_cleSegments(rond, detailsComplets)] =
          _SegmentsParZone(segments, rond, detailsComplets);
      while (_segmentsCache.length > 40) {
        _segmentsCache.remove(_segmentsCache.keys.first);
      }
      Journal.i('CARTE', 'Couloir de l\'itinéraire prêt pour affichage', {
        'segments': segments.length,
        'details_complets': detailsComplets,
      });
      _reconstruirePolylignes();
    } catch (e) {
      debugPrint('[KinFlow] Préchargement couloir itinéraire échoué: $e');
      _reconstruirePolylignes();
    }
  }

  /// Préchauffe les tuiles du FOND DE CARTE le long du couloir de
  /// l'itinéraire, aux zooms de la vue d'ensemble. Dès que le tracé est
  /// connu la caméra s'anime vers le parcours complet : si la zone n'est
  /// pas encore en cache, elle apparaît blanche pendant 1 à 2 s le temps
  /// que les tuiles arrivent. En les téléchargeant en parallèle de
  /// l'animation (même source et mêmes zooms que la carte affichée), la vue
  /// d'ensemble s'affiche instantanément. Fire-and-forget : l'écran n'attend
  /// jamais la fin du téléchargement.
  ///
  /// PASSE UNIQUE couvrant toute la plage de zooms : l'ancienne boucle
  /// annulait la passe précédente avec le même identifiant FMTC avant chaque
  /// démarrage, si bien que chaque zoom tuait la passe du zoom précédent et
  /// que seul le dernier zoom était réellement téléchargé — la vue
  /// d'ensemble (souvent z12-z13) restait grise longtemps.
  Future<void> _prechargerTuilesCouloir(List<LatLng> points) async {
    if (!_fmtcReady || kIsWeb || !mounted) return;
    // Le réseau seul n'a pas de cache à préchauffer.
    if (_tileProvider == null) return;
    // Le satellite est lourd et son itinéraire n'est pas dessiné : on
    // laisse la carte s'afficher normalement sans précharger.
    if (_modeCarte == _ModeCarte.satellite) return;

    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    var minLon = double.infinity;
    var maxLon = double.negativeInfinity;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    if (minLat > maxLat || minLon > maxLon) return;

    const marge = 0.02;
    final couloir = LatLngBounds(
      LatLng(minLat - marge, minLon - marge),
      LatLng(maxLat + marge, maxLon + marge),
    );

    final store = FMTCStore('kinshasa');
    try {
      final region = RectangleRegion(couloir).toDownloadable(
        minZoom: _zoomsPrechargementCouloir.first,
        maxZoom: _zoomsPrechargementCouloir.last,
        options: TileLayer(
          urlTemplate: _urlDuMode,
          userAgentPackageName: 'com.kinflow.kinflow',
        ),
      );
      final nombre = await store.download.countTiles(region);
      if (nombre <= 0 || nombre > _maxTuilesTotalesCouloir) return;

      // Une seule passe de téléchargement à la fois : on annule celle de
      // l'itinéraire précédent avant d'en lancer la nouvelle (un itinéraire
      // recalculé pendant que la passe tourne encore).
      await store.download.cancel(instanceId: _instanceIdTuilesCouloir);

      final (:downloadProgress, :tileEvents) = store.download.startForeground(
        region: region,
        parallelThreads: 2,
        skipExistingTiles: true,
        skipSeaTiles: true,
        retryFailedRequestTiles: false,
        instanceId: _instanceIdTuilesCouloir,
      );
      tileEvents.listen((_) {}, onError: (_) {});

      // Le téléchargement est lancé mais nul besoin d'attendre tout son
      // trajet : on le laisse finir en arrière-plan. On écoute juste les
      // erreurs de démarrage qui remonteraient en async vide.
      downloadProgress.listen((_) {}, onError: (_) {});
    } catch (e) {
      debugPrint('[KinFlow] Préchargement tuiles du couloir échoué: $e');
    }
    // Le widget est démonté : la passe de téléchargement ne doit pas rester
    // active sans lecteur (elle continuerait à écrire des octets en cache).
    if (!mounted) {
      await store.download.cancel(instanceId: _instanceIdTuilesCouloir);
    }
  }

  /// Prefetch les routes de la zone visible + une marge de 20 % : quand
  /// l'utilisateur panne légèrement, les données sont déjà en cache et le
  /// rebuild est instantané. Ne fait rien si la zone est déjà couverte.
  Future<void> _prefetchRoutes() async {
    if (!_fmtcReady || !mounted) return;
    if (widget.suspendreTravailCarte) return;
    // Nuit : pas de préchargement réseau, l'affichage au déplacement suffit.
    if (_estNuit()) return;
    final camera = widget.mapController.camera;
    if (camera.zoom < zoomMinGlobal) return;

    final detailsComplets = camera.zoom >= 15;
    final rond = _arrondirBoundsEtendu(camera.visibleBounds, 0.20);

    if (_aSegmentsPour(rond, detailsComplets)) return;

    try {
      final segments = await _roadService.obtenirRoutes(
        rond,
        detailsComplets: detailsComplets,
      );
      if (!mounted) return;

      _segmentsCache[_cleSegments(rond, detailsComplets)] =
          _SegmentsParZone(segments, rond, detailsComplets);
      while (_segmentsCache.length > 40) {
        _segmentsCache.remove(_segmentsCache.keys.first);
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur prefetch routes: $e');
    }
  }

  LatLngBounds _arrondirBounds(LatLngBounds b) {
    const f = 100.0;
    return LatLngBounds(
      LatLng(
        (b.south * f).floorToDouble() / f,
        (b.west * f).floorToDouble() / f,
      ),
      LatLng(
        (b.north * f).ceilToDouble() / f,
        (b.east * f).ceilToDouble() / f,
      ),
    );
  }

  /// Arrondit les bounds puis les étend de [facteur] (0.20 = +20 %) pour
  /// prefetcharger les routes de la zone avoisinante : les petits panning
  /// n'auront pas besoin d'un nouvel appel réseau.
  LatLngBounds _arrondirBoundsEtendu(LatLngBounds b, double facteur) {
    final centreLat = (b.north + b.south) / 2;
    final centreLon = (b.east + b.west) / 2;
    final demiLat = (b.north - b.south) / 2 * (1 + facteur);
    final demiLon = (b.east - b.west) / 2 * (1 + facteur);
    return _arrondirBounds(LatLngBounds(
      LatLng(centreLat - demiLat, centreLon - demiLon),
      LatLng(centreLat + demiLat, centreLon + demiLon),
    ));
  }

  String _cleSegments(LatLngBounds b, bool detailsComplets) {
    final r = _arrondirBounds(b);
    return '${detailsComplets ? 'd' : 'm'}|${r.south}|${r.west}|${r.north}|${r.east}';
  }

  bool _aSegmentsPour(LatLngBounds rond, bool detailsComplets) {
    for (final zone in _segmentsCache.values) {
      if (zone.detailsComplets || !detailsComplets) {
        if (_boundsContient(zone.bounds, rond)) return true;
      }
    }
    return false;
  }

  bool _boundsContient(LatLngBounds conteneur, LatLngBounds contenu) =>
      conteneur.north >= contenu.north &&
      conteneur.south <= contenu.south &&
      conteneur.east >= contenu.east &&
      conteneur.west <= contenu.west;

  void _prefetchTuiles() {
    if (!_fmtcReady || kIsWeb || !mounted) return;
    if (widget.suspendreTravailCarte) return;
    // Nuit : pas de préchargement des tuiles, économie de données mobiles.
    if (_estNuit()) return;
    // En satellite les tuiles sont beaucoup plus lourdes : on ne précharge
    // pas, l'affichage réel suffit (ou le téléchargement hors ligne choisi).
    if (_modeCarte == _ModeCarte.satellite) return;
    final position = widget.positionActuelle;
    final zoom = widget.mapController.camera.zoom.round();
    // Hors de la ville (petits zooms), chaque tuile couvre un immense terrain
    // inutile à précharger : on attend que l'utilisateur zoome réellement.
    if (zoom < 10) return;
    final centre = position != null
        ? LatLng(position.latitude, position.longitude)
        : widget.mapController.camera.center;
    _prefetchService.demander(
      position: centre,
      vitesse: position?.speed,
      cap: position?.heading,
      zoom: zoom,
    );
  }

  void _reconstruirePolylignes() {
    if (!mounted || !_fmtcReady) return;
    if (widget.suspendreTravailCarte) return;

    // L'itinéraire se dessine TOUJOURS comme UNE SEULE ligne continue du
    // point bleu (départ) au point vert (arrivée) : on part des points du
    // tracé calculé, jamais segments de route par segments de route —
    // chaque segment devenait une polyligne séparée et la carte montrait
    // plusieurs bouts de ligne déconnectés, ce qui perdait le suivi.

    final zoom = widget.mapController.camera.zoom;
    if (zoom < zoomMinGlobal) {
      if (_polylignesTrafic.isNotEmpty ||
          _polylignesItineraire.isNotEmpty ||
          _raccordEtape.isNotEmpty) {
        setState(() {
          _polylignesTrafic = [];
          _polylignesItineraire = [];
          _raccordEtape = [];
        });
      }
      return;
    }
    // Un seul tracé PRIORITAIRE à l'écran : quand un itinéraire est affiché,
    // il passe au-dessus de toutes les rues. Celles-ci restent toutefois
    // visibles sur la partie cadrée : l'utilisateur peut regarder/zoomer
    // ailleurs que le couloir et y voir le trafic apparaître en quelques
    // secondes.
    final pointsItineraire =
        (widget.itinerairePoints != null &&
                widget.itinerairePoints!.length >= 2)
            ? widget.itinerairePoints
            : null;
    if (pointsItineraire != null) {
      _polylignesItineraire = _decouperItineraireParEtat(pointsItineraire);
    } else {
      _polylignesItineraire = [];
    }
    _raccordEtape = _construireRaccordEtape(pointsItineraire);

    // Lignes de trafic masquées pendant un itinéraire : on garde la dernière
    // version construite en cache pour la restaurer instantanément au
    // réaffichage. L'itinéraire seul doit malgré tout déclencher un rebuild.
    if (!widget.afficherLignesTrafic) {
      if (_polylignesTrafic.isNotEmpty) {
        _polylignesTraficCache = _polylignesTrafic;
        _polylignesTrafic = [];
      }
      setState(() {});
      return;
    }

    // Réaffichage : restaurer le cache instantanément.
    if (_polylignesTrafic.isEmpty && _polylignesTraficCache.isNotEmpty) {
      final cache = _polylignesTraficCache;
      _polylignesTraficCache = [];
      setState(() => _polylignesTrafic = cache);
      return;
    }

    final vue = widget.mapController.camera.visibleBounds;
    final maintenant = DateTime.now();
    final toleranceEcran = _toleranceEcran(zoom);

    // Collecte des candidats : dédupliqués par IDENTITÉ de route (les zones
    // en cache se recouvrent, le même tronçon y figure sous des index
    // différents), puis triés par importance de classe. Le tri permet au
    // plafond de sacrifier d'abord les ruelles, jamais les grands axes.
    final candidats = <RoadSegment>[];
    final vusIds = <int>{};
    for (final zone in _segmentsCache.values) {
      if (!_boundsIntersect(zone.bounds, vue)) continue;
      final rMin = _celluleLat(vue.south).clamp(0, _grilleMaxCols);
      final rMax = _celluleLat(vue.north);
      final cMin = _celluleLon(vue.west).clamp(0, _grilleMaxCols);
      final cMax = _celluleLon(vue.east);
      for (var r = rMin; r <= rMax; r++) {
        for (var c = cMin; c <= cMax; c++) {
          final indices = zone.grille[_cleCellule(r, c)];
          if (indices == null) continue;
          for (final index in indices) {
            final segment = zone.segments[index];
            if (!vusIds.add(segment.id)) continue;
            if (!_classeVisible(segment.classe, zoom)) continue;
            if (!_boundsIntersect(zone.bornes[index], vue)) continue;
            candidats.add(segment);
          }
        }
      }
    }
    candidats.sort((a, b) {
      final pa = _prioriteClasse(a.classe);
      final pb = _prioriteClasse(b.classe);
      if (pa != pb) return pa - pb;
      return a.id.compareTo(b.id);
    });

    final polylignes = <Polyline>[];
    for (final segment in candidats) {
      // Plafond atteint : les classes secondaires déjà triées en queue de
      // liste ne sont simplement plus dessinées (plafond réduit la nuit).
      if (polylignes.length >= _plafondPolylignes) break;
      final points = segment.points;
      if (points.length < 2) continue;

      // Simplification À TOUS les zooms : la géométrie Overpass contient
      // des sommets espacés de moins d'un pixel, inutiles à peindre.
      final simpl = _simplifier(points, toleranceEcran);
      if (simpl.length < 2) continue;
      polylignes.addAll(
        _decouperParEtat(segment, simpl, zoom, maintenant),
      );
    }

    setState(() {
      _polylignesTrafic = polylignes;
    });
  }

  /// Tolérance de simplification en pixels écran selon le zoom : large aux
  /// zooms où les routes sont minuscules, fine aux zooms de rue pour rester
  /// fidèle aux virages.
  double _toleranceEcran(double zoom) {
    if (zoom < 13) return 4.0;
    if (zoom < 15) return 3.0;
    if (zoom < 17) return 1.2;
    return 0.8;
  }

  /// Rang d'importance cartographique d'une classe : 0 = autoroute,
  /// 7 = chemin de service. Les rangs faibles sont dessinés en priorité
  /// quand le plafond [_plafondPolylignes] est atteint.
  int _prioriteClasse(String classe) {
    switch (classe) {
      case 'motorway':
      case 'motorway_link':
        return 0;
      case 'trunk':
      case 'trunk_link':
        return 1;
      case 'primary':
      case 'primary_link':
        return 2;
      case 'secondary':
      case 'secondary_link':
        return 3;
      case 'tertiary':
      case 'tertiary_link':
        return 4;
      case 'unclassified':
      case 'road':
        return 5;
      case 'residential':
      case 'living_street':
        return 6;
      default:
        return 7;
    }
  }

  Marker _marqueurPoi(Poi poi) {
    final (icone, couleur) = iconePoi(poi.type);
    final afficherNom =
        widget.mapController.camera.zoom >= zoomNomPois && poi.nom.isNotEmpty;
    return Marker(
      point: poi.point,
      width: afficherNom ? 110 : 34,
      height: afficherNom ? 48 : 34,
      alignment: Alignment.topCenter,
      rotate: true,
      child: MarqueurPoi(
        icone: icone,
        couleur: couleur,
        nom: afficherNom ? poi.nom : '',
      ),
    );
  }

  /// Découpe un segment en tronçons. Les rues sont colorées selon l'état
  /// simulé (heure de la journée) ; les portions couvertes par une zone de
  /// circulation réelle (puis l'itinéraire) portent la couleur des témoins.
  ///
  /// De nuit (00h → 6h) et hors itinéraire, tout est forcé en vert uniforme :
  /// 1 tronçon par segment, aucune recherche de zone, aucun appel simulateur.
  /// [pourItineraire] laisse le tracé bleu → vert fonctionner normalement.
  List<Polyline> _decouperParEtat(
    RoadSegment segment,
    List<LatLng> points,
    double zoom,
    DateTime maintenant, {
    bool pourItineraire = false,
  }) {
    final nuit = !pourItineraire && _estNuit();
    final couleurBase = _fondSombre ? Colors.grey.shade400 : Colors.grey.shade500;
    final baseOpacite = _fondSombre ? 0.85 : 0.6;
    final epaisseur = _epaisseur(segment.classe, zoom);

    // Couleur de base du segment : l'état simulé (embouteillages des heures
    // de pointe). Sur la carte claire, les grandes artères des tuiles sont déjà
    // peintes en rouge/jaune : la ligne de trafic doit être PLEINE (opacité 1)
    // et assez épaisse pour masquer entièrement la couleur de la tuile dessous,
    // sinon on voit une ligne verte couper une route rouge (mauvais rendu).
    // De nuit, l'état est figé sur fluide : la ville dort, tout roule.
    final simEtat = nuit
        ? EtatTrafic.fluide
        : _simulateur.estimer(segment, moment: maintenant);
    final couleurBaseSim =
        _fondSombre ? Color.lerp(couleurBase, simEtat.couleur, 0.7)! : simEtat.couleur;
    final opaciteBaseSim = _fondSombre ? 0.85 : 1.0;

    ({Color couleur, double opacite}) attribut(LatLng milieu) {
      // De nuit, aucune zone de trafic ne teinte les rues : la couleur
      // verte est constante, ce qui fait un seul tronçon par segment.
      if (nuit) {
        return (couleur: couleurBaseSim, opacite: opaciteBaseSim);
      }
      final zone = _zonePourPoint(milieu);
      if (zone == null) {
        return (couleur: couleurBaseSim, opacite: opaciteBaseSim);
      }
      // Fiabilité faible → on se rapproche de la couleur simulée : un
      // signalement vieilli ou isolé ne teinte pas brutalement la route.
      final f = zone.fiabilite.clamp(0.0, 1.0);
      final couleur = _fondSombre
          ? Color.lerp(couleurBaseSim, zone.etat.couleur, f)!
          : zone.etat.couleur;
      return (couleur: couleur, opacite: _fondSombre ? (0.35 + 0.65 * f).clamp(0.0, 1.0) : 1.0);
    }

    final troncons = <({List<LatLng> pts, Color couleur, double opacite})>[];
    var courant = <LatLng>[points.first];
    var couleur = couleurBase;
    var opacite = baseOpacite;

    void fermer() {
      if (courant.length >= 2) {
        troncons.add((pts: courant, couleur: couleur, opacite: opacite));
      }
    }

    for (var i = 0; i < points.length - 1; i++) {
      final milieu = LatLng(
        (points[i].latitude + points[i + 1].latitude) / 2,
        (points[i].longitude + points[i + 1].longitude) / 2,
      );
      final a = attribut(milieu);
      if (a.couleur != couleur || a.opacite != opacite) {
        fermer();
        courant = <LatLng>[points[i]];
        couleur = a.couleur;
        opacite = a.opacite;
      }
      courant.add(points[i + 1]);
    }
    fermer();

    return [
      for (final t in troncons)
        ..._decouperPourLabel(segment, t.pts, t.couleur, epaisseur, zoom, t.opacite),
    ];
  }

  /// La ligne de l'itinéraire calculé, colorée tronçon par tronçon avec les
  /// mêmes couleurs que les rues : la sévérité calculée par le moteur local
  /// pour chaque tronçon (classe de rue + zones signalées), ou à défaut
  /// l'état simulé générique du tracé entier puis les zones couvertes.
  /// Itinéraire : UNE seule ligne, épaisseur constante, dont la couleur
  /// suit l'état des routes tronçon par tronçon. Les transitions de couleur
  /// sont jointes par des caps ronds pour rester un tracé unique et continu.
  /// La couleur ne couvre QUE la portion sur chaussée : un départ ou une
  /// arrivée hors route (bâtiment, parcelle) est raccordé par des pointillés
  /// noirs, jamais par la couleur elle-même.
  List<Polyline> _decouperItineraireParEtat(List<LatLng> points) {
    return decouperItineraireParEtat(
      points: points,
      debutRoute: widget.itineraireDebutRoute,
      finRoute: widget.itineraireFinRoute,
      debutVisuel: widget.itineraireDebutVisuel,
      fondSombre: _fondSombre,
      severites: widget.itineraireSeverites,
      simulateur: _simulateur,
      zonePourPoint: _zonePourPoint,
    );
  }

  List<Polyline> _decouperPourLabel(
    RoadSegment segment,
    List<LatLng> points,
    Color couleur,
    double largeur,
    double zoom,
    double opacite,
  ) {
    Polyline ligne(List<LatLng> pts) => Polyline(
          points: pts,
          strokeWidth: largeur,
          color: couleur.withValues(alpha: opacite.clamp(0.0, 1.0)),
          borderColor: Colors.black.withValues(alpha: 0.35),
          // La bordure fait peindre chaque tronçon DEUX fois : en vue ville
          // (zoom < 12) les lignes sont si fines qu'elle est invisible —
          // on la supprime pour diviser le coût de rendu par deux.
          borderStrokeWidth: zoom < 12 ? 0 : 1,
        );

    if (zoom < 12 || segment.nom.isEmpty || points.length < 2) {
      return [ligne(points)];
    }

    final camera = widget.mapController.camera;
    final ecrans = <Point<double>>[
      for (final p in points) camera.latLngToScreenPoint(p),
    ];
    final longueurTotale = _longueurEcran(ecrans);
    if (longueurTotale <= _rayonLabel * 3) {
      return [ligne(points)];
    }

    final centre = _pointEcranALongueur(ecrans, longueurTotale / 2);
    final parts = <List<LatLng>>[];
    var courant = <LatLng>[];
    for (var i = 0; i < points.length; i++) {
      if (centre.distanceTo(ecrans[i]) <= _rayonLabel) {
        if (courant.isNotEmpty) {
          parts.add(courant);
          courant = <LatLng>[];
        }
      } else {
        courant.add(points[i]);
      }
    }
    if (courant.isNotEmpty) parts.add(courant);

    if (parts.length <= 1) {
      return [ligne(points)];
    }

    return [
      for (final part in parts)
        if (part.length >= 2) ligne(part),
    ];
  }

  double _longueurEcran(List<Point<double>> pts) {
    var total = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      total += pts[i].distanceTo(pts[i + 1]);
    }
    return total;
  }

  Point<double> _pointEcranALongueur(List<Point<double>> pts, double cible) {
    var cumul = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final d = pts[i].distanceTo(pts[i + 1]);
      if (cumul + d >= cible) {
        final t = d > 0 ? (cible - cumul) / d : 0.0;
        return Point(
          pts[i].x + (pts[i + 1].x - pts[i].x) * t,
          pts[i].y + (pts[i + 1].y - pts[i].y) * t,
        );
      }
      cumul += d;
    }
    return pts.last;
  }

  bool _classeVisible(String classe, double zoom) =>
      zoom >= (_zoomMinParClasse[classe] ?? 15.0);

  List<LatLng> _simplifier(List<LatLng> points, double minEcartEcran) {
    final camera = widget.mapController.camera;
    final simplifie = <LatLng>[points.first];
    var dernier = camera.latLngToScreenPoint(points.first);
    for (var i = 1; i < points.length - 1; i++) {
      final p = points[i];
      final ecran = camera.latLngToScreenPoint(p);
      if (dernier.distanceTo(ecran) >= minEcartEcran) {
        simplifie.add(p);
        dernier = ecran;
      }
    }
    final dernierPoint = points.last;
    if (camera.latLngToScreenPoint(dernierPoint).distanceTo(dernier) >=
        minEcartEcran) {
      simplifie.add(dernierPoint);
    }
    return simplifie;
  }

  /// Épaisseur d'un trait selon sa classe, élargie modérément avec le zoom.
  /// La ligne doit couvrir la chaussée de l'artère (pour masquer sa couleur
  /// sur les tuiles) sans pour autant avaler les noms de rues qui y sont
  /// affichés : on reste donc assez fin, l'opacité pleine faisant le reste.
  double _epaisseur(String classe, double zoom) {
    // 1 au zoom de référence (13), puis croît doucement : à 15 → ~1.7×,
    // 17 → 2.4×, 19 → 3.1×. Même échelle sur toutes les cartes.
    final f = (1 + (zoom - 13) * 0.35).clamp(0.9, 5.0);
    final base = switch (classe) {
      'motorway' ||
      'motorway_link' ||
      'trunk' ||
      'trunk_link' => 3.5,
      'primary' ||
      'primary_link' ||
      'secondary' ||
      'secondary_link' => 3.0,
      'tertiary' || 'tertiary_link' || 'unclassified' || 'road' => 2.2,
      _ => 1.8,
    };
    return base * f;
  }

  bool _boundsIntersect(LatLngBounds a, LatLngBounds b) {
    return !(a.east < b.west ||
        a.west > b.east ||
        a.north < b.south ||
        a.south > b.north);
  }

  /// URL du fond de carte selon le mode actif : sert aussi au prétéléchargement
  /// des tuiles du couloir d'itinéraire (même source que la carte affichée).
  String get _urlDuMode => switch (_modeCarte) {
    _ModeCarte.sombre => _urlTuilesSombre,
    _ModeCarte.satellite => _urlTuilesSatellite,
    _ModeCarte.claire => _urlTuiles,
    _ModeCarte.positron => _urlTuilesPositron,
    _ModeCarte.darkMatter => _urlTuilesDarkMatter,
    _ModeCarte.voyager => _urlTuilesVoyager,
    _ModeCarte.topo => _urlTuilesTopo,
  };

  Widget _tuileDeBase(_ModeCarte mode) {
    final url = _urlDuMode;
    return TileLayer(
      urlTemplate: url,
      userAgentPackageName: 'com.kinflow.kinflow',
      tileProvider:
          _tileProvider ?? NetworkTileProvider(silenceExceptions: true),
      errorTileCallback: (tile, error, stackTrace) {
        // Les échecs de téléchargement de tuiles (réseau instable, serveur
        // indisponible) sont déjà rendus par tileBuilder via tile.loadError :
        // on les absorbe ici pour éviter qu'ils remontent en erreur Flutter
        // non gérée (plantage) pendant les déplacements de carte.
        debugPrint('[KinFlow] Tuile indisponible: $error');
      },
      tileBuilder: (context, widgetTile, tile) {
        if (chargementCarte) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => chargementCarte = false);
            }
          });
        }

        final enChargement = !tile.readyToDisplay && !tile.loadError;
        if (enChargement) {
          _dernierChargement = DateTime.now();
          if (!_chargementTuilesActif) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() => _chargementTuilesActif = true);
              }
            });
          }
          _timerFinChargement ??= Timer.periodic(
            const Duration(milliseconds: 300),
            (_) => _verifierFinChargement(),
          );
        }

        if (tile.loadError) {
          return Container(
            color: Colors.grey.shade400,
            alignment: Alignment.center,
            child: Icon(
              Icons.cloud_off,
              color: Colors.grey.shade600,
              size: 14,
            ),
          );
        }
        if (!tile.readyToDisplay) {
          return Container(
            color: Colors.grey.shade300,
            alignment: Alignment.center,
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Colors.grey.shade600,
              ),
            ),
          );
        }
        // En mode sombre, on désature les tuiles OSM et on les assombrit
        // pour obtenir un fond gris foncé / noir.
        if (_modeCarte == _ModeCarte.sombre) {
          return ColorFiltered(
            colorFilter: const ColorFilter.matrix([
              0.2126, 0.7152, 0.0722, 0, 0,
              0.2126, 0.7152, 0.0722, 0, 0,
              0.2126, 0.7152, 0.0722, 0, 0,
              0,      0,      0,      1, 0,
            ]),
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix([
                0.6, 0, 0, 0, 0,
                0, 0.6, 0, 0, 0,
                0, 0,   0.6, 0, 0,
                0, 0,   0,   1, 0,
              ]),
              child: widgetTile,
            ),
          );
        }
        return widgetTile;
      },
    );
  }

  void _verifierFinChargement() {
    if (!mounted) return;
    final dernier = _dernierChargement;
    if (dernier != null &&
        DateTime.now().difference(dernier) >
            const Duration(milliseconds: 1500)) {
      _timerFinChargement?.cancel();
      _timerFinChargement = null;
      if (_chargementTuilesActif) {
        setState(() => _chargementTuilesActif = false);
      }
    }
  }

  /// Épingle classique « goutte » en relief : corps coloré aux reflets 3D,
  /// aiguille grise au centre, pointe en bas. Dessinée en CustomPaint.
  Widget _construireEpingle(Color couleur) {
    return CustomPaint(
      size: const Size(50, 50),
      painter: PeintreEpingle(couleur),
    );
  }

  /// Icône de localisation standard (« goutte d'eau ») : le symbole habituel
  /// de position sur les téléphones. Utilisée pour la position de l'utilisateur
  /// et le lieu recherché.
  Widget _construireGoutte(Color couleur) {
    return Icon(
      Icons.location_on,
      size: 46,
      color: couleur,
    );
  }

  /// Étape « Ajouter à l'itinéraire » : un pin ambre numéroté, clairement
  /// différent du point vert de la destination et de l'épingle rouge.
  Widget _construireEtape() {
    return CustomPaint(
      size: const Size(50, 50),
      painter: PeintreEtape(KinColors.accent, '1'),
    );
  }

  /// Cône de vision au-delà duquel une étape posée hors chaussée est reliée
  /// à l'itinéraire par des pointillés noirs (bâtiment, parcelle). Tant
  /// qu'un tracé passe sous le marqueur — l'itinéraire lui-même ou une rue
  /// du réseau chargé — aucun raccord n'est dessiné.
  static const double _seuilRaccordEtapeMetres = 25;

  /// Raccords en pointillés noirs entre l'étape et l'itinéraire déjà tracé.
  /// Vide si l'étape repose sur la chaussée (l'itinéraire passe alors
  /// dessus) ou s'il n'y a pas encore de tracé à proximité.
  List<Polyline> _construireRaccordEtape(List<LatLng>? pointsItineraire) {
    final etape = widget.pointEtape;
    if (etape == null) return const [];

    // Pas de pointillés quand un tracé passe sous le marqueur. L'étape
    // ajoutée révise l'itinéraire, dont la polyline est recalée au plus près
    // du point projeté sur la chaussée ; et même sans tracé itinéraire à
    // proximité, une rue du réseau déjà chargé sous le marqueur suffit à
    // considérer l'étape « sur route ».
    if (pointsItineraire != null) {
      final proche = _projeterSurPolyligne(etape, pointsItineraire);
      if (distanceMetresHaversine(etape, proche) < _seuilRaccordEtapeMetres) {
        return const [];
      }
    }
    if (_estSurReseauRoutier(etape, _seuilRaccordEtapeMetres)) {
      return const [];
    }
    if (pointsItineraire == null) return const [];

    final proche = _projeterSurPolyligne(etape, pointsItineraire);
    return [
      Polyline(
        points: [etape, proche],
        strokeWidth: 3.2,
        color: Colors.black.withValues(alpha: _fondSombre ? 0.95 : 0.8),
        pattern: StrokePattern.dotted(),
        strokeCap: StrokeCap.round,
      ),
    ];
  }

  /// Vrai si [etape] repose sur une route du réseau déjà chargé
  /// ([_segmentsCache]) : dans ce cas l'itinéraire, recalé dessus, passe
  /// sous le marqueur et le raccord en pointillés n'a plus lieu d'être.
  bool _estSurReseauRoutier(LatLng etape, double rayonMetres) {
    final fenetre = _etendrePoint(etape, rayonMetres);
    for (final zone in _segmentsCache.values) {
      if (!_boundsSeChevauchent(zone.bounds, fenetre)) continue;
      for (var i = 0; i < zone.segments.length; i++) {
        if (!_boundsSeChevauchent(zone.bornes[i], fenetre)) continue;
        final proche = _projeterSurPolyligne(etape, zone.segments[i].points);
        if (distanceMetresHaversine(etape, proche) < rayonMetres) return true;
      }
    }
    return false;
  }

  /// Fenêtre de quelques dizaines de mètres autour de [p], pour filtrer les
  /// zones et segments trop éloignés avant la projection précise.
  LatLngBounds _etendrePoint(LatLng p, double rayonMetres) {
    final dLat = rayonMetres / 111320.0;
    final dLon = dLat / max(cos(p.latitude * pi / 180), 0.15);
    return LatLngBounds(
      LatLng(p.latitude - dLat, p.longitude - dLon),
      LatLng(p.latitude + dLat, p.longitude + dLon),
    );
  }

  bool _boundsSeChevauchent(LatLngBounds a, LatLngBounds b) =>
      a.north >= b.south &&
      a.south <= b.north &&
      a.east >= b.west &&
      a.west <= b.east;

  /// Point de la polyligne [pts] le plus proche de [p] (projection orthogonale
  /// bornée sur chaque arête, puis choix du minimum).
  LatLng _projeterSurPolyligne(LatLng p, List<LatLng> pts) {
    LatLng? meilleur;
    var minD = double.infinity;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final dx = b.longitude - a.longitude;
      final dy = b.latitude - a.latitude;
      final len2 = dx * dx + dy * dy;
      if (len2 <= 0) continue;
      final t = (((p.longitude - a.longitude) * dx +
                  (p.latitude - a.latitude) * dy) /
              len2)
          .clamp(0.0, 1.0);
      final proj = LatLng(
        a.latitude + t * dy,
        a.longitude + t * dx,
      );
      final d = distanceMetresHaversine(proj, p);
      if (d < minD) {
        minD = d;
        meilleur = proj;
      }
    }
    return meilleur ?? p;
  }

  @override
  Widget build(BuildContext context) {

    double? decalageBoutons;
    double? largeurBoutons;
    double? hauteurBoutons;

    if (widget.afficherActions && widget.pointActions != null) {

      final textScaler = MediaQuery.textScalerOf(context);

      final styleBase =
          DefaultTextStyle.of(context).style.copyWith(
                fontSize: BoutonAction.tailleTexte,
                fontWeight: FontWeight.w600,
              );

      final largeur2 =
          BoutonAction.largeurPour(
            'Supprimer',
            styleBase,
            textScaler,
          );

      final largeurDetails =
          BoutonAction.largeurPour(
            'Détails',
            styleBase,
            textScaler,
          );

      if (widget.seulementSupprimer) {

        decalageBoutons = 0;

        // « Détails » + « Supprimer » pour le point bleu de position,
        // uniquement « Supprimer » pour les pins verts (destination,
        // étape, lieu recherché).
        largeurBoutons =
            (widget.onVoirDetails != null ? largeurDetails + 8 : 0) +
            largeur2;

      } else {

        final largeur1 =
            BoutonAction.largeurPour(
              widget.libelleActionPrincipale,
              styleBase,
              textScaler,
            );

        decalageBoutons = (largeur2 - largeur1) / 2;

        largeurBoutons = largeur1 + 8 + largeur2;
      }

      hauteurBoutons =
          BoutonAction.hauteurPour(styleBase, textScaler);

    }

    return Stack(

      children: [

        if (!_fmtcReady)
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text(
                  'Initialisation de la carte...',
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ),
          )
        else
        Listener(
            onPointerDown: (e) {
              _pointersDown++;
              _departsPointeurs[e.pointer] = e.localPosition;
              if (_pointersDown > 1) {
                _annulerSansTap();
                return;
              }
              // Un nouvel appui invalide tout « clic simple » encore en
              // attente du tap précédent : sinon son futur `onMapTap`
              // se déclencherait pendant qu'on appuie sur un bouton et
              // fermerait/réouvrirait les actions aussitôt. Si c'est un
              // double-clic (un clic simple est en attente), on le marque
              // pour que le zoom ne fasse pas aussi apparaître les infos.
              if (_singleTapTimer != null) {
                _doubleTapEnCours = true;
                _singleTapTimer?.cancel();
                _singleTapTimer = null;
              }
              if (_appuiBoutonAction) {
                _doubleTapEnCours = false;
                return;
              }
              widget.onUserInteract?.call();
              _interactionSurBoutons();
              if (_fmtcReady && !_longPressActif) {
                _demarrerLongPress(e.localPosition);
              }
            },
          onPointerMove: (e) {
            final depart = _departsPointeurs[e.pointer];
            if (depart == null) return;
            if ((e.localPosition - depart).distance <= 18) return;
            _pointeurBouge = true;
            _longPressTimer?.cancel();
            _longPressTimer = null;
            _zoomOutTimer?.cancel();
            _zoomOutTimer = null;
            _longPressActif = false;
            // Un glissement à UN doigt reprend la main sur la caméra : le
            // mode navigation est coupé, la carte garde son orientation
            // courante. Un pincement (2 doigts déjà posés) est un zoom :
            // il ne doit PAS couper le suivi, qui adopte le nouveau zoom
            // dans [_surEvenementCarte].
            if (widget.modeNavigation && _pointersDown <= 1) {
              widget.onNavigationInterrompue?.call();
            }
          },
          onPointerUp: (e) {
            if (_pointersDown > 0) _pointersDown--;
            _departsPointeurs.remove(e.pointer);
            _annulerLongPress();
          },
          onPointerCancel: (e) {
            if (_pointersDown > 0) _pointersDown--;
            _departsPointeurs.remove(e.pointer);
            _annulerSansTap();
          },
          child: FlutterMap(

          mapController: widget.mapController,


          options: MapOptions(

            initialCenter: const LatLng(

              -4.325,

              15.322,

            ),

            initialZoom: 13,

            onMapEvent: _surEvenementCarte,

            interactionOptions: const InteractionOptions(

              scrollWheelVelocity: 0.015,

              pinchZoomThreshold: 0.15,

            ),

          ),



          children: [

            _tuileDeBase(_modeCarte),



            if (widget.afficherLignesTrafic ||
                widget.itinerairePoints != null)
              PolylineLayer(polylines: [
                ..._polylignesTrafic,
                // La ligne de l'itinéraire calculé reste toujours visible,
                // même si le cache des rues du couloir n'est pas encore prêt.
                ..._polylignesItineraire,
                // Raccord en pointillés noirs d'une étape hors réseau routier.
                ..._raccordEtape,
              ]),



            MarkerLayer(

              markers: [


                for (final poi in _poisVisibles()) _marqueurPoi(poi),



                // Ordre de peinture = ordre d'empilement : ce marqueur est
                // AVANT tous les marqueurs de destination (vert, épingle),
                // il passe donc toujours EN DESSOUS d'eux quand ils se
                // recouvrent, jamais au-dessus.
                if (widget.positionActuelle != null)

                  Marker(

                    point: _positionAnimation != null
                        ? _positionAnimation!.value
                        : (_displayedPosition ??
                            LatLng(
                              widget.positionActuelle!.latitude,
                              widget.positionActuelle!.longitude,
                            )),

                    width: 50,

                    height: 50,

                    // Contre-rotation : le marqueur reste visuellement
                    // droit pendant la rotation de la carte, sans gêner
                    // son déplacement qui suit la position GPS.
                    rotate: true,

                    child: _construireGoutte(Colors.blueAccent),

                  ),



                if (widget.lieuRecherche != null)


                  Marker(

                    point: widget.lieuRecherche!,

                    width: 50,

                    height: 50,


                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: _construireGoutte(const Color(0xFF00B050)),

                  ),


                // Destination de l'itinéraire : son pin vert reste en place
                // même quand un autre lieu est ensuite recherché.
                if (widget.pointDestination != null)

                  Marker(

                    point: widget.pointDestination!,

                    width: 50,

                    height: 50,

                    rotate: true,

                    child: _construireGoutte(const Color(0xFF00B050)),

                  ),

                // Étape obligatoire de l'itinéraire (une seule).
                // Affiche un pin ambre numéroté (checkpoint), distinct du
                // point vert de la destination, avant celle-ci.
                if (widget.pointEtape != null)

                  Marker(

                    point: widget.pointEtape!,

                    width: 50,

                    height: 50,

                    rotate: true,

                    child: _construireEtape(),

                  ),



                if (widget.epingle != null)


                  Marker(

                    point: widget.epingle!,


                    width: 40,

                    height: 40,


                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: _construireEpingle(Colors.red),

                  ),

                // Le point vert de destination reste toujours visible,
                // y compris pendant un itinéraire actif. Sauf quand les
                // actions sont attachées à l'épingle rouge : l'épingle
                // reste un repère rouge, on ne la recouvre jamais de vert.
                if (widget.pointActions != null &&
                    !widget.seulementSupprimer &&
                    !widget.actionsSurEpingle &&
                    widget.pointActions != widget.epingle &&
                    widget.pointActions != widget.lieuRecherche)

                  Marker(

                    point: widget.pointActions!,

                    width: 50,

                    height: 50,

                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: _construireEpingle(Colors.red),

                  ),

                if (widget.afficherActions &&
                    widget.pointActions != null &&
                    !_modePoserEpingle)

                  Marker(

                    point: widget.pointActions!,

                    width: largeurBoutons!,

                    height: hauteurBoutons! + 40,

                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: Transform.translate(

                      offset: Offset(decalageBoutons!, 40),

                      child: BoutonsActions(

                        onDefinirItineraire:
                            widget.desactiverItineraire
                                ? null
                                : widget.onDefinirItineraire,

                        libelleDefinirItineraire:
                            widget.libelleActionPrincipale,

                        onSupprimer: widget.onSupprimer,

                        onVoirDetails: widget.onVoirDetails,

                        afficherDefinirItineraire:
                            !widget.seulementSupprimer,

                        onInteractionStart: () {
                          _appuiBoutonAction = true;
                        },

                        onInteractionEnd: () {
                          _appuiBoutonAction = false;
                        },

                      ),

                    ),

                  ),



              ],
            ),


          ],
        ),
        ),



        if (_modePoserEpingle && _fmtcReady)
          Positioned.fill(
            child: Stack(
              children: [
                // Épingle de prévisualisation au centre : elle ne capte
                // aucun toucher, la carte reste libre à déplacer dessous.
                Center(
                  child: IgnorePointer(
                    child: _construireEpingle(Colors.red),
                  ),
                ),
                // Bouton « Poser » juste en dessous de l'épingle.
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 84),
                      BoutonPoser(onPressed: _poserEpingle),
                    ],
                  ),
                ),
              ],
            ),
          ),

        if (_fmtcReady)
          Positioned(
            left: 8,
            bottom: 16,
            child: AnimatedOpacity(
              opacity: _boutonsVisibles
                  ? 1.0
                  : _opaciteBoutonsInactifs,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              child: BoutonPoserEpingle(
                actif: _modePoserEpingle,
                onPressed: _basculerModePoserEpingle,
              ),
            ),
          ),

        if (_fmtcReady)
          Positioned(
            right: 8,
            bottom: 16,
            child: AnimatedOpacity(
              opacity: _boutonsVisibles
                  ? 1.0
                  : _opaciteBoutonsInactifs,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              child: BoutonModeCarte(
                onPressed: _ouvrirMenuCartes,
              ),
            ),
          ),

        if (_fmtcReady && _modeCarte == _ModeCarte.satellite)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Imagerie © Esri, Maxar, Earthstar Geographics',
                style: TextStyle(fontSize: 9, color: Colors.black87),
              ),
            ),
          ),

        if (_fmtcReady &&
            (_modeCarte == _ModeCarte.positron ||
                _modeCarte == _ModeCarte.darkMatter))
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '© CARTO, © OpenStreetMap',
                style: TextStyle(fontSize: 9, color: Colors.black87),
              ),
            ),
          ),

        if (_fmtcReady && _modeCarte == _ModeCarte.voyager)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '© CARTO, © OpenStreetMap',
                style: TextStyle(fontSize: 9, color: Colors.black87),
              ),
            ),
          ),

        if (_fmtcReady && _modeCarte == _ModeCarte.topo)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '© OpenTopoMap (CC-BY-SA)',
                style: TextStyle(fontSize: 9, color: Colors.black87),
              ),
            ),
          ),

        if (_chargementTuilesActif)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Chargement des tuiles...',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),


        if (chargementCarte && _fmtcReady)


          const Center(

            child: CircularProgressIndicator(),

          ),


        if (_downloadProgress > 0 && _downloadProgress < 100)
          Positioned(
            bottom: 8,
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: _downloadProgress / 100,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _lastStatus,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),


      ],


    );


  }

}
