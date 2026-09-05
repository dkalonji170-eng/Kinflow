import 'dart:async';
import 'dart:convert';
import 'dart:math' show Point, exp, max, min;
import 'package:flutter/foundation.dart' show compute, debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import '../main.dart'
    show tileDownloadService, waitForFmtc, initFmtc, fmtcSucceeded;
import '../models/road_segment.dart';
import '../models/traffic_state.dart';
import '../theme/kinflow_theme.dart';
import '../services/road_service.dart';
import '../services/diagnostics_service.dart';
import '../services/data_usage_service.dart';
import '../services/tile_prefetch_service.dart';
import '../services/traffic_simulator.dart';
import '../services/traffic_stats_service.dart';
import '../services/supabase_service.dart';
import '../services/orientation_navigation.dart';


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

class _Poi {
  final LatLng point;
  final String nom;
  final String type;
  const _Poi(this.point, this.nom, this.type);
}

const double _zoomMinGlobal = 8.0;
const double _rayonLabel = 40.0;
const double _zoomMinPois = 14.0;
const double _zoomNomPois = 16.5;
const int _maxPois = 500;
const int _maxPoisParType = 30;
const int _maxPoisVisiblesParType = 10;

/// Plafond de tronçons dessinés simultanément : au-delà, les classes de rue
/// les moins importantes sont abandonnées. Sans ce garde-fou, une vue dense
/// de Kinshasa au zoom ≥ 15 produit des dizaines de milliers de polylignes
/// repeintes à CHAQUE frame — c'est ce qui rendait la carte inexploitable.
const int _maxPolylignes = 1600;

/// Mode navigation : raideur du lissage exponentiel caméra (par seconde).
const double _navFacteurLissage = 5.0;

/// Mode navigation : raideur du lissage exponentiel de la ROTATION (par
/// seconde). Volontairement doux : la carte doit pivoter en glissant, même
/// quand le cap GPS varie vite ou bruite (le seuil bas de 10° déclenche des
/// recadrages fréquents, un raideur élevée les rendrait secoués).
const double _navFacteurLissageRotation = 1.5;

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

final LatLngBounds _limitesAfrique = LatLngBounds(
  const LatLng(-35.0, -18.0),
  const LatLng(37.5, 52.0),
);

/// Styles de fond de carte, choisis indépendamment du thème clair/sombre
/// de l'application.
enum _ModeCarte {
  claire,
  sombre,
  satellite;
}

const String _urlTuiles =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

// La carte sombre utilise les mêmes tuiles OSM que la carte claire, mais
// avec une désaturation + assombrissement appliqués en temps réel.
const String _urlTuilesSombre = _urlTuiles;

const String _urlTuilesSatellite =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

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

List<_Poi> _parserPois(dynamic json) {
  final resultats = <_Poi>[];
  final elements =
      (json as Map<String, dynamic>)['elements'] as List? ?? const [];

  for (final e in elements) {
    final tags = (e['tags'] as Map<String, dynamic>?) ?? const {};

    double? lat = (e['lat'] as num?)?.toDouble();
    double? lon = (e['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      final centre = (e['center'] as Map?) ?? const {};
      lat = (centre['lat'] as num?)?.toDouble();
      lon = (centre['lon'] as num?)?.toDouble();
    }
    if (lat == null || lon == null) continue;

    final type = (tags['amenity'] ??
            tags['shop'] ??
            tags['tourism'] ??
            tags['leisure'] ??
            tags['office']
        ).toString();
    if (type.isEmpty) continue;

    final nom = (tags['name'] ?? '').toString();

    resultats.add(_Poi(LatLng(lat, lon), nom, type));
  }

  final parType = <String, List<_Poi>>{};
  for (final poi in resultats) {
    final liste = parType.putIfAbsent(poi.type, () => []);
    if (liste.length < _maxPoisParType) liste.add(poi);
  }

  final limites = <_Poi>[
    for (final liste in parType.values) ...liste,
  ];

  limites.sort((a, b) {
    final aNom = a.nom.isEmpty ? 1 : 0;
    final bNom = b.nom.isEmpty ? 1 : 0;
    if (aNom != bNom) return aNom - bNom;
    return _prioritePoi(a.type).compareTo(_prioritePoi(b.type));
  });

  return limites.take(_maxPois).toList();
}

(IconData, Color) _iconePoi(String type) {
  switch (type) {
    case 'restaurant':
    case 'cafe':
    case 'bar':
    case 'pub':
      return (Icons.restaurant, const Color(0xFFE65100));
    case 'school':
    case 'college':
    case 'university':
      return (Icons.school, const Color(0xFF6A1B9A));
    case 'hospital':
    case 'clinic':
      return (Icons.local_hospital, const Color(0xFFC62828));
    case 'pharmacy':
      return (Icons.local_pharmacy, const Color(0xFFE53935));
    case 'bank':
      return (Icons.account_balance, const Color(0xFF00695C));
    case 'marketplace':
    case 'market':
      return (Icons.storefront, const Color(0xFFEF6C00));
    case 'place_of_worship':
    case 'church':
    case 'mosque':
      return (Icons.church, const Color(0xFF6D4C41));
    case 'fuel':
      return (Icons.local_gas_station, const Color(0xFF37474F));
    case 'police':
      return (Icons.local_police, const Color(0xFF283593));
    case 'fire_station':
      return (Icons.local_fire_department, const Color(0xFFD32F2F));
    case 'post_office':
      return (Icons.local_post_office, const Color(0xFF1565C0));
    case 'library':
      return (Icons.local_library, const Color(0xFFF57F17));
    case 'cinema':
      return (Icons.movie, const Color(0xFF7B1FA2));
    case 'theatre':
      return (Icons.theater_comedy, const Color(0xFF8E24AA));
    case 'parking':
      return (Icons.local_parking, const Color(0xFF1565C0));
    case 'taxi':
      return (Icons.local_taxi, const Color(0xFFF9A825));
    case 'supermarket':
      return (Icons.shopping_cart, const Color(0xFF2E7D32));
    case 'mall':
      return (Icons.local_mall, const Color(0xFF388E3C));
    case 'convenience':
    case 'general':
    case 'bakery':
    case 'butcher':
      return (Icons.store, const Color(0xFF00897B));
    case 'hotel':
    case 'guest_house':
      return (Icons.hotel, const Color(0xFF1E88E5));
    case 'museum':
      return (Icons.museum, const Color(0xFF5D4037));
    case 'attraction':
      return (Icons.attractions, const Color(0xFFD81B60));
    case 'viewpoint':
      return (Icons.photo_camera, const Color(0xFF43A047));
    case 'park':
      return (Icons.park, const Color(0xFF2E7D32));
    case 'stadium':
    case 'sports_centre':
      return (Icons.stadium, const Color(0xFFEF6C00));
    case 'government':
    case 'embassy':
      return (Icons.account_balance, const Color(0xFF455A64));
    default:
      return (Icons.place, const Color(0xFF757575));
  }
}

int _prioritePoi(String type) {
  switch (type) {
    case 'hospital':
    case 'clinic':
      return 0;
    case 'school':
    case 'college':
    case 'university':
      return 1;
    case 'marketplace':
    case 'market':
      return 2;
    case 'fuel':
      return 3;
    case 'police':
      return 4;
    case 'fire_station':
      return 5;
    case 'place_of_worship':
    case 'church':
    case 'mosque':
      return 6;
    case 'bank':
      return 7;
    case 'pharmacy':
      return 8;
    case 'post_office':
      return 9;
    case 'library':
      return 10;
    case 'parking':
      return 11;
    case 'park':
      return 12;
    case 'hotel':
    case 'guest_house':
      return 13;
    case 'supermarket':
    case 'mall':
      return 14;
    case 'museum':
      return 15;
    case 'cinema':
    case 'theatre':
      return 16;
    case 'stadium':
    case 'sports_centre':
      return 17;
    case 'taxi':
      return 18;
    case 'government':
    case 'embassy':
      return 19;
    case 'restaurant':
      return 20;
    case 'cafe':
      return 21;
    case 'bar':
    case 'pub':
      return 22;
    case 'convenience':
    case 'general':
    case 'bakery':
    case 'butcher':
      return 23;
    case 'attraction':
    case 'viewpoint':
      return 24;
    default:
      return 25;
  }
}

class LatLngTween extends Tween<LatLng> {
  LatLngTween({super.begin, super.end});

  @override
  LatLng lerp(double t) {
    final b = begin!;
    final e = end!;
    return LatLng(
      b.latitude + (e.latitude - b.latitude) * t,
      b.longitude + (e.longitude - b.longitude) * t,
    );
  }
}

class TrafficMap extends StatefulWidget {

  final MapController mapController;

  final Position? positionActuelle;

  final LatLng? lieuRecherche;

  final bool afficherLignesTrafic;

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

    required this.onMapReady,

    this.onMapTap,

    this.afficherActions = false,

    this.seulementSupprimer = false,

    this.onDefinirItineraire,

    this.onSupprimer,

    this.onVoirDetails,

    this.onUserInteract,

    this.epingle,

    this.pointActions,

    this.actionsSurEpingle = false,

    this.versionZonesTrafic = 0,

    this.onZonesTrafic,

    this.itinerairePoints,

    this.itineraireSeverites,

    this.itineraireDebutRoute = 0,

    this.itineraireDebutVisuel = -1,

    this.itineraireFinRoute = -1,

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
  FMTCTileProvider? _tileProvider;
  Timer? _timerConsoTuiles;
  int _tailleCachePrecedenteKiBToOctets = 0;

  /// Vrai quand le fond est sombre (carte sombre ou satellite) : sert aux
  /// réglages de contraste (contours, drapeaux) indépendants du thème.
  bool get _fondSombre => _modeCarte != _ModeCarte.claire;

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
  final Map<String, _SegmentsParZone> _segmentsCache = {};
  Timer? _debounceRoutes;
  Timer? _debounceRoutesPrefetch;
  Timer? _rafraichissementSimulation;
  Timer? _rafraichissementRoutes;
  Timer? _rafraichissementPrefetch;
  Timer? _rafraichissementStats;

  List<ZoneTrafic> _zonesTrafic = [];

  List<_Poi> _pois = [];
  final Map<String, List<_Poi>> _poiCache = {};
  Timer? _debouncePois;
  int _signatureZoom = -1;

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
  }

  @override
  void didUpdateWidget(TrafficMap oldWidget) {
    super.didUpdateWidget(oldWidget);

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
        }
      });
    } else if (widget.itineraireDebutVisuel !=
        oldWidget.itineraireDebutVisuel) {
      // Le suivi réél a avancé : la portion parcourue derrière l'utilisateur
      // doit disparaître du rendu. On rebâtit juste les polylignes.
      _reconstruirePolylignes();
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

    final newPos = widget.positionActuelle;
    if (newPos != null) {
      final newLatLng = LatLng(newPos.latitude, newPos.longitude);
      final oldPos = _displayedPosition;

      if (oldPos == null) {
        _displayedPosition = newLatLng;
      } else {
        _positionAnimController?.stop();
        _positionAnimController?.dispose();
        _positionAnimController = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 300),
        );
        _positionAnimation = LatLngTween(
          begin: oldPos,
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
          widget.onMapTap?.call(point);
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
    _annulerLongPress();
    _statusSub?.cancel();
    _progressSub?.cancel();
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

  void _ouvrirMenuCartes() {
    if (!_fmtcReady || !mounted) return;
    final sombre = _modeCarte == _ModeCarte.sombre;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor:
          sombre ? KinColors.surfaceSombre : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            _OptionModeCarte(
              icone: Icons.light_mode,
              libelle: 'Claire',
              selectionne: _modeCarte == _ModeCarte.claire,
              sombre: sombre,
              onTap: () => _choisirMode(_ModeCarte.claire),
            ),
            _OptionModeCarte(
              icone: Icons.dark_mode,
              libelle: 'Sombre',
              selectionne: _modeCarte == _ModeCarte.sombre,
              sombre: sombre,
              onTap: () => _choisirMode(_ModeCarte.sombre),
            ),
            _OptionModeCarte(
              icone: Icons.satellite_alt,
              libelle: 'Satellite',
              selectionne: _modeCarte == _ModeCarte.satellite,
              sombre: sombre,
              onTap: () => _choisirMode(_ModeCarte.satellite),
            ),
            const SizedBox(height: 8),
          ],
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
      bounds: _limitesAfrique,
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
    final delta = _deltaRotation(_animDebutRotation, _animCibleRotation);
    final rotation = _normaliserDegre(_animDebutRotation + delta * k);
    widget.mapController.move(centre, zoom);
    widget.mapController.rotate(rotation);
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
    // Nouvelle session de suivi : référentiel d'orientation remis à zéro.
    // Le premier cap valide réalignera la carte immédiatement.
    _orientationNav.reinitialiser();
    _navTicker ??= createTicker(_surTickNavigation);
    if (!_navTicker!.isActive) _navTicker!.start();
  }

  void _arreterSuiviNavigation() {
    _navTicker?.stop();
    _navDernierTick = null;
    _navCentreCourant = null;
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
      final delta = _deltaRotation(rotation, cibleRot);
      if (delta.abs() > 0.3) {
        rotation = _normaliserDegre(rotation + delta * kRot);
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
      _debouncePois = Timer(const Duration(milliseconds: 250), () {
        if (mounted) unawaited(_chargerPois());
      });
      // Pendant le déplacement, on lance un prefetch des routes de la
      // zone vers laquelle on se dirige : les données arrivent avant
      // l'arrêt du geste et le cache est prêt au moment du rebuild.
      _debounceRoutesPrefetch?.cancel();
      _debounceRoutesPrefetch = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) unawaited(_prefetchRoutes());
      });
    }
    if (event is MapEventMoveEnd) {
      _debounceRoutes?.cancel();
      _debounceRoutes = Timer(const Duration(milliseconds: 400), () {
        if (mounted) unawaited(_chargerRoutes());
      });
      _debouncePois?.cancel();
      _debouncePois = Timer(const Duration(milliseconds: 700), () {
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

    final camera = widget.mapController.camera;
    if (camera.zoom < _zoomMinPois) {
      if (_pois.isNotEmpty) {
        setState(() => _pois = []);
      }
      return;
    }

    final cle = 'kinshasa';

    final enCache = _poiCache[cle];
    if (enCache != null) {
      if (identical(enCache, _pois)) return;
      setState(() => _pois = enCache);
      return;
    }

    try {
      final pois = await _telechargerPois();
      _poiCache[cle] = pois;
      while (_poiCache.length > 30) {
        _poiCache.remove(_poiCache.keys.first);
      }
      if (mounted) {
        setState(() => _pois = pois);
      }
    } catch (e) {
      debugPrint('[KinFlow] Erreur chargement POI: $e');
      _debouncePois?.cancel();
      _debouncePois = Timer(const Duration(seconds: 15), () {
        if (mounted) unawaited(_chargerPois());
      });
    }
  }

  Future<List<_Poi>> _telechargerPois() async {
    const query = '''
[out:json][timeout:25];
area["boundary"="administrative"]["admin_level"="4"]["name"="Kinshasa"]->.kin;
(
  nwr["amenity"~"^(restaurant|cafe|bar|pub|school|college|university|hospital|clinic|pharmacy|bank|marketplace|market|place_of_worship|church|mosque|fuel|police|fire_station|post_office|library|cinema|theatre|parking|taxi)\$"](area.kin);
  nwr["shop"~"^(supermarket|mall|convenience|general|bakery|butcher)\$"](area.kin);
  nwr["tourism"~"^(hotel|guest_house|museum|attraction|viewpoint)\$"](area.kin);
  nwr["leisure"~"^(park|stadium|sports_centre)\$"](area.kin);
  nwr["office"~"^(government|embassy)\$"](area.kin);
);
out center tags;
''';

    const maxTentatives = 3;
    const baseBackoff = Duration(seconds: 2);

    // Bascule sur un miroir Overpass différent à chaque tentative pour ne
    // pas marteler un serveur déjà limité en débit (429/504).
    const endpoints = [
      'https://overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://overpass.private.coffee/api/interpreter',
    ];

    for (var tentative = 0; tentative < maxTentatives; tentative++) {
      final endpoint = endpoints[tentative % endpoints.length];
      try {
        final reponse = await http
            .post(
              Uri.parse(endpoint),
              headers: {'User-Agent': 'KinFlow-App/1.0 (projet kinflow)'},
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 25));

        if (reponse.statusCode == 200) {
          return compute(_parserPois, json.decode(reponse.body));
        }

        final resoumettre =
            reponse.statusCode == 429 || reponse.statusCode == 504;
        if (!resoumettre) {
          throw Exception('Overpass POI: HTTP ${reponse.statusCode}');
        }

        final retryAfter =
            int.tryParse(reponse.headers['retry-after'] ?? '');
        final delai = retryAfter != null && retryAfter > 0
            ? Duration(seconds: retryAfter)
            : baseBackoff * (1 << tentative);
        Journal.a('CARTE', 'Surcharge Overpass POI, nouvelle tentative dans ${delai.inSeconds} s', {
          'code_http': reponse.statusCode,
          'tentative': tentative + 1,
          'miroir': endpoint,
        });
        await Future<void>.delayed(delai);
      } on TimeoutException {
        if (tentative >= maxTentatives - 1) rethrow;
        final delai = baseBackoff * (1 << tentative);
        Journal.a('CARTE', 'Délai dépassé Overpass POI, nouvelle tentative dans ${delai.inSeconds} s', {
          'tentative': tentative + 1,
          'miroir': endpoint,
        });
        await Future<void>.delayed(delai);
      } on http.ClientException {
        if (tentative >= maxTentatives - 1) rethrow;
        final delai = baseBackoff * (1 << tentative);
        await Future<void>.delayed(delai);
      }
    }

    throw Exception('Overpass POI: échec après $maxTentatives tentatives');
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
    if (zoom < _zoomMinPois) return -1;
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

  List<_Poi> _poisVisibles() {
    if (!_carteRendue) return const [];
    final camera = widget.mapController.camera;
    final zoom = camera.zoom;
    if (zoom < _zoomMinPois) return const [];

    final seuil = _seuilPoiParZoom(zoom);
    if (seuil < 0) return const [];

    final espace = _espacementPois(zoom);

    final parType = <String, List<_Poi>>{};
    for (final poi in _pois) {
      if (_prioritePoi(poi.type) > seuil) continue;
      parType.putIfAbsent(poi.type, () => []).add(poi);
    }
    final types = parType.keys.toList()
      ..sort((a, b) => _prioritePoi(a).compareTo(_prioritePoi(b)));

    final visibles = <_Poi>[];
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
        if ((places[type] ?? 0) >= _maxPoisVisiblesParType) continue;
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

    final camera = widget.mapController.camera;
    if (camera.zoom < _zoomMinGlobal) {
      if (_polylignesTrafic.isNotEmpty) {
        setState(() => _polylignesTrafic = []);
      }
      return;
    }

    // Pendant un itinéraire, on charge aussi le trafic de la partie visible :
    // l'utilisateur peut zoomer/regarder ailleurs que le couloir, les lignes
    // doivent y apparaître en quelques secondes. Seul l'itinéraire garde la
    // priorité de dessin au-dessus des rues.

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

    _reconstruirePolylignes();

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
      _debounceRoutes = Timer(const Duration(seconds: 5), () {
        if (mounted) unawaited(_chargerRoutes());
      });
    }
  }

  /// Prefetch les routes de la zone visible + une marge de 20 % : quand
  /// l'utilisateur panne légèrement, les données sont déjà en cache et le
  /// rebuild est instantané. Ne fait rien si la zone est déjà couverte.
  Future<void> _prefetchRoutes() async {
    if (!_fmtcReady || !mounted) return;
    final camera = widget.mapController.camera;
    if (camera.zoom < _zoomMinGlobal) return;

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
    final zoom = widget.mapController.camera.zoom;
    if (zoom < _zoomMinGlobal) {
      if (_polylignesTrafic.isNotEmpty ||
          _polylignesItineraire.isNotEmpty) {
        setState(() {
          _polylignesTrafic = [];
          _polylignesItineraire = [];
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
      // liste ne sont simplement plus dessinées.
      if (polylignes.length >= _maxPolylignes) break;
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
  /// quand le plafond [_maxPolylignes] est atteint.
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

  Marker _marqueurPoi(_Poi poi) {
    final (icone, couleur) = _iconePoi(poi.type);
    final afficherNom =
        widget.mapController.camera.zoom >= _zoomNomPois && poi.nom.isNotEmpty;
    return Marker(
      point: poi.point,
      width: afficherNom ? 110 : 34,
      height: afficherNom ? 48 : 34,
      alignment: Alignment.topCenter,
      rotate: true,
      child: _MarqueurPoi(
        icone: icone,
        couleur: couleur,
        nom: afficherNom ? poi.nom : '',
      ),
    );
  }

  /// Découpe un segment en tronçons. Les rues sont colorées selon l'état
  /// simulé (heure de la journée) ; les portions couvertes par une zone de
  /// circulation réelle (puis l'itinéraire) portent la couleur des témoins.
  List<Polyline> _decouperParEtat(
    RoadSegment segment,
    List<LatLng> points,
    double zoom,
    DateTime maintenant,
  ) {
    final couleurBase = _fondSombre ? Colors.grey.shade400 : Colors.grey.shade500;
    final baseOpacite = _fondSombre ? 0.85 : 0.6;
    final epaisseur = _epaisseur(segment.classe, zoom);

    // Couleur de base du segment : l'état simulé (embouteillages des heures
    // de pointe). Sur la carte claire, les grandes artères des tuiles sont déjà
    // peintes en rouge/jaune : la ligne de trafic doit être PLEINE (opacité 1)
    // et assez épaisse pour masquer entièrement la couleur de la tuile dessous,
    // sinon on voit une ligne verte couper une route rouge (mauvais rendu).
    final simEtat = _simulateur.estimer(segment, moment: maintenant);
    final couleurBaseSim =
        _fondSombre ? Color.lerp(couleurBase, simEtat.couleur, 0.7)! : simEtat.couleur;
    final opaciteBaseSim = _fondSombre ? 0.85 : 1.0;

    ({Color couleur, double opacite}) attribut(LatLng milieu) {
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
  List<Polyline> _decouperItineraireParEtat(List<LatLng> points) {
    if (points.length < 2) return const [];

    final maintenant = DateTime.now();
    final baseOpacite = _fondSombre ? 0.9 : 0.8;
    const epaisseur = 6.0;

    // L'itinéraire est UNE seule ligne colorée continue : elle part du point
    // bleu (départ), passe obligatoirement par le drapeau d'étape et rejoint
    // le point vert (arrivée). Aucun décrochage pointillé aux extrémités :
    // le tracé couvre la totalité du parcours.
    var debut = 0;
    final fin = points.length - 1;

    // Pendant le suivi réel, la portion déjà parcourue derrière l'utilisateur
    // est masquée : la ligne commence à [itineraireDebutVisuel] (l'index du
    // premier point encore devant). Le tracé entier réapparaît à tout moment
    // où l'utilisateur est hors itinéraire (recalcul) car l'index est remis
    // à -1 par l'écran.
    final debutVisuel =
        widget.itineraireDebutVisuel.clamp(0, points.length - 1).toInt();
    if (debutVisuel > debut) {
      debut = debutVisuel;
    }

    final pointsRoute = points.sublist(debut, fin + 1);
    if (pointsRoute.length < 2) return const [];

    final severites = widget.itineraireSeverites;
    final severitesRoute =
        severites != null && severites.length == points.length
            ? severites.sublist(debut, fin + 1)
            : null;
    final severiteParPoint =
        severitesRoute != null && severitesRoute.length == pointsRoute.length;

    final segment = RoadSegment(
      id: -1,
      nom: '',
      classe: 'primary',
      points: pointsRoute,
    );
    final simEtat = _simulateur.estimer(segment, moment: maintenant);

    ({Color couleur, double opacite}) attribut(int i) {
      Color base;
      if (severiteParPoint) {
        final x = severitesRoute[i].clamp(0.0, 3.0);
        final lo = x.floor();
        final hi = min(lo + 1, 3);
        base = Color.lerp(
          EtatTrafic.values[lo].couleur,
          EtatTrafic.values[hi].couleur,
          x - lo,
        )!;
      } else {
        base = simEtat.couleur;
      }
      final milieu = LatLng(
        (pointsRoute[i].latitude + pointsRoute[i + 1].latitude) / 2,
        (pointsRoute[i].longitude + pointsRoute[i + 1].longitude) / 2,
      );
      final zone = _zonePourPoint(milieu);
      if (zone == null) {
        return (couleur: base, opacite: baseOpacite);
      }
      // Même fusion que les rues : fiabilité faible → on se rapproche de
      // l'état simulé, un signalement isolé ne noircit pas tout le tracé.
      final f = zone.fiabilite.clamp(0.0, 1.0);
      return (
        couleur: Color.lerp(base, zone.etat.couleur, f)!,
        opacite: (0.35 + 0.65 * f).clamp(0.0, 1.0),
      );
    }

    // L'itinéraire est UNE seule ligne, épaisseur constante, dont la couleur
    // suit l'état des routes tronçon par tronçon. Aucun contour : les
    // polylignes de trafic étant masquées pendant l'itinéraire, le tracé
    // n'a besoin d'aucun liseré pour se détacher.
    final polylignes = <Polyline>[];
    var courant = <LatLng>[pointsRoute.first];
    var couleur = simEtat.couleur;
    var opacite = baseOpacite;

    void fermer() {
      if (courant.length >= 2) {
        polylignes.add(Polyline(
          points: List.of(courant),
          strokeWidth: epaisseur,
          color: couleur.withValues(alpha: opacite.clamp(0.0, 1.0)),
          // Caps ronds : les tronçons colorés se recouvrent aux transitions
          // sans laisser voir le contour, la ligne reste unique et continue.
          strokeCap: StrokeCap.round,
          strokeJoin: StrokeJoin.round,
        ));
      }
    }

    for (var i = 0; i < pointsRoute.length - 1; i++) {
      final a = attribut(i);
      if (a.couleur != couleur || a.opacite != opacite) {
        fermer();
        courant = <LatLng>[pointsRoute[i]];
        couleur = a.couleur;
        opacite = a.opacite;
      }
      courant.add(pointsRoute[i + 1]);
    }
    fermer();

    return polylignes;
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

  Widget _tuileDeBase(_ModeCarte mode) {
    final url = switch (mode) {
      _ModeCarte.sombre => _urlTuilesSombre,
      _ModeCarte.satellite => _urlTuilesSatellite,
      _ModeCarte.claire => _urlTuiles,
    };
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


  @override
  Widget build(BuildContext context) {

    double? decalageBoutons;
    double? largeurBoutons;
    double? hauteurBoutons;

    if (widget.afficherActions && widget.pointActions != null) {

      final textScaler = MediaQuery.textScalerOf(context);

      final styleBase =
          DefaultTextStyle.of(context).style.copyWith(
                fontSize: _BoutonAction.tailleTexte,
                fontWeight: FontWeight.w600,
              );

      final largeur2 =
          _BoutonAction.largeurPour(
            'Supprimer',
            styleBase,
            textScaler,
          );

      final largeurDetails =
          _BoutonAction.largeurPour(
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
            _BoutonAction.largeurPour(
              widget.libelleActionPrincipale,
              styleBase,
              textScaler,
            );

        decalageBoutons = (largeur2 - largeur1) / 2;

        largeurBoutons = largeur1 + 8 + largeur2;
      }

      hauteurBoutons =
          _BoutonAction.hauteurPour(styleBase, textScaler);

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

                    child: const Icon(

                      Icons.location_pin,

                      color: Colors.blue,

                      size: 50,

                    ),

                  ),



                if (widget.lieuRecherche != null)


                  Marker(

                    point: widget.lieuRecherche!,

                    width: 50,

                    height: 50,


                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: const Icon(

                      Icons.location_pin,

                      color: Colors.green,

                      size: 50,

                    ),

                  ),


                // Destination de l'itinéraire : son pin vert reste en place
                // même quand un autre lieu est ensuite recherché.
                if (widget.pointDestination != null)

                  Marker(

                    point: widget.pointDestination!,

                    width: 50,

                    height: 50,

                    rotate: true,

                    child: const Icon(

                      Icons.location_pin,

                      color: Colors.green,

                      size: 50,

                    ),

                  ),

                // Étape obligatoire de l'itinéraire (une seule).
                // Affiche un petit drapeau (checkpoint) avant la destination.
                if (widget.pointEtape != null)

                  Marker(

                    point: widget.pointEtape!,

                    width: 50,

                    height: 50,

                    rotate: true,

                    child: Icon(

                      Icons.flag,

                      color: _fondSombre ? Colors.white : Colors.black,

                      size: 42,

                    ),

                  ),



                if (widget.epingle != null)


                  Marker(

                    point: widget.epingle!,


                    width: 40,

                    height: 40,


                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: Icon(

                      Icons.push_pin,

                      color: _fondSombre ? Colors.white : Colors.black,

                      size: 40,

                    ),

                  ),

                // Le point vert de destination reste toujours visible,
                // y compris pendant un itinéraire actif. Sauf quand les
                // actions sont attachées à l'épingle rouge : l'épingle
                // reste un repère rouge, on ne la recouvre jamais de vert.
                if (widget.pointActions != null &&
                    !widget.seulementSupprimer &&
                    !widget.actionsSurEpingle &&
                    widget.pointActions != widget.epingle)

                  Marker(

                    point: widget.pointActions!,

                    width: 50,

                    height: 50,

                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: const Icon(

                      Icons.location_pin,

                      color: Colors.green,

                      size: 50,

                    ),

                  ),

                if (widget.afficherActions &&
                    widget.pointActions != null)

                  Marker(

                    point: widget.pointActions!,

                    width: largeurBoutons!,

                    height: hauteurBoutons! + 40,

                    // Reste droit pendant la rotation de la carte.
                    rotate: true,

                    child: Transform.translate(

                      offset: Offset(decalageBoutons!, 40),

                      child: _BoutonsActions(

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



        if (_fmtcReady)
          Positioned(
            right: 8,
            bottom: 16,
            child: _BoutonModeCarte(
              onPressed: _ouvrirMenuCartes,
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

class _BoutonsActions extends StatelessWidget {

  final VoidCallback? onDefinirItineraire;

  /// Libellé du bouton principal (« Définir itinéraire » ou « Ajouter à
  /// l'itinéraire » selon le contexte).
  final String libelleDefinirItineraire;

  final VoidCallback? onSupprimer;

  /// Affiche les coordonnées géographiques du point bleu de position.
  final VoidCallback? onVoirDetails;

  final bool afficherDefinirItineraire;

  final VoidCallback onInteractionStart;

  final VoidCallback onInteractionEnd;

  const _BoutonsActions({

    this.onDefinirItineraire,

    this.libelleDefinirItineraire = 'Définir itinéraire',

    this.onSupprimer,

    this.onVoirDetails,

    this.afficherDefinirItineraire = true,

    required this.onInteractionStart,

    required this.onInteractionEnd,

  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => onInteractionStart(),
      onPointerUp: (_) => onInteractionEnd(),
      onPointerCancel: (_) => onInteractionEnd(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (afficherDefinirItineraire)
            _BoutonAction(
              onPressed: onDefinirItineraire,
              icone: Icons.route,
              libelle: libelleDefinirItineraire,
              couleur: Colors.black,
            ),
          if (afficherDefinirItineraire) const SizedBox(width: 8),
          // Le point bleu de position affiche « Détails » + « Supprimer ».
          // Le point bleu de position affiche « Détails » + « Supprimer ».
          if (onVoirDetails != null) ...[
            _BoutonAction(
              onPressed: onVoirDetails,
              icone: Icons.info_outline,
              libelle: 'Détails',
              couleur: Colors.black,
            ),
            const SizedBox(width: 8),
          ],
          _BoutonAction(
            onPressed: onSupprimer,
            icone: Icons.delete,
            libelle: 'Supprimer',
            couleur: Colors.black,
          ),
        ],
      ),
    );
  }

}

class _BoutonAction extends StatelessWidget {

  static const double paddingHorizontal = 12;

  static const double paddingVertical = 8;

  static const double iconeTaille = 18;

  static const double ecartIcone = 6;

  static const double tailleTexte = 12;

  static double largeurPour(
    String texte,
    TextStyle styleBase,
    TextScaler textScaler,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: texte, style: styleBase),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    return tp.width + (2 * paddingHorizontal) + iconeTaille + ecartIcone + 4;
  }

  static double hauteurPour(
    TextStyle styleBase,
    TextScaler textScaler,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: 'Ag', style: styleBase),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    return max(iconeTaille, tp.height) + (2 * paddingVertical);
  }

  final VoidCallback? onPressed;

  final IconData icone;

  final String libelle;

  final Color couleur;

  const _BoutonAction({

    this.onPressed,

    required this.icone,

    required this.libelle,

    required this.couleur,

  });

  @override
  Widget build(BuildContext context) {
    final actif = onPressed != null;
    final couleurBtn = actif ? couleur : Colors.grey;
    return Material(
      color: actif ? Colors.white : Colors.grey.shade200,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
          color: actif ? Colors.black : Colors.grey,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: paddingHorizontal,
            vertical: paddingVertical,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icone, size: iconeTaille, color: couleurBtn),
              const SizedBox(width: ecartIcone),
              Flexible(
                child: Text(
                  libelle,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: tailleTexte,
                    fontWeight: FontWeight.w600,
                    color: couleurBtn,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

}

class _MarqueurPoi extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String nom;
  const _MarqueurPoi({
    required this.icone,
    required this.couleur,
    required this.nom,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: couleur, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Icon(icone, size: 15, color: couleur),
        ),
        if (nom.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(maxWidth: 104),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              nom,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
      ],
    );
  }
}

class _BoutonModeCarte extends StatelessWidget {
  final VoidCallback onPressed;
  const _BoutonModeCarte({
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Colors.black26),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onPressed,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.layers,
                size: 18,
                color: Colors.black87,
              ),
              SizedBox(width: 6),
              Text(
                "Cartes",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionModeCarte extends StatelessWidget {
  final IconData icone;
  final String libelle;
  final bool selectionne;
  final bool sombre;
  final VoidCallback onTap;
  const _OptionModeCarte({
    required this.icone,
    required this.libelle,
    required this.selectionne,
    this.sombre = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final couleurTexte = sombre ? KinColors.texteSombre : Colors.black87;
    return ListTile(
      leading: Icon(icone, color: couleurTexte),
      title: Text(
        libelle,
        style: TextStyle(fontSize: 15, color: couleurTexte),
      ),
      trailing: selectionne
          ? const Icon(Icons.check_circle, color: KinColors.primary)
          : null,
      onTap: onTap,
    );
  }
}

