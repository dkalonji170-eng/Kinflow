import 'dart:async';
import 'dart:math' show Point, cos, exp, max, min, pow;
import 'package:flutter/foundation.dart' show listEquals, debugPrint, kIsWeb;
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
import '../models/ami_position.dart';
import '../models/traffic_state.dart';
import '../theme/kinflow_theme.dart';
import '../utils/geo.dart'
    show deltaRotation, distanceMetresHaversine, normaliserDegre;
import '../utils/latlng_tween.dart';
import '../utils/temps_relatif.dart';
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
import '../services/rendu_itineraire.dart'
    show construireRaccordDepart, decouperItineraireParEtat;
import '../services/road_service.dart';
import '../services/diagnostics_service.dart';
import '../services/data_usage_service.dart';
import '../services/tile_prefetch_service.dart';
import '../services/traffic_simulator.dart';
import '../services/traffic_stats_service.dart';
import '../services/supabase_service.dart';
import '../services/orientation_navigation.dart';
import 'map_controls.dart';
import 'map_painters.dart' show PeintreEtape;
import 'avatar_animal.dart';

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

/// Rouge « épingle classique » (comme les cartes) pour les épingles posées,
/// la prévisualisation et le bouton « Épingler ».
const Color _couleurEpinglette = Color(0xFFE53935);

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
/// Volontairement VIF (10/s, convergence à ~95 % en 0,3 s) : le point bleu
/// étant désormais glissé avec la caméra, une raideur élevée donne une suite
/// immédiate à chaque fix GPS — l'utilisateur sent qu'il avance tout de
/// suite. L'exponentiel interdit toujours le téléport : la trajectoire reste
/// continue.
const double _navFacteurLissage = 10.0;

/// Mode navigation : raideur du lissage exponentiel de la ROTATION (par
/// seconde). Relevée de 1,5 à 3,0 pour un rendu « décidé » : quand un
/// recadrage (ou l'adaptation continue) décide de pivoter, la carte le fait
/// vite. Le double seuil 10°/5 m en amont limite déjà le nombre de
/// recadrages — la raideur ne fait que leur donner de l'allant.
const double _navFacteurLissageRotation = 3.0;

/// Mode navigation : écart angulaire minimal (degrés) entre la rotation
/// caméra courante et le cap filtré pour reprogrammer une adaptation
/// continue de l'orientation. Sous ce seuil la carte reste figée : le filtre
/// circulaire du cap suffit déjà à éliminer le bruit, il ne faut pas en
/// plus faire « danser » la caméra sur des micro-variations.
/// Seuil réduit de 8° à 6° avec une raideur de rotation relevée à 3,0 :
/// réponse « vif mais stable » — la carte réagit à de vraies inflexions de
/// trajectoire sans osciller en ligne droite (le cap GPS est déjà filtré).
const double _seuilRotationContinueDegres = 6.0;

/// Mode navigation : part de la hauteur d'écran séparant le centre réel de
/// la caméra du point utilisateur (placé plus bas, vers le tiers inférieur).
const double _navProportionDecalage = 0.22;

/// Mode navigation : distance minimale (mètres) parcourue entre le début et
/// la fin d'un geste manuel pour considérer l'utilisateur « en mouvement » et
/// reprendre le recentrage IMMÉDIATEMENT au relâchement. En dessous, la carte
/// reste là où le geste l'a laissée et attend la prochaine fix GPS réellement
/// déplacée : le suivi ne doit pas arracher la vue d'un utilisateur immobile
/// qui vient de consulter la carte.
const double _seuilMouvementGesteMetres = 5.0;

const double _tailleCellule = 0.01;
const double _grilleMinLat = -5.0;
const double _grilleMinLon = 15.05;
const int _grilleMaxCols = 64;

int _celluleLat(double lat) => ((lat - _grilleMinLat) / _tailleCellule).floor();
int _celluleLon(double lon) => ((lon - _grilleMinLon) / _tailleCellule).floor();
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
  topo,
}

const String _urlTuiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

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

const String _urlTuilesTopo = 'https://tile.opentopomap.org/{z}/{x}/{y}.png';

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

/// Type de lieu personnel que l'utilisateur pose sur la carte : son
/// domicile (maison) ou son lieu de travail (mallette).
enum TypeLieuPose { maison, travail }

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

  /// Demande (depuis la recherche de lieu) d'entrer en mode « poser un lieu
  /// personnel » : une icône de prévisualisation (maison ou mallette) suit
  /// le centre de l'écran, la carte se laisse pivoter et déplacer dessous
  /// pour viser le point, puis l'utilisateur la pose avec « Poser ». `null`
  /// quand aucune pose n'est demandée.
  final TypeLieuPose? poseLieu;

  /// Point du domicile enregistré : une icône maison reste ancrée sur ce
  /// lieu, collée à la carte tant que le domicile n'est pas changé.
  final LatLng? pointMaison;

  /// Point du lieu de travail enregistré : une mallette reste ancrée sur ce
  /// lieu, collée à la carte tant que le lieu de travail n'est pas changé.
  final LatLng? pointTravail;

  /// Appelé quand l'utilisateur pose l'icône (maison ou travail) : fournit
  /// le type posé et la coordonnée géographique au centre de la carte, que
  /// le parent persiste comme domicile ou lieu de travail.
  final void Function(TypeLieuPose type, LatLng point)? onPoserLieu;

  /// Appelé quand l'utilisateur annule la pose : le parent ressort du mode
  /// pose sans enregistrer.
  final VoidCallback? onAnnulerPoseLieu;

  final LatLng? pointActions;

  /// Le menu d'actions est attaché à l'épingle rouge existante : dans ce cas
  /// aucun marqueur vert de destination n'est dessiné par-dessus elle.
  final bool actionsSurEpingle;

  /// Actions contextuelles ouvertes sur le pin vert de l'ami(e) localisé.
  /// Les boutons habituels s'affichent quand même ; ce drapeau sert seulement
  /// à ne pas dessiner l'épingle rouge par-dessus le pin de l'ami(e).
  final bool actionsSurAmi;

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

  /// Point de DÉPART réel de l'itinéraire (là où l'utilisateur l'a demandé),
  /// indépendant de la position bleue vivante. Sert d'ancrage aux pointillés
  /// noirs de départ quand le GPS n'a pas encore parlé — et en repli OSRM, dont
  /// le tracé ne conserve pas la queue hors chaussée.
  final LatLng? itineraireDepart;

  /// Pin vert de la destination de l'itinéraire en cours (null sinon) :
  /// reste visible même quand un autre lieu est ensuite recherché.
  final LatLng? pointDestination;

  /// Pins ambre numérotés des étapes obligatoires de l'itinéraire, dans
  /// l'ordre du parcours (aucun si l'itinéraire n'a pas d'étape).
  final List<LatLng> pointEtape;

  /// Amis(es) dont la position est partagée en direct : affichés par un
  /// marqueur rond (avatar + prénom) au-dessus de la carte.
  final List<AmiPosition> amis;

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

    this.poseLieu,

    this.pointMaison,

    this.pointTravail,

    this.onPoserLieu,

    this.onAnnulerPoseLieu,

    this.pointActions,

    this.actionsSurEpingle = false,

    this.actionsSurAmi = false,

    this.versionZonesTrafic = 0,

    this.onZonesTrafic,

    this.itinerairePoints,

    this.itineraireSeverites,

    this.itineraireDebutRoute = 0,

    this.itineraireDebutVisuel = -1,

    this.itineraireFinRoute = -1,

    this.itineraireSegmentIds,

    this.itineraireDepart,

    this.pointDestination,

    this.pointEtape = const [],

    this.amis = const [],

    this.libelleActionPrincipale = 'Définir itinéraire',

    this.desactiverItineraire = false,

    this.modeNavigation = false,

    this.capUtilisateur,

    this.onNavigationInterrompue,
  });

  @override
  State<TrafficMap> createState() => _TrafficMapState();
}

class _TrafficMapState extends State<TrafficMap> with TickerProviderStateMixin {
  bool chargementCarte = true;
  bool _fmtcReady = false;
  bool _carteRendue = false;
  _ModeCarte _modeCarte = _ModeCarte.claire;
  final ScrollController _menuCartesScroll = ScrollController();

  /// Fournisseurs de tuiles FMTC, un par famille de fond (OSM, Carto,
  /// satellite, topo...). Il en faut un DISTINCT par famille : avec un
  /// fournisseur unique, le cache d'images de Flutter réassocie les tuiles
  /// déjà affichées au même identifiant (FMTC #183) et ne recharge jamais le
  /// nouveau style — la bascule de carte semble alors « prendre une éternité »
  /// et n'apparaît qu'en se déplaçant. Les familles sont mises en cache pour
  /// réutiliser le même fournisseur (et donc le même cache mémoire) au retour.
  final Map<String, FMTCTileProvider> _providersFmtc = {};

  /// Fournisseur réseau partagé (web ou cache FMTC indisponible). Construit une
  /// seule fois : en recréer un à chaque build fuite un client HTTP et casse la
  /// session de chargement des tuiles.
  NetworkTileProvider? _providerReseau;

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
  int get _plafondPolylignes =>
      _estNuit() ? _maxPolylignesNuit : _maxPolylignes;

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

  /// Position « vivante » du point bleu : pilotée par le ticker navigation
  /// (qui la fait glisser avec la caméra lissée) ou par l'animation du pin.
  /// C'est un NOTIFIER et non un setState : quand le point bouge, seul le
  /// calque des marqueurs (et le raccord de départ) se reconstruit — les
  /// 600→1600 polylignes de trafic restent intactes.
  final ValueNotifier<LatLng?> _pointBleuNotifier = ValueNotifier<LatLng?>(
    null,
  );

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

  /// Pendant la navigation, un geste manuel (glisser, pincer, pivoter,
  /// double-clic de zoom, appui long de dézoom) ne COUPE plus le suivi : il
  /// le suspend le temps du geste, puis la carte attend un réel déplacement
  /// avant de se recentrer — sinon le suivi arracherait la vue d'un
  /// utilisateur immobile qui vient de consulter la carte.
  bool _suiviEnAttenteMouvement = false;

  /// Position GPS au début du geste manuel : comparée à celle du relâchement
  /// pour décider si l'utilisateur est déjà en mouvement (≥
  /// [_seuilMouvementGesteMetres]) et reprendre le recentrage aussitôt.
  LatLng? _positionDebutGeste;

  /// Appui long maintenu (dézoom continu) : suspend l'écriture de la caméra
  /// par le suivi comme un geste, jusqu'au relâchement du doigt.
  bool _longPressDezoomActif = false;

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

  /// Mode pose d'un lieu personnel (maison ou travail, [TypeLieuPose]) :
  /// même mécanique que l'épingle, mais avec l'icône du lieu demandé. Entré
  /// à la demande du parent ([widget.poseLieu]), sorti quand l'utilisateur
  /// pose ou annule.
  TypeLieuPose? _poseLieuActif;

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
  final TilePrefetchService _prefetchService = TilePrefetchService(
    nomMagasin: 'kinshasa',
  );

  /// Anti-spam molette : le zoom à la molette déclenche une rafale
  /// d'événements (un par cran) — on ne journalise qu'à la fin de la rafale.
  Timer? _debounceJournalMolette;
  List<Polyline> _polylignesTrafic = [];
  List<Polyline> _polylignesTraficCache = [];
  List<Polyline> _polylignesItineraire = [];
  List<Polyline> _polylignesRaccordDepart = [];

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
    // La carte est indépendante du thème de l'application : elle s'ouvre
    // TOUJOURS en mode clair au premier affichage, quelle que soit l'ambiance
    // (appli sombre comprise). Ensuite le style ne bouge plus qu'avec le
    // menu « Cartes » ; basculer l'appli en clair/sombre n'écrase jamais le
    // choix de l'utilisateur.
    _modeCarte = _ModeCarte.claire;
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
    if (widget.suspendreTravailCarte && !oldWidget.suspendreTravailCarte) {
      _mettreEnPauseTravailCarte();
    } else if (!widget.suspendreTravailCarte &&
        oldWidget.suspendreTravailCarte) {
      _reprendreTravailCarte();
    }

    // Le style de carte ne suit PAS le thème : basculer l'appli en
    // clair/sombre ne change plus le fond de carte (indépendance totale,
    // seul le menu « Cartes » choisit le style). L'alignement initial est
    // déjà fait dans initState (premier affichage uniquement).

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

    // Demande de pose d'un lieu personnel : on suit le parent pour entrer ou
    // sortir du mode « poser maison/travail » (l'épingle et la pose de lieu
    // ne coexistent jamais, une pose en cours est d'abord refermée).
    if (widget.poseLieu != _poseLieuActif) {
      if (widget.poseLieu != null) {
        _entrerModePoseLieu(widget.poseLieu!);
      } else if (mounted) {
        setState(() => _poseLieuActif = null);
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
    if (!listEquals(oldWidget.pointEtape, widget.pointEtape)) {
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
      oldWidget.itineraireSegmentIds,
      widget.itineraireSegmentIds,
    )) {
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
      // Une fix ACCEPTÉE n'arrive qu'après un réel déplacement (filtre
      // anti-bruit du parent) : elle relance le suivi navigation à la suite
      // d'un geste manuel. Le recentrage repart de la vue LAISSÉE par le
      // geste pour glisser vers le point bleu au lieu d'y sauter.
      if (_suiviEnAttenteMouvement &&
          !identical(oldWidget.positionActuelle, newPos)) {
        _reprendreSuiviNavigation();
      }
      final newLatLng = LatLng(newPos.latitude, newPos.longitude);
      final oldPos = _displayedPosition;

      void nettoyerAnimation() {
        _positionAnimController?.stop();
        _positionAnimController?.dispose();
        _positionAnimController = null;
        _positionAnimation = null;
      }

      if (widget.modeNavigation) {
        // En navigation, le POINT BLEU n'est plus posé directement sur la
        // fix brute : il GLISSE avec la caméra lissée, piloté par
        // [_surTickNavigation] (_navCentreCourant → [_pointBleuNotifier]).
        // Poser la fix brute d'un bloc sur le pin pendant que la caméra la
        // rattrape en douceur produisait le cycle « saut en avant puis
        // glissement en arrière » — brutal et indécis.
        nettoyerAnimation();
        _displayedPosition = newLatLng;
        // Le raccord pointillé suit le point bleu en direct pendant le suivi.
        _majRaccordDepart();
      } else if (oldPos == null) {
        _displayedPosition = newLatLng;
        // Première position : rien à animer, on pose le point d'un coup.
        _pointBleuNotifier.value = newLatLng;
        _majRaccordDepart();
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
          // Réduit de 300 à 200 ms : en mode libre, le point bleu doit
          // réagir presque instantanément à chaque fix GPS accepté.
          duration: const Duration(milliseconds: 200),
        );
        _positionAnimation = LatLngTween(begin: base, end: newLatLng).animate(
          CurvedAnimation(
            parent: _positionAnimController!,
            curve: Curves.easeOut,
          ),
        );
        _positionAnimation!.addListener(() {
          if (!mounted) return;
          // Raccord mis à jour AVANT le notifier : la reconstruction du
          // calque vivant (marqueurs + raccord) lira la liste fraîche.
          _majRaccordDepart();
          _pointBleuNotifier.value = _positionAnimation!.value;
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
      // chaque frame et ramène le zoom vers sa cible : sans suspension,
      // chaque pas de dézoom serait annulé aussitôt émis. Comme pour un
      // glissement manuel, l'appui long suspend le suivi le temps du geste ;
      // au relâchement, la carte garde le dézoom choisi et se recentrera au
      // prochain déplacement ([_finGesteManuel]).
      _camAnim?.dispose();
      _camAnim = null;
      _longPressDezoomActif = true;
      _positionDebutGeste ??= _fixActuelleLatLng;

      final center = widget.mapController.camera.pointToLatLng(
        Point(position.dx, position.dy),
      );

      _zoomOutTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final zoom = widget.mapController.camera.zoom;
        if (zoom > 2) {
          widget.mapController.move(center, zoom - 0.12);
        }
      });
    });
  }

  void _annulerLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _zoomOutTimer?.cancel();
    _zoomOutTimer = null;

    if (!_longPressActif &&
        !_pointeurBouge &&
        _pointerDownPos != null &&
        _pointerDownTime != null) {
      final duree = DateTime.now().difference(_pointerDownTime!);
      if (duree.inMilliseconds < 500 && !_doubleTapEnCours) {
        final point = widget.mapController.camera.pointToLatLng(
          Point(_pointerDownPos!.dx, _pointerDownPos!.dy),
        );
        _singleTapTimer = Timer(const Duration(milliseconds: 180), () {
          if (!mounted) return;
          // En mode pose (épingle ou lieu personnel), un appui simple ne doit ni
          // sélectionner un pin ni ouvrir les infos d'un lieu : la carte sert
          // uniquement à être déplacée sous l'icône de prévisualisation.
          if (!_modePoserEpingle && _poseLieuActif == null) {
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
    // Fin d'un appui long maintenu (dézoom continu) : le dézoom choisi
    // devient la cible du suivi (pas de retour brusque en arrière) et la
    // carte attend un déplacement avant de recentrer, comme tout geste.
    if (_longPressDezoomActif) {
      _longPressDezoomActif = false;
      _navZoomCible = widget.mapController.camera.zoom;
      _finGesteManuel();
    }
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
    // Un appui long en cours interrompu (second doigt posé, geste annulé) :
    // le dézoom choisi reste la cible du suivi, le geste en cours prend le
    // relais (le suivi est déjà suspendu par [_gestesActifs] ou restera en
    // attente jusqu'au prochain déplacement).
    if (_longPressDezoomActif) {
      _longPressDezoomActif = false;
      _navZoomCible = widget.mapController.camera.zoom;
      _suiviEnAttenteMouvement = true;
    }
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
    _pointBleuNotifier.dispose();
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
    // Libère les fournisseurs de tuiles mis en cache. Le TileLayer a déjà
    // libéré celui du fond actif ; dispose() est idempotent (fermeture d'un
    // client HTTP déjà fermé), on peut donc tous les libérer sans risque.
    for (final provider in _providersFmtc.values) {
      unawaited(provider.dispose());
    }
    _providersFmtc.clear();
    final fournisseurReseau = _providerReseau;
    if (fournisseurReseau != null) {
      unawaited(fournisseurReseau.dispose());
    }
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
      final taille = await FMTCStore('kinshasa').stats.size;
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
    // Les deux modes de pose (épingle et lieu personnel) ne coexistent jamais :
    // si une pose de lieu est en cours, on la quitte d'abord.
    if (_poseLieuActif != null) {
      _annulerPoseLieu();
      return;
    }
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
      if (_modePoserEpingle || _poseLieuActif != null) {
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

  /// Entre en mode « poser un lieu personnel » (maison ou travail), demandé
  /// par le parent après un appui sur « Ma maison » ou « Mon travail » dans
  /// la recherche de lieu : l'icône colle au centre de l'écran, la carte
  /// reste libre à pivoter dessous.
  void _entrerModePoseLieu(TypeLieuPose type) {
    if (!mounted) return;
    setState(() {
      _poseLieuActif = type;
      // On referme toute pose d'épingle en cours : l'icône prend le relais
      // et la carte doit rester entièrement libre sous elle.
      _modePoserEpingle = false;
    });
    widget.onNavigationInterrompue?.call();
    _annulerSansTap();
  }

  /// Pose l'icône (maison ou travail) à la coordonnée géographique
  /// actuellement au centre de l'écran, puis quitte le mode pose : le parent
  /// persiste le lieu correspondant.
  void _poserLieu() {
    final centre = widget.mapController.camera.center;
    if (!centre.latitude.isFinite || !centre.longitude.isFinite) return;
    final type = _poseLieuActif;
    if (type == null) return;
    setState(() => _poseLieuActif = null);
    widget.onPoserLieu?.call(type, centre);
  }

  /// Annule la pose : on sort du mode sans enregistrer, le parent referme
  /// aussi sa propre demande.
  void _annulerPoseLieu() {
    setState(() => _poseLieuActif = null);
    widget.onAnnulerPoseLieu?.call();
  }

  /// Bouton « Annuler » de la pose de lieu personnel : même gabarit réduit
  /// que « Poser » (compact), en croix pour bien distinguer les deux actions.
  Widget _boutonAnnulerLieu() {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _annulerPoseLieu,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close, size: 14, color: Colors.black54),
              SizedBox(width: 5),
              Text(
                'Annuler',
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

  void _ouvrirMenuCartes() {
    if (!_fmtcReady || !mounted) return;
    _interactionSurBoutons();
    final sombre = _modeCarte == _ModeCarte.sombre;
    showModalBottomSheet<void>(
      context: context,
      // Contrôle la hauteur nous-mêmes : sans cela la feuille est plafonnée
      // et le geste de glissement sert à la fermer, pas à défiler la liste.
      isScrollControlled: true,
      backgroundColor: sombre ? KinColors.surfaceSombre : Colors.white,
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
    // Ancre de déplacement de l'adaptation continue : posée sur la position
    // de départ. Aucune rotation ne peut donc se déclencher avant un VRAI
    // déplacement de 5 m depuis l'entrée du suivi : un cap résiduel (dernier
    // cap connu avant l'arrêt) ne fait plus pivoter la carte immobile.
    _navDernierePositionRotationContinue = _fixActuelleLatLng;
    _gestesActifs = 0;
    _suiviEnAttenteMouvement = false;
    _longPressDezoomActif = false;
    _positionDebutGeste = null;
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
    _suiviEnAttenteMouvement = false;
    _longPressDezoomActif = false;
    _positionDebutGeste = null;

    // Pendant le suivi, le point bleu glisse avec la caméra lissée
    // ([_navCentreCourant]) : il n'est PAS sur la position GPS réelle. À
    // l'arrêt du suivi (interruption manuelle, récentrage), il faut le
    // réancrer sur la vraie fix : sinon il reste figé sur l'ancien centre
    // lissé, qui après des manipulations de la carte peut se retrouver en
    // dehors du champ visible (« le point bleu quitte la carte »).
    final pos = widget.positionActuelle;
    if (pos != null) {
      final fix = LatLng(pos.latitude, pos.longitude);
      _displayedPosition = fix;
      _pointBleuNotifier.value = fix;
      _majRaccordDepart();
    }
  }

  /// Dernière position GPS reçue par le widget (fix brute), en [LatLng], ou
  /// null tant qu'aucune position n'a été fournie.
  LatLng? get _fixActuelleLatLng {
    final p = widget.positionActuelle;
    if (p == null) return null;
    return LatLng(p.latitude, p.longitude);
  }

  /// Fin d'un geste manuel (glisser, pincer, pivoter, double-clic de zoom,
  /// appui long de dézoom) : le suivi navigation n'est jamais COUPÉ par un
  /// geste, seulement suspendu le temps du geste. Au relâchement :
  ///
  ///  - si l'utilisateur est déjà en mouvement réel (≥ 5 m parcourues depuis
  ///    le début du geste), la carte se recentre sur le point bleu aussitôt ;
  ///  - sinon elle reste là où le geste l'a laissée et attend le prochain
  ///    déplacement ([_reprendreSuiviNavigation] au fil du flux GPS).
  void _finGesteManuel() {
    if (!widget.modeNavigation) return;
    // Défensif (double appel : relâchement du doigt puis événement carte de
    // fin) : s'il n'y a rien à décider, on ne réécrit pas l'état.
    if (_positionDebutGeste == null && !_suiviEnAttenteMouvement) return;
    final debut = _positionDebutGeste;
    _positionDebutGeste = null;
    final fix = _fixActuelleLatLng;
    if (debut != null && fix != null) {
      final metres = distanceHaversineMetres(
        debut.latitude,
        debut.longitude,
        fix.latitude,
        fix.longitude,
      );
      if (metres >= _seuilMouvementGesteMetres) {
        _reprendreSuiviNavigation();
        return;
      }
    }
    _suiviEnAttenteMouvement = true;
  }

  /// Le suivi navigation reprend son écriture de la caméra après un geste
  /// manuel : le centre lissé est ré-ancré sur la coordonnée actuellement
  /// affichée à l'emplacement de suivi (tiers inférieur de l'écran), pour
  /// que le recentrage soit un glissement continu depuis la vue laissée par
  /// le geste, et non un saut depuis l'ancien centre figé.
  void _reprendreSuiviNavigation() {
    _suiviEnAttenteMouvement = false;
    _positionDebutGeste = null;
    final camera = widget.mapController.camera;
    if (!camera.center.latitude.isFinite) return;
    final taille = camera.nonRotatedSize;
    _navCentreCourant = camera.pointToLatLng(
      Point(
        taille.x / 2,
        taille.y / 2 + taille.y * _navProportionDecalageCourante,
      ),
    );
    // Oublier le dernier tick (figé depuis le début du geste) : sinon le
    // premier tick de reprise convergerait à ~70 % d'un coup (saut) au lieu
    // du lissage habituel de ~0,3 s.
    _navDernierTick = null;
    // Le déplacement qui a motivé la reprise ne doit pas servir d'élan pour
    // une rotation immédiate : l'ancre repart de la position courante. La
    // carte ne pivotera qu'après 5 m parcourus DEPUIS la reprise.
    _navDernierePositionRotationContinue = _fixActuelleLatLng;
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
        widget.positionActuelle == null) {
      return;
    }
    // Le suivi de la position NE DÉPEND PAS du cache de tuiles (FMTC). Sur le
    // web, FMTC est ignoré et la carte est prête immédiatement ; sur Android,
    // l'initialisation du cache (ou son échec) retardait `_fmtcReady` et
    // figeait le point bleu alors que la carte est déjà utilisable. On ne
    // s'appuie donc que sur la disponibilité réelle de la caméra.
    final cameraPrete = widget.mapController.camera;
    if (!cameraPrete.center.latitude.isFinite ||
        cameraPrete.nonRotatedSize.x <= 0 ||
        cameraPrete.nonRotatedSize.y <= 0) {
      return;
    }
    // Un geste utilisateur est en cours (glissement, pincement, pivotement,
    // double-clic, appui long de dézoom) : on suspend l'écriture caméra du
    // suivi le temps du geste pour ne pas lui faire opposition. Au
    // relâchement, [_suiviEnAttenteMouvement] garde la main à l'utilisateur
    // jusqu'à un réel déplacement (le suivi reprend alors, cf.
    // [_reprendreSuiviNavigation]).
    if (_gestesActifs > 0 || _longPressDezoomActif) return;
    if (_suiviEnAttenteMouvement) return;

    final dt =
        (_navDernierTick == null
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
        final deplacementSuffisant =
            derniere == null ||
            distanceHaversineMetres(
                  derniere.latitude,
                  derniere.longitude,
                  cible.latitude,
                  cible.longitude,
                ) >=
                seuilDistanceMetres;
        if (deplacementSuffisant) {
          // Déplacement réel : l'ancre avance MAINTENANT, qu'on pivote ou
          // non. Sinon elle resterait figée loin derrière et un simple bruit
          // de cap à l'arrêt (GPS immobile) finirait par dépasser 5 m et
          // ferait pivoter la carte toute seule.
          _navDernierePositionRotationContinue = cible;
          final cibleContinue = normaliserDegre(-capFiltre);
          final cibleEnCours = _navRotationCible ?? _navRotationCourante;
          if (deltaRotation(cibleEnCours, cibleContinue).abs() >=
              _seuilRotationContinueDegres) {
            _navRotationCible = cibleContinue;
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

    // Le point bleu GLISSE avec la caméra : il est posé sur le centre lissé
    // (et non sur la fix brute, qui le faisait sauter en avant puis refluer
    // d'un coup quand la caméra le rattrapait). Garde anti-tremblement : on
    // ne notifie que si le point a réellement bougé d'une trame à l'autre.
    final navCourant = _navCentreCourant;
    final pointAffiche = _pointBleuNotifier.value;
    if (navCourant != null &&
        (pointAffiche == null ||
            (navCourant.latitude - pointAffiche.latitude).abs() > 1e-9 ||
            (navCourant.longitude - pointAffiche.longitude).abs() > 1e-9)) {
      _majRaccordDepart();
      _pointBleuNotifier.value = navCourant;
    }

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
        (_navCentreCourant!.latitude - camera.center.latitude).abs() > 1e-9 ||
        (_navCentreCourant!.longitude - camera.center.longitude).abs() > 1e-9 ||
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
      _positionDebutGeste ??= _fixActuelleLatLng;
    } else if (event is MapEventMoveEnd ||
        event is MapEventRotateEnd ||
        event is MapEventDoubleTapZoomEnd) {
      if (_gestesActifs > 0) _gestesActifs--;
      // Fin de TOUS les gestes en cours (le pincement émet Move ET Rotate) :
      // le suivi reprend ou attend un déplacement selon le mouvement réel.
      if (_gestesActifs == 0) _finGesteManuel();
    }
    // Inertie de lâcher (fling) : après un glissement rapide, flutter_map
    // continue d'animer la caméra sur l'élan. Le suivi doit rester suspendu
    // durant cette dérive pour n'offrir AUCUNE résistance ; il ne reprendra
    // qu'au prochain déplacement réel (carte lâchée + utilisateur en marche).
    if (widget.modeNavigation && event is MapEventFlingAnimation) {
      _suiviEnAttenteMouvement = true;
    }
    // Zoom à la molette (web/desktop) : pas d'événement « début/fin » de
    // geste associé — chaque cran est une manipulation directe. Le suivi
    // reste suspendu pendant et après le zoom pour n'offrir aucune
    // résistance, et reprend au prochain déplacement réel.
    if (widget.modeNavigation && event is MapEventScrollWheelZoom) {
      _suiviEnAttenteMouvement = true;
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
    // La signature embarque aussi la visibilité des badges ancrés des lieux
    // personnels : elle change dès qu'un badge de maison/travail franchit le
    // seuil [_zoomMinLieuxPersonnels], même si les tableaux de POIs, eux, ne
    // bougent pas. Sans cela, le marqueur resterait figé jusqu'au prochain
    // changement de seuil POI.
    final signature =
        _seuilPoiParZoom(zoom) * 100 +
        _espacementPois(zoom).round() +
        ((_lieuxPersonnelsVisibles(zoom)) ? 1000000 : 0);
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
      _segmentsCache[_cleSegments(rond, detailsComplets)] = _SegmentsParZone(
        segments,
        rond,
        detailsComplets,
      );
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
      // Disjoncteur Overpass ouvert : état attendu et temporaire (pause de
      // secours pendant 30 s à 240 s), pas une erreur. Le repli exponentiel
      // ci-dessous relancera tout seul à la fin de la pause.
      if (RoadService.disjoncteurOuvert) {
        Journal.a(
          'CARTE',
          'Chargement des routes suspendu : disjoncteur Overpass ouvert',
        );
      } else {
        Journal.e('CARTE', 'Chargement des routes pour la carte échoué', {
          'erreur': '$e',
        });
      }
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
    final lointain =
        (couloir.north - couloir.south) > 0.08 ||
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
      _segmentsCache[_cleSegments(rond, detailsComplets)] = _SegmentsParZone(
        segments,
        rond,
        detailsComplets,
      );
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
    // Le préchauffage n'a de sens qu'avec le cache FMTC disponible : sur le
    // réseau seul (web ou FMTC indisponible), il n'y a pas de cache à remplir.
    if (!_fmtcReady || kIsWeb || !fmtcSucceeded || !mounted) return;
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

      _segmentsCache[_cleSegments(rond, detailsComplets)] = _SegmentsParZone(
        segments,
        rond,
        detailsComplets,
      );
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
      LatLng((b.north * f).ceilToDouble() / f, (b.east * f).ceilToDouble() / f),
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
    return _arrondirBounds(
      LatLngBounds(
        LatLng(centreLat - demiLat, centreLon - demiLon),
        LatLng(centreLat + demiLat, centreLon + demiLon),
      ),
    );
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
          _polylignesRaccordDepart.isNotEmpty ||
          _raccordEtape.isNotEmpty) {
        setState(() {
          _polylignesTrafic = [];
          _polylignesItineraire = [];
          _polylignesRaccordDepart = [];
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
    _majRaccordDepart();

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
      polylignes.addAll(_decouperParEtat(segment, simpl, zoom, maintenant));
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

  /// Marqueur d'un ami(e) qui partage sa position : un pin vert (goutte
  /// `location_on`) contenant son avatar, son prénom, puis l'âge de la
  /// dernière position connue (« il y a 15 minutes »), le tout sous le pin.
  /// `IgnorePointer` empêche le marqueur de capter les gestes destinés à la
  /// carte ; l'ancrage fait tomber la POINTE du pin sur la position.
  ///
  /// La hauteur de la boîte a grandi (72 → 92) pour loger la ligne du temps
  /// SANS déplacer le pin : l'alignement vertical est recalculé pour garder la
  /// même position de pointe à l'écran (même hauteur sous le pin qu'avant).
  Marker _marqueurAmi(AmiPosition ami) {
    return Marker(
      point: ami.position,
      width: 120,
      height: 92,
      alignment: const Alignment(0, 0.59),
      // Contre-rotation : le pin reste droit quand la carte pivote.
      rotate: true,
      child: _MarqueurAmi(ami: ami),
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
    final couleurBase = _fondSombre
        ? Colors.grey.shade400
        : Colors.grey.shade500;
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
    final couleurBaseSim = _fondSombre
        ? Color.lerp(couleurBase, simEtat.couleur, 0.7)!
        : simEtat.couleur;
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
      return (
        couleur: couleur,
        opacite: _fondSombre ? (0.35 + 0.65 * f).clamp(0.0, 1.0) : 1.0,
      );
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
        ..._decouperPourLabel(
          segment,
          t.pts,
          t.couleur,
          epaisseur,
          zoom,
          t.opacite,
        ),
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
      departAncre: departAncreVivant() ?? widget.itineraireDepart,
      arriveeAncre: widget.pointDestination,
    );
  }

  /// Position bleue effective à l'écran : celle de l'animation en cours, sinon
  /// la dernière affichée, sinon la position GPS reçue. Sert à rattacher les
  /// pointillés de départ de l'itinéraire au pin bleu, où qu'il soit.
  LatLng? departAncreVivant() {
    final vivant = _pointBleuNotifier.value;
    if (vivant != null) return vivant;
    if (_positionAnimation != null) return _positionAnimation!.value;
    if (_displayedPosition != null) return _displayedPosition;
    final pos = widget.positionActuelle;
    if (pos == null) return null;
    return LatLng(pos.latitude, pos.longitude);
  }

  /// Re-dessine les pointillés noirs du DÉPART de l'itinéraire à l'endroit du
  /// point bleu VIVANT : appelé à chaque fix GPS accepté et à chaque trame de
  /// l'animation du pin, pour que le raccord suive le point bleu même quand il
  /// saute. Rare et bon marché (une seule polyligne).
  void _majRaccordDepart() {
    final points = widget.itinerairePoints;
    final raccord = (points == null || points.length < 2)
        ? const <Polyline>[]
        : construireRaccordDepart(
            points: points,
            debutRoute: widget.itineraireDebutRoute,
            debutVisuel: widget.itineraireDebutVisuel,
            fondSombre: _fondSombre,
            departAncre: departAncreVivant() ?? widget.itineraireDepart,
          );
    if (!listEquals(_polylignesRaccordDepart, raccord)) {
      _polylignesRaccordDepart = raccord;
    }
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
      'motorway' || 'motorway_link' || 'trunk' || 'trunk_link' => 3.5,
      'primary' || 'primary_link' || 'secondary' || 'secondary_link' => 3.0,
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
  String get _urlDuMode => _urlPourMode(_modeCarte);

  String _urlPourMode(_ModeCarte mode) => switch (mode) {
    _ModeCarte.sombre => _urlTuilesSombre,
    _ModeCarte.satellite => _urlTuilesSatellite,
    _ModeCarte.claire => _urlTuiles,
    _ModeCarte.positron => _urlTuilesPositron,
    _ModeCarte.darkMatter => _urlTuilesDarkMatter,
    _ModeCarte.voyager => _urlTuilesVoyager,
    _ModeCarte.topo => _urlTuilesTopo,
  };

  /// Identifiant court et stable d'une famille de fond : deux modes qui
  /// partagent exactement les mêmes tuiles doivent renvoyer la même famille
  /// (c'est le cas de « claire » et « sombre », tous deux en OSM).
  String _familleFond(_ModeCarte mode) => switch (mode) {
    _ModeCarte.claire || _ModeCarte.sombre => 'osm',
    _ModeCarte.satellite => 'esri-satellite',
    _ModeCarte.positron => 'carto-positron',
    _ModeCarte.darkMatter => 'carto-dark-matter',
    _ModeCarte.voyager => 'carto-voyager',
    _ModeCarte.topo => 'opentopomap',
  };

  /// Fournisseur de tuiles pour le mode demandé. Un fournisseur FMTC DISTINCT
  /// par famille de fond : c'est ce qui force le cache d'images à recharger les
  /// tuiles lors d'une bascule de carte (FMTC #183). La distinction est assurée
  /// par un en-tête factice propre à la famille (ignoré par les serveurs de
  /// tuiles) ; le reste de la configuration demeure identique.
  TileProvider _providerTuiles(_ModeCarte mode) {
    if (!kIsWeb && fmtcSucceeded) {
      final famille = _familleFond(mode);
      return _providersFmtc.putIfAbsent(
        famille,
        () => FMTCTileProvider(
          stores: const {'kinshasa': BrowseStoreStrategy.readUpdateCreate},
          loadingStrategy: BrowseLoadingStrategy.cacheFirst,
          headers: {'x-kinflow-fond': famille},
          // Une tuile introuvable ou en erreur réseau renverrait une
          // exception remontant en erreur Flutter non gérée. On renvoie
          // une tuile transparente à la place : le rendu affiche le fond
          // gris via tileBuilder sans jamais planter.
          errorHandler: (_) => TileProvider.transparentImage,
        ),
      );
    }
    return _providerReseau ??= NetworkTileProvider(silenceExceptions: true);
  }

  Widget _tuileDeBase(_ModeCarte mode) {
    return TileLayer(
      urlTemplate: _urlPourMode(mode),
      userAgentPackageName: 'com.kinflow.kinflow',
      tileProvider: _providerTuiles(mode),
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
            child: Icon(Icons.cloud_off, color: Colors.grey.shade600, size: 14),
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
              0.2126,
              0.7152,
              0.0722,
              0,
              0,
              0.2126,
              0.7152,
              0.0722,
              0,
              0,
              0.2126,
              0.7152,
              0.0722,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
            ]),
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix([
                0.6,
                0,
                0,
                0,
                0,
                0,
                0.6,
                0,
                0,
                0,
                0,
                0,
                0.6,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
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

  /// Épingle classique (punaise) : la même que la prévisualisation et le
  /// bouton « Épingler ». Sa pointe en bas sert d'ancre géographique.
  Widget _construireEpingle() {
    return const Icon(
      Icons.push_pin,
      size: 34,
      color: _couleurEpinglette,
    );
  }

  /// Icône de localisation standard (« goutte d'eau ») : le symbole habituel
  /// de position sur les téléphones. Utilisée pour la position de l'utilisateur
  /// et le lieu recherché.
  Widget _construireGoutte(Color couleur) {
    return Icon(Icons.location_on, size: 46, color: couleur);
  }

  /// Étape « Ajouter à l'itinéraire » : un pin ambre numéroté de son rang dans
  /// le parcours, clairement différent du point vert de la destination et de
  /// l'épingle rouge.
  Widget _construireEtape(int numero) {
    return CustomPaint(
      size: const Size(50, 50),
      painter: PeintreEtape(KinColors.accent, '$numero'),
    );
  }

  /// Taille de l'icône de prévisualisation pendant la pose d'un lieu
  /// personnel : légèrement agrandie par rapport au badge ancré (30) pour
  /// rester bien visible au centre pendant qu'on vise le point.
  static const double _taillePoseLieu = 40;

  /// Zoom en dessous duquel les badges ancrés des lieux personnels (maison,
  /// travail) disparaissent de la carte. Fortement dézoomés, ces petits repères
  /// individuels n'ont plus leur place à l'échelle de la ville et ne feraient
  /// qu'encombrer la vue. Aligné sur le seuil d'apparition des POIs
  /// ([zoomMinPois]) : badges et POIs réagissent au même niveau, la transition
  /// est visuellement cohérente. Masquer aussi le badge épinglé en cours de
  /// destination (maison/travail) relève d'un choix produit différent — ici on
  /// ne masque que les deux badges ancrés.
  static const double _zoomMinLieuxPersonnels = 14.0;

  /// Vrai quand les badges ancrés des lieux personnels (maison, travail)
  /// restent visibles au zoom donné. En dessous de [_zoomMinLieuxPersonnels]
  /// (dézoom prononcé), ils sont masqués, exactement comme les POIs autour du
  /// même seuil.
  bool _lieuxPersonnelsVisibles(double zoom) => zoom >= _zoomMinLieuxPersonnels;

  /// Vert de la famille POI, commun à tous les badges de lieu personnel.
  static const Color _vertLieuPersonnel = Color(0xFF00B050);

  /// Icône qui distingue les deux lieux personnels : la maison et le travail
  /// partagent EXACTEMENT le même badge, seul ce pictogramme change.
  static IconData _iconeLieuPersonnel(TypeLieuPose type) =>
      type == TypeLieuPose.maison ? Icons.home : Icons.work;

  /// Badge d'un lieu personnel (maison ou travail) : le même badge que les
  /// POIs — pastille blanche bordée de vert, icône verte — avec un faible
  /// encombrement sur la carte. Il sert à la fois de prévisualisation pendant
  /// la pose, de domicile posé et de lieu de travail posé ; [icone] est le SEUL
  /// élément qui distingue la maison du travail. [taille] : la pose de lieu
  /// emploie la version agrandie [_taillePoseLieu] pour rester visible au
  /// centre.
  Widget _construireBadgeLieu(IconData icone, {double taille = 30}) {
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: _vertLieuPersonnel, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Icon(icone, color: _vertLieuPersonnel, size: taille * 0.52),
    );
  }

  /// Badge d'un [type] de lieu personnel (maison ou travail) à la [taille]
  /// demandée : même code pour les deux, seul le pictogramme diffère.
  Widget _construireLieu(TypeLieuPose type, {double taille = 30}) =>
      _construireBadgeLieu(_iconeLieuPersonnel(type), taille: taille);

  /// Distance maximale (mètres) entre un point de la carte (destination,
  /// lieu recherché) et un lieu personnel enregistré pour considérer qu'ils
  /// désignent le même endroit : son BADGE remplace alors le pin vert.
  /// Tolérance volontairement large : l'arrivée d'un itinéraire est parfois
  /// recalée sur la chaussée à côté du bâtiment où le badge est ancré.
  static const double _seuilCoincidenceLieuM = 50;

  /// Si [point] tombe (à [_seuilCoincidenceLieuM] près) sur la maison ou le
  /// lieu de travail enregistré, renvoie son type — autrement null.
  TypeLieuPose? _typeLieuPersonnel(LatLng? point) {
    if (point == null) return null;
    final maison = widget.pointMaison;
    if (maison != null &&
        distanceMetresHaversine(maison, point) < _seuilCoincidenceLieuM) {
      return TypeLieuPose.maison;
    }
    final travail = widget.pointTravail;
    if (travail != null &&
        distanceMetresHaversine(travail, point) < _seuilCoincidenceLieuM) {
      return TypeLieuPose.travail;
    }
    return null;
  }

  /// Le lieu personnel correspondant à la destination affichée sur la carte
  /// (destination d'itinéraire, sinon lieu recherché), ou null.
  TypeLieuPose? get _typeLieuDestination =>
      _typeLieuPersonnel(widget.pointDestination ?? widget.lieuRecherche);

  /// Marqueur d'une destination (itinéraire ou lieu recherché) : son BADGE
  /// rond si le point est une maison ou le lieu de travail, sinon le pin vert
  /// habituel.
  Widget _construireMarqueurDestination(LatLng point) {
    final type = _typeLieuPersonnel(point);
    return type == null
        ? _construireGoutte(_vertLieuPersonnel)
        : _construireLieu(type);
  }

  /// Vrai quand [a] et [b] désignent quasiment le même point (~10 m) : deux
  /// marqueurs ne doivent pas s'empiler l'un sur l'autre au même endroit.
  bool _coincide(LatLng? a, LatLng? b) {
    if (a == null || b == null) return false;
    return distanceMetresHaversine(a, b) < 10;
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
    final etapes = widget.pointEtape;
    if (etapes.isEmpty) return const [];

    final raccords = <Polyline>[];
    for (final etape in etapes) {
      // Pas de pointillés quand un tracé passe sous le marqueur. L'étape
      // ajoutée révise l'itinéraire, dont la polyline est recalée au plus près
      // du point projeté sur la chaussée ; et même sans tracé itinéraire à
      // proximité, une rue du réseau déjà chargé sous le marqueur suffit à
      // considérer l'étape « sur route ».
      if (pointsItineraire != null) {
        final proche = _projeterSurPolyligne(etape, pointsItineraire);
        if (distanceMetresHaversine(etape, proche) < _seuilRaccordEtapeMetres) {
          continue;
        }
      }
      if (_estSurReseauRoutier(etape, _seuilRaccordEtapeMetres)) {
        continue;
      }
      if (pointsItineraire == null) continue;

      final proche = _projeterSurPolyligne(etape, pointsItineraire);
      raccords.add(
        Polyline(
          points: [etape, proche],
          strokeWidth: 3.2,
          color: Colors.black.withValues(alpha: _fondSombre ? 0.95 : 0.8),
          pattern: StrokePattern.dotted(),
          strokeCap: StrokeCap.round,
        ),
      );
    }
    return raccords;
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
      final t =
          (((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
                  len2)
              .clamp(0.0, 1.0);
      final proj = LatLng(a.latitude + t * dy, a.longitude + t * dx);
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

      final styleBase = DefaultTextStyle.of(context).style.copyWith(
        fontSize: BoutonAction.tailleTexte,
        fontWeight: FontWeight.w600,
      );

      final largeur2 = BoutonAction.largeurPour(
        'Supprimer',
        styleBase,
        textScaler,
      );

      final largeurDetails = BoutonAction.largeurPour(
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
            (widget.onVoirDetails != null ? largeurDetails + 8 : 0) + largeur2;
      } else {
        final largeur1 = BoutonAction.largeurPour(
          widget.libelleActionPrincipale,
          styleBase,
          textScaler,
        );

        decalageBoutons = (largeur2 - largeur1) / 2;

        largeurBoutons = largeur1 + 8 + largeur2;
      }

      hauteurBoutons = BoutonAction.hauteurPour(styleBase, textScaler);
    }

    // Marqueurs « avant » le point bleu : les POIs, calculés UNE fois par
    // build (projections écran), puis injectés dans le calque vivant qui se
    // reconstruit seul à chaque trame. Le point bleu est peint EN DESSOUS
    // des marqueurs de destination mais AU-DESSUS des POIs.
    final marqueursAvantBleu = <Marker>[
      for (final poi in _poisVisibles()) _marqueurPoi(poi),
    ];

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
              // Un glissement (un doigt comme deux) ne coupe PLUS le suivi
              // navigation : il le suspend le temps du geste, puis le
              // relâchement attend un réel déplacement avant de recentrer
              // (cf. [_finGesteManuel]). Le pincement à deux doigts est un
              // zoom : le suivi adopte le nouveau zoom dans
              // [_surEvenementCarte].
              if (_longPressDezoomActif) {
                // L'appui long avait déjà lancé un dézoom : le doigt bouge,
                // le geste devient un glissement ordinaire, le dézoom choisi
                // reste la cible du suivi.
                _longPressDezoomActif = false;
                _navZoomCible = widget.mapController.camera.zoom;
                _suiviEnAttenteMouvement = true;
              }
            },
            onPointerUp: (e) {
              if (_pointersDown > 0) _pointersDown--;
              _departsPointeurs.remove(e.pointer);
              _annulerLongPress();
              // Défensif : plus aucun doigt sur l'écran, aucun geste ne peut
              // être en cours. Un événement de fin manqué (annulation système,
              // fin de pincement en deux temps…) ne doit pas laisser le suivi
              // navigation suspendu indéfiniment.
              if (_departsPointeurs.isEmpty && _gestesActifs > 0) {
                _gestesActifs = 0;
                _finGesteManuel();
              }
            },
            onPointerCancel: (e) {
              if (_pointersDown > 0) _pointersDown--;
              _departsPointeurs.remove(e.pointer);
              _annulerSansTap();
              if (_departsPointeurs.isEmpty && _gestesActifs > 0) {
                _gestesActifs = 0;
                _finGesteManuel();
              }
            },
            child: FlutterMap(
              mapController: widget.mapController,

              options: MapOptions(
                initialCenter: const LatLng(-4.325, 15.322),

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
                  PolylineLayer(
                    polylines: [
                      ..._polylignesTrafic,
                      ..._polylignesItineraire,
                      // Raccord en pointillés noirs d'une étape hors réseau routier.
                      ..._raccordEtape,
                    ],
                  ),

                // Calque VIVANT du point bleu : pendant le suivi navigation le
                // ticker fait glisser le point avec la caméra lissée, et pendant
                // l'animation du pin le tween l'interpole. Reconstruire SEUL ce
                // sous-arbre à chaque trame (marqueurs + pointillés de départ)
                // laisse les 600→1600 polylignes de trafic intactes : c'était leur
                // re-construction par setState par trame qui faisait les ratés.
                ValueListenableBuilder<LatLng?>(
                  valueListenable: _pointBleuNotifier,
                  builder: (context, pointBleu, _) => Stack(
                    children: [
                      // Pointillés de départ : ancrés au point bleu vivant,
                      // au-dessus du tracé pour rester visibles même si le pin
                      // s'intersecte avec l'itinéraire.
                      if (_polylignesRaccordDepart.isNotEmpty)
                        PolylineLayer(polylines: _polylignesRaccordDepart),
                      MarkerLayer(
                        markers: [
                          ...marqueursAvantBleu,

                          // Amis(es) : position partagée en direct. Placés
                          // au-dessus des POIs mais sous le point bleu et les
                          // destinations, pour ne jamais masquer le guidage.
                          for (final ami in widget.amis) _marqueurAmi(ami),

                          // Ordre de peinture = ordre d'empilement : ce marqueur
                          // est AVANT tous les marqueurs de destination (vert,
                          // épingle), il passe donc toujours EN DESSOUS d'eux
                          // quand ils se recouvrent, jamais au-dessus.
                          if (widget.positionActuelle != null)
                            Marker(
                              point:
                                  pointBleu ??
                                  (_displayedPosition ??
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
                              // Isolé dans un RepaintBoundary : le point bleu ne
                              // se recolle plus en copie fantôme au-dessus/en
                              // dessous de lui-même quand la caméra pivote et
                              // zoome en même temps pendant la pose maison/travail
                              // (doublon visible sur le rendu Web).
                              child: RepaintBoundary(
                                child: _construireGoutte(Colors.blueAccent),
                              ),
                            ),

                          // Lieu recherché : BADGE du lieu personnel si c'est la maison
                          // ou le travail, sinon le pin vert habituel. Quand la
                          // destination de l'itinéraire occupe déjà le même point, seul
                          // son marqueur est dessiné (pas de doublon).
                          if (widget.lieuRecherche != null &&
                              !_coincide(
                                widget.lieuRecherche,
                                widget.pointDestination,
                              ))
                            Marker(
                              point: widget.lieuRecherche!,

                              width: 50,

                              height: 50,

                              // Reste droit pendant la rotation de la carte.
                              rotate: true,

                              child: _construireMarqueurDestination(
                                widget.lieuRecherche!,
                              ),
                            ),

                          // Destination de l'itinéraire : son marqueur vert reste en
                          // place même quand un autre lieu est ensuite recherché. Si la
                          // destination est la maison ou le travail, c'est leur BADGE
                          // rond (icône domicile/mallette) qui s'affiche, pas un pin.
                          if (widget.pointDestination != null)
                            Marker(
                              point: widget.pointDestination!,

                              width: 50,

                              height: 50,

                              rotate: true,

                              child: _construireMarqueurDestination(
                                widget.pointDestination!,
                              ),
                            ),

                          // Étapes obligatoires de l'itinéraire : un pin ambre
                          // numéroté par étape, dans l'ordre du parcours, distinct du
                          // point vert de la destination qui les suit toutes.
                          for (var i = 0; i < widget.pointEtape.length; i++)
                            Marker(
                              point: widget.pointEtape[i],
                              width: 50,
                              height: 50,
                              rotate: true,
                              child: _construireEtape(i + 1),
                            ),

                          // Lieux personnels posés (domicile, travail) : leurs icônes restent
                          // ancrées sur ces lieux, collées à la carte (elles suivent les
                          // déplacements et rotations), tant que l'utilisateur ne les
                          // change ou ne les supprime pas. Masquées pendant une nouvelle
                          // pose, remplacées par l'icône de prévisualisation au centre.
                          // Leur TAILLE suit le zoom ([_BadgeAncrageZoom] lit la caméra) :
                          // gros en zoom in, petit puis invisible en zoom out.
                          if (widget.pointMaison != null &&
                              _poseLieuActif != TypeLieuPose.maison &&
                              _typeLieuDestination != TypeLieuPose.maison)
                            Marker(
                              key: const ValueKey('badge_maison'),
                              point: widget.pointMaison!,
                              width: _BadgeAncrageZoom.tailleBoite,
                              height: _BadgeAncrageZoom.tailleBoite,
                              // Reste droit pendant la rotation de la carte.
                              rotate: true,
                              // Le badge change de taille à chaque
                              // mouvement/zoom de caméra. Isolé dans un
                              // RepaintBoundary, il ne laisse plus filer de
                              // copie fantôme décalée au-dessus/en dessous
                              // pendant l'animation de pose (doublon Web).
                              child: RepaintBoundary(
                                child: _BadgeAncrageZoom(
                                  construire: (taille) => _construireLieu(
                                    TypeLieuPose.maison,
                                    taille: taille,
                                  ),
                                ),
                              ),
                            ),

                          if (widget.pointTravail != null &&
                              _poseLieuActif != TypeLieuPose.travail &&
                              _typeLieuDestination != TypeLieuPose.travail)
                            Marker(
                              key: const ValueKey('badge_travail'),
                              point: widget.pointTravail!,
                              width: _BadgeAncrageZoom.tailleBoite,
                              height: _BadgeAncrageZoom.tailleBoite,
                              // Reste droit pendant la rotation de la carte.
                              rotate: true,
                              // Publie son résultat dans SA propre couche puis
                              // repaint atomiquement : pendant le mouvement/
                              // zoom/rotation qui accompagne la pose, le badge
                              // ne laisse plus de copie fantôme au-dessus/en
                              // dessous de lui-même (doublon Web).
                              child: RepaintBoundary(
                                child: _BadgeAncrageZoom(
                                  construire: (taille) => _construireLieu(
                                    TypeLieuPose.travail,
                                    taille: taille,
                                  ),
                                ),
                              ),
                            ),

                          if (widget.epingle != null)
                            Marker(
                              point: widget.epingle!,

                              width: 40,

                              height: 40,

                              // Reste droit pendant la rotation de la carte.
                              rotate: true,

                              child: _construireEpingle(),
                            ),

                          // Le point vert de destination reste toujours visible,
                          // y compris pendant un itinéraire actif. Sauf quand les
                          // actions sont attachées à l'épingle rouge : l'épingle
                          // reste un repère rouge, on ne la recouvre jamais de vert.
                          if (widget.pointActions != null &&
                              !widget.seulementSupprimer &&
                              !widget.actionsSurEpingle &&
                              !widget.actionsSurAmi &&
                              widget.pointActions != widget.epingle &&
                              widget.pointActions != widget.lieuRecherche)
                            Marker(
                              point: widget.pointActions!,

                              width: 50,

                              height: 50,

                              // Reste droit pendant la rotation de la carte.
                              rotate: true,

                              child: _construireEpingle(),
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
                  // Isolée dans sa propre frontière de peinture, elle ne
                  // laisse plus filer de copie fantôme décalée au-dessus/en
                  // dessous d'elle-même pendant la pose d'un lieu ou d'une
                  // épingle (doublon Web signalé sur l'épingle flottante).
                  child: RepaintBoundary(
                    child: IgnorePointer(
                      child: const Icon(
                        Icons.push_pin,
                        size: 52,
                        color: _couleurEpinglette,
                      ),
                    ),
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

        if (_poseLieuActif != null && _fmtcReady)
          Positioned.fill(
            child: Stack(
              children: [
                // Icône de prévisualisation au centre de l'écran : elle ne
                // capte aucun toucher — la carte reste libre à pivoter et à
                // se déplacer dessous pour viser le lieu (maison ou travail).
                // Elle change de TAILLE à chaque mouvement/zoom de caméra,
                // comme les badges. Isolée dans un RepaintBoundary, elle ne
                // laisse plus filer de copie fantôme décalée au-dessus/en
                // dessous d'elle-même pendant cette animation de pose
                // (doublon Web « deux épingles » signalé sur ce calque).
                Center(
                  child: RepaintBoundary(
                    child: IgnorePointer(
                      child: _construireLieu(
                        _poseLieuActif!,
                        taille: _taillePoseLieu,
                      ),
                    ),
                  ),
                ),
                // Bouton « Poser » sous l'icône, « Annuler » encore en
                // dessous — tous deux en gabarit réduit.
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 90),
                      BoutonPoser(onPressed: _poserLieu, compact: true),
                      const SizedBox(height: 6),
                      _boutonAnnulerLieu(),
                    ],
                  ),
                ),
              ],
            ),
          ),

        if (_fmtcReady && _poseLieuActif == null)
          Positioned(
            left: 8,
            bottom: 16,
            child: AnimatedOpacity(
              opacity: _boutonsVisibles ? 1.0 : _opaciteBoutonsInactifs,
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
              opacity: _boutonsVisibles ? 1.0 : _opaciteBoutonsInactifs,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              // Le bouton des cartes change d'opacité en fondu (AnimatedOpacity)
              // à chaque affichage/masquage des contrôles : isolé dans son
              // RepaintBoundary, il n'imprime plus de copie fantôme floue
              // au-dessus/en dessous de lui-même pendant ces fondus (doublon
              // Web signalé sur ce bouton).
              child: RepaintBoundary(
                child: BoutonModeCarte(onPressed: _ouvrirMenuCartes),
              ),
            ),
          ),

        if (_fmtcReady && _modeCarte == _ModeCarte.satellite)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
          const Center(child: CircularProgressIndicator()),

        if (_downloadProgress > 0 && _downloadProgress < 100)
          Positioned(
            bottom: 8,
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    style: const TextStyle(color: Colors.white, fontSize: 11),
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

/// Badge maison/travail ANCRÉ à taille SUIVANT LE ZOOM : il lit la caméra dans
/// son build ([MapCamera.of], fournie par le modèle hérité de FlutterMap), donc
/// il est reconstruit à chaque changement de zoom/déplacement/rotation de la
/// carte. Sa taille à l'écran suit ainsi le zoom — gros quand on zoome,
/// minuscule puis INVISIBLE quand on dézoome — au lieu d'une grosse icône
/// figée qui reste plantée sur la carte même en dézoom maximal.
class _BadgeAncrageZoom extends StatelessWidget {
  const _BadgeAncrageZoom({required this.construire});

  /// Fabrique le badge voulu (maison ou travail) à la taille demandée.
  final Widget Function(double taille) construire;

  /// Zoom de référence : à ce niveau le badge affiche sa [tailleBase].
  static const double zoomReference = 17;

  /// Taille du badge au zoom de référence (px, gabarit POI actuel).
  static const double tailleBase = 30;

  /// Sous cette taille à l'écran (px) le badge disparaît complètement : le
  /// dézoom fait « petit petit jusqu'à disparaître ».
  static const double tailleMinVisible = 7;

  /// Taille maximale (px) : le badge ne devient pas absurde en très fort zoom.
  static const double tailleMax = 72;

  /// Largeur de la boîte d'ancrage du marqueur : la taille MAX, pour que le
  /// badge (centré dans la boîte) puisse grandir jusqu'à [tailleMax] sans
  /// être rogné, et que le point géographique reste son centre.
  static const double tailleBoite = tailleMax;

  @override
  Widget build(BuildContext context) {
    final taille = _taillePourZoom(MapCamera.of(context).zoom);
    if (taille <= 0) return const SizedBox.shrink();
    return Align(alignment: Alignment.center, child: construire(taille));
  }

  /// Taille d'affichage pour un zoom donné : double à chaque niveau de zoom
  /// au-dessus de [zoomReference], réduite de moitié en dessous, 0 (invisible)
  /// sous [tailleMinVisible].
  static double _taillePourZoom(double zoom) {
    final taille = tailleBase * pow(2, zoom - zoomReference);
    if (taille < tailleMinVisible) return 0;
    return min(taille, tailleMax);
  }
}

/// Pin vert d'un ami(e) partageant sa position : une goutte `location_on`
/// verte, l'avatar animal de l'ami(e) logé dans la tête du pin, son prénom
/// sur une petite étiquette juste en dessous, puis l'âge de sa dernière
/// position connue (« il y a 15 minutes », « il y a 2 jours »…). Ni le pin ni
/// les étiquettes ne captent les gestes : la carte reste libre.
class _MarqueurAmi extends StatelessWidget {
  const _MarqueurAmi({required this.ami});

  final AmiPosition ami;

  /// Vert du pin : la couleur principale de KinFlow, pour bien distinguer
  /// l'ami(e) qui partage sa position des autres repères de la carte.
  static const Color _vert = KinColors.primary;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Le pin vert « goutte d'eau », avec l'avatar dans sa tête.
          SizedBox(
            width: 52,
            height: 52,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                const Icon(
                  Icons.location_on,
                  size: 52,
                  color: _vert,
                  shadows: [
                    Shadow(
                      color: Colors.black38,
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                Positioned(
                  top: 7,
                  child: Container(
                    padding: const EdgeInsets.all(1),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: AvatarAnimalWidget(taille: 26, avatarId: ami.avatar),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: _vert,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              ami.nom,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          // Âge de la dernière position enregistrée : visible même quand le
          // téléphone de l'ami(e) est éteint (position « figée » côté serveur).
          if (ami.majA != null) ...[
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.schedule, size: 10, color: _vert),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      tempsRelatif(ami.majA!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: _vert,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
