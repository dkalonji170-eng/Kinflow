import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../models/road_segment.dart';

/// Limites d'une zone demandée (uniquement des doubles, envoyable à un isolat
/// et compatible `dart run`). L'app convertit son `LatLngBounds` via
/// [LimitesGraphe.deZone].
class LimitesGraphe {
  final double nord;
  final double sud;
  final double est;
  final double ouest;

  const LimitesGraphe({
    required this.nord,
    required this.sud,
    required this.est,
    required this.ouest,
  });
}

/// Graphe routier décodé depuis l'asset hors‑ligne : réseau complet de la
/// zone embarquée, conservé sous forme compacte (listes plates) pour mémoire
/// faible et filtrage rapide au corridor sans instancier tous les objets.
class GrapheHorsLigneBrut {
  /// Boîte englobante de TOUTES les chaussées du fichier.
  final double latMin;
  final double latMax;
  final double lonMin;
  final double lonMax;

  final List<String> noms;
  final List<String> classes;

  /// Périphérique d'un segment : [segmentNom]/[segmentClasse] par segment,
  /// et ses points dans [lat]/[lon] entre les index [segmentDebut] et
  /// [segmentFin] (exclus).
  final List<int> segmentNom;
  final List<int> segmentClasse;
  final List<int> segmentDebut;
  final List<int> segmentFin;

  final List<double> lat;
  final List<double> lon;

  GrapheHorsLigneBrut({
    required this.latMin,
    required this.latMax,
    required this.lonMin,
    required this.lonMax,
    required this.noms,
    required this.classes,
    required this.segmentNom,
    required this.segmentClasse,
    required this.segmentDebut,
    required this.segmentFin,
    required this.lat,
    required this.lon,
  });

  int get nombreSegments => segmentNom.length;

  /// Vrai si le fichier couvre entièrement [zone] (avec une petite marge) :
  /// un couloir en bordure ne prend que partiellement l'asset, l'appelant
  /// bascule alors sur Overpass plutôt que de risquer un réseau troué.
  bool couvre(LimitesGraphe zone) {
    const marge = 0.002;
    return latMax >= zone.nord - marge &&
        latMin <= zone.sud + marge &&
        lonMax >= zone.est - marge &&
        lonMin <= zone.ouest + marge;
  }

  /// Segments dont la géométrie touche la boîte [zone], reconstruits en
  /// objets [RoadSegment] (mêmes champs que le cache Overpass : le Dijkstra
  /// et ses pénalités les consomment à l'identique).
  List<RoadSegment> segmentsDans(LimitesGraphe zone) {
    final resultats = <RoadSegment>[];
    for (var s = 0; s < nombreSegments; s++) {
      if (!_intersecte(s, zone)) continue;
      resultats.add(materiel(s));
    }
    return resultats;
  }

  RoadSegment materiel(int s) {
    final debut = segmentDebut[s];
    final fin = segmentFin[s];
    final points = List<LatLng>.generate(fin - debut, (i) {
      final k = debut + i;
      return LatLng(lat[k], lon[k]);
    }, growable: false);
    return RoadSegment(
      id: s,
      nom: noms[segmentNom[s]],
      classe: classes[segmentClasse[s]],
      points: points,
    );
  }

  bool _intersecte(int s, LimitesGraphe zone) {
    final debut = segmentDebut[s];
    final fin = segmentFin[s];
    var minLat = 90.0;
    var maxLat = -90.0;
    var minLon = 180.0;
    var maxLon = -180.0;
    for (var i = debut; i < fin; i++) {
      final la = lat[i];
      final lo = lon[i];
      if (la < minLat) minLat = la;
      if (la > maxLat) maxLat = la;
      if (lo < minLon) minLon = lo;
      if (lo > maxLon) maxLon = lo;
    }
    if (minLat > zone.nord || maxLat < zone.sud) return false;
    if (minLon > zone.est || maxLon < zone.ouest) return false;
    return true;
  }
}

/// Encodage/décodage du graphe routier compact embarqué dans l'APK.
///
/// Format (petit‑boutiste) :
///   magic « KRFW » (4 octets) + version uint16
///   bbox E7 : latMin, latMax, lonMin, lonMax (4 × int32)
///   dictionnaire des noms    (uint32 nombre, puis uint16 longueur + UTF‑8)
///   dictionnaire des classes (idem)
///   uint32 nombre de segments
///   par segment :
///       uint16 index nom, uint16 index classe, uint16 nombre de points
///       puis int32 latE7 × n puis int32 lonE7 × n
class GrapheCodec {
  /// « KRFW » suivi de la version. Pour contrôler le magic dans le décodeur,
  /// on utilise [_magicOctets].
  static const int _version = 1;
  static final Uint8List _magicOctets = Uint8List.fromList([0x4b, 0x52, 0x46, 0x57]);

  GrapheCodec._();

  static Uint8List encoderSegments(List<RoadSegment> segments) {
    final noms = <String, int>{};
    final classes = <String, int>{};
    int indexer(Map<String, int> table, String valeur) =>
        table.putIfAbsent(valeur, () => table.length);

    double minLat = 90;
    double maxLat = -90;
    double minLon = 180;
    double maxLon = -180;
    for (final s in segments) {
      for (final p in s.points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
      if (s.points.length > 0xffff) {
        throw ArgumentError('Segments de plus de 65535 points non supportés');
      }
      // Les dictionnaires sont remplis AVANT le passage d'écriture : les
      // index des segments doivent exister quand on écrit les listes de noms
      // et de classes, sinon celles-ci seraient vides.
      indexer(noms, s.nom);
      indexer(classes, s.classe);
    }

    final b = BytesBuilder();

    void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    void u32(int v) => b.add([
          v & 0xff,
          (v >> 8) & 0xff,
          (v >> 16) & 0xff,
          (v >> 24) & 0xff,
        ]);
    void i32(int v) => u32(v & 0xffffffff);
    void chaine(String s) {
      final octets = utf8.encode(s);
      u16(octets.length);
      b.add(octets);
    }

    b.add(_magicOctets);
    u16(_version);
    i32(_versE7(minLat));
    i32(_versE7(maxLat));
    i32(_versE7(minLon));
    i32(_versE7(maxLon));

    u32(noms.length);
    noms.forEach((valeur, _) => chaine(valeur));
    u32(classes.length);
    classes.forEach((valeur, _) => chaine(valeur));

    u32(segments.length);
    for (final s in segments) {
      u16(indexer(noms, s.nom));
      u16(indexer(classes, s.classe));
      u16(s.points.length);
      for (final p in s.points) {
        i32(_versE7(p.latitude));
        i32(_versE7(p.longitude));
      }
    }

    return b.toBytes();
  }

  /// Décodage complet : les listes plates sont remplies pour un accès
  /// séquentiel immédiat. Conçu pour tourner dans un isolat (compute).
  static GrapheHorsLigneBrut decoderHorsLigne(Uint8List octets) {
    final data = ByteData.sublistView(octets);
    var o = 0;

    int u16() {
      final v = data.getUint16(o, Endian.little);
      o += 2;
      return v;
    }

    int u32() {
      final v = data.getUint32(o, Endian.little);
      o += 4;
      return v;
    }

    int i32() {
      final v = data.getInt32(o, Endian.little);
      o += 4;
      return v;
    }

    String chaine() {
      final n = u16();
      final v = utf8.decode(data.buffer.asUint8List(
        data.offsetInBytes + o,
        n,
      ));
      o += n;
      return v;
    }

    o = 4;
    for (var i = 0; i < 4; i++) {
      if (octets[i] != _magicOctets[i]) {
        throw FormatException('Graphe hors‑ligne invalide (magic)');
      }
    }
    final version = u16();
    if (version != _version) {
      throw FormatException('Graphe hors‑ligne v$version non pris en charge');
    }

    final latMin = _depuisE7(i32());
    final latMax = _depuisE7(i32());
    final lonMin = _depuisE7(i32());
    final lonMax = _depuisE7(i32());

    final noms = <String>[];
    final nNoms = u32();
    for (var i = 0; i < nNoms; i++) {
      noms.add(chaine());
    }

    final classes = <String>[];
    final nClasses = u32();
    for (var i = 0; i < nClasses; i++) {
      classes.add(chaine());
    }

    final nSegments = u32();
    final segmentNom = <int>[];
    final segmentClasse = <int>[];
    final segmentDebut = <int>[];
    final segmentFin = <int>[];
    final lat = <double>[];
    final lon = <double>[];

    for (var s = 0; s < nSegments; s++) {
      final ni = u16();
      final ci = u16();
      final n = u16();
      segmentNom.add(ni);
      segmentClasse.add(ci);
      segmentDebut.add(lat.length);
      for (var i = 0; i < n; i++) {
        lat.add(_depuisE7(i32()));
        lon.add(_depuisE7(i32()));
      }
      segmentFin.add(lat.length);
    }

    return GrapheHorsLigneBrut(
      latMin: latMin,
      latMax: latMax,
      lonMin: lonMin,
      lonMax: lonMax,
      noms: noms,
      classes: classes,
      segmentNom: segmentNom,
      segmentClasse: segmentClasse,
      segmentDebut: segmentDebut,
      segmentFin: segmentFin,
      lat: lat,
      lon: lon,
    );
  }

  static int _versE7(double v) => (v * 1e7).round();
  static double _depuisE7(int e7) => e7 / 1e7;
}