import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart' show LatLng;

/// Constantes partagées de la carte, communes à l'écran principal et au
/// widget de carte : zoom minimum et vue « Afrique » d'attente.

/// Zoom le plus bas autorisé. En dessous, la carte ne charge ni tuiles ni
/// polylignes : elle reste désespérément vide et le zoom n'apporte rien à
/// l'utilisateur.
const double zoomMinGlobal = 8.0;

/// Bornes de la vue « Afrique » affichée tant qu'aucune position n'est connue.
final LatLngBounds bornesAfrique = LatLngBounds(
  const LatLng(-35.0, -18.0),
  const LatLng(37.5, 52.0),
);

/// Zone couverte par l'application : Kinshasa et sa périphérie.
///
/// L'app est une application de la ville : hors de ces bornes, une recherche
/// ne renvoie rien (voir [estDansKinshasa]). Les limites reprennent celles du
/// `viewbox` Nominatim utilisé depuis toujours par la recherche, pour qu'il
/// n'y ait qu'une seule définition de « Kinshasa » dans le projet.
const double kinshasaSud = -5.20;
const double kinshasaNord = -3.90;
const double kinshasaOuest = 15.00;
const double kinshasaEst = 16.45;

/// Vrai si le point appartient à la zone couverte (Kinshasa).
bool estDansKinshasa(double latitude, double longitude) =>
    latitude >= kinshasaSud &&
    latitude <= kinshasaNord &&
    longitude >= kinshasaOuest &&
    longitude <= kinshasaEst;

/// Zone de recherche au format `viewbox` de Nominatim : gauche,haut,droite,bas.
const String viewboxKinshasa =
    '$kinshasaOuest,$kinshasaNord,$kinshasaEst,$kinshasaSud';

/// Vitesse maximale (m/s) jugée plausible pendant que l'utilisateur
/// VISUALISE son trajet sur la carte (≈ 80 km/h).
///
/// On ne roule pas à grande vitesse en lisant son itinéraire à l'écran : un
/// utilisateur qui suit son point bleu est à pied, dans un trafic dense, ou
/// arrêté. Au-delà de ce seuil, une mesure GPS est traitée comme peu crédible
/// (saut de position après une coupure, fix aberrant) et non comme un vrai
/// déplacement. Le plafond borne :
///
///  - la vitesse de rattrapage du point bleu (un recadrage de 40 m glisse sur
///    la carte au lieu de la traverser d'un coup) ;
///  - la vitesse prise en compte par le zoom adaptatif de la navigation.
///
/// C'est le seul endroit à modifier pour rendre le suivi plus (60 km/h) ou
/// moins (100 km/h) permissif.
const double vitesseVisualisationMaxMetresParSeconde = 80.0 / 3.6;

/// Fournisseur des tuiles de fond de carte.
///
/// L'app utilise **MapTiler Cloud** quand une clé est fournie : le rendu est
/// bien plus proche de Google Maps que les tuiles OSM brutes (libellés,
/// couleurs, densité d'informations). Sans clé, elle retombe automatiquement
/// sur OpenStreetMap : rien ne casse, le fond est simplement plus austère.
///
/// Mise en place (5 minutes) :
///  1. Créer un compte gratuit sur https://cloud.maptiler.com/ (le plan
///     gratuit suffit largement pour une app personnelle) ;
///  2. copier sa clé API depuis le tableau de bord (« API keys ») ;
///  3. la coller ci-dessous, ou compiler avec
///     `--dart-define=MAPTILER_KEY=ta_cle` (recommandé pour ne pas la laisser
///     dans le dépôt : la valeur de compilation écrase celle du fichier) :
///
/// ```sh
/// flutter run --dart-define=MAPTILER_KEY=ta_cle
/// flutter build apk --dart-define=MAPTILER_KEY=ta_cle
/// ```
///
/// Styles disponibles (identifiants MapTiler) : `streets-v4` (le plus proche
/// de Google Maps, utilisé par défaut), `bright-v2`, `base-v4`,
/// `outdoor-v4`, `topo-v4`, `satellite-v4`… Les variantes sombres sont
/// suffixées `-dark` (ex. `streets-v4-dark`).
///
/// À savoir : les tuiles hors-ligne déjà téléchargées (cache FMTC, archive
/// `kinshasa.fmtc`) sont indexées par URL. En passant d'OSM à MapTiler, il
/// faut relancer un téléchargement hors-ligne pour retrouver le fond
/// détaillé sans connexion ; le cache OSM existant devient simplement
/// inutilisé.
abstract final class CarteConfig {
  /// Valeur de remplacement : si elle est encore là, l'app utilise OSM.
  static const String _clePlaceholder = 'MET_TON_ICI_LA_CLE_MAPTILER';

  /// Clé API MapTiler. Peut être surchargée à la compilation
  /// (`--dart-define=MAPTILER_KEY=...`), sinon la clé ci-dessous est utilisée.
  static const String cleMapTiler = String.fromEnvironment(
    'MAPTILER_KEY',
    defaultValue: 'p32Py525U7FgrDVEV6uo',
  );

  /// Style « clair » : Streets v4, le rendu le plus proche de Google Maps.
  /// Remplacer par `bright-v2` pour un fond plus lumineux/contrasté.
  static const String styleClair = 'streets-v4';

  /// Style « sombre » : même cartographie, palette nuit.
  static const String styleSombre = 'streets-v4-dark';

  /// Satellite + libellés (nom des quartiers, rues) : plus lisible qu'une
  /// image brute, comme la vue satellite de Google Maps.
  static const String styleSatellite = 'hybrid';

  /// Minimaliste clair, équivalent MapTiler de « Positron » (CARTO).
  static const String styleMinimal = 'base-v4';

  /// Minimaliste sombre, équivalent de « Dark Matter » (CARTO).
  static const String styleMinimalSombre = 'base-v4-dark';

  /// Coloré/vivant, équivalent de « Voyager » (CARTO).
  static const String styleVif = 'bright-v2';

  /// Relief et courbes de niveau, équivalent de l'OpenTopoMap.
  static const String styleTopo = 'topo-v4';

  /// Vrai quand une clé MapTiler exploitable a été fournie.
  static bool get mapTilerActif =>
      cleMapTiler.isNotEmpty && cleMapTiler != _clePlaceholder;

  /// Fond de secours libre, sans clé ni quota.
  static const String urlOpenStreetMap =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// `/256/` force des tuiles de 256 px. Sans ce segment, MapTiler sert du
  /// 512 px : ~3× plus lourd (130 Ko contre 40 Ko pour une tuile de Kinshasa)
  /// pour le même nombre de requêtes, ce qui compte sur les forfaits data.
  /// Retirer `/256/` si l'on préfère la netteté « retina » au prix du débit.
  static String _urlMapTiler(String style) =>
      'https://api.maptiler.com/maps/$style/256/{z}/{x}/{y}.png?key=$cleMapTiler';

  /// URL des tuiles du fond clair (MapTiler si configuré, sinon OSM).
  static String get urlFondClair =>
      mapTilerActif ? _urlMapTiler(styleClair) : urlOpenStreetMap;

  /// URL des tuiles du fond sombre. Sans MapTiler, on réutilise OSM : le
  /// widget applique alors son filtre d'assombrissement habituel.
  static String get urlFondSombre =>
      mapTilerActif ? _urlMapTiler(styleSombre) : urlOpenStreetMap;

  /// URL du style MapTiler demandé, ou [secours] (fournisseur historique)
  /// quand aucune clé n'est configurée. Tous les fonds du menu « Cartes »
  /// passent par ici : une seule clé, un seul fournisseur, un rendu cohérent.
  static String urlPourStyle(String style, String secours) =>
      mapTilerActif ? _urlMapTiler(style) : secours;
}
