import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/models/road_segment.dart';
import 'package:kinflow/services/offline_graph_codec.dart';
import 'package:latlong2/latlong.dart';

List<RoadSegment> _jeu() => [
      RoadSegment(
        id: 0,
        nom: 'Boulevard du 30 Juin',
        classe: 'primary',
        points: const [
          LatLng(-4.3200, 15.2900),
          LatLng(-4.3185, 15.2920),
          LatLng(-4.3170, 15.2940),
        ],
      ),
      RoadSegment(
        id: 1,
        nom: 'Boulevard du 30 Juin',
        classe: 'primary',
        points: const [
          LatLng(-4.3170, 15.2940),
          LatLng(-4.3155, 15.2960),
        ],
      ),
      RoadSegment(
        id: 2,
        nom: 'Avenue des Huileries',
        classe: 'residential',
        points: const [
          LatLng(-4.3180, 15.2900),
          LatLng(-4.3180, 15.2940),
        ],
      ),
    ];

void main() {
  test('roundtrip : encodage puis décodage sans perte', () {
    final octets = GrapheCodec.encoderSegments(_jeu());
    final brut = GrapheCodec.decoderHorsLigne(octets);

    expect(brut.nombreSegments, 3);
    expect(brut.noms.length, 2, reason: 'dict des noms interné');
    expect(brut.classes.length, 2, reason: 'dict des classes interné');

    final seg0 = brut.materiel(0);
    expect(seg0.nom, 'Boulevard du 30 Juin');
    expect(seg0.classe, 'primary');
    expect(seg0.points.length, 3);
    expect(seg0.points.first.latitude, closeTo(-4.32, 1e-7));
    expect(seg0.points.last.longitude, closeTo(15.294, 1e-7));

    final seg1 = brut.materiel(1);
    expect(seg1.nom, 'Boulevard du 30 Juin', reason: 'dict partagé');
    expect(seg1.classe, 'primary');
  });

  test('bbox couvre et extraction par zone', () {
    final octets = GrapheCodec.encoderSegments(_jeu());
    final brut = GrapheCodec.decoderHorsLigne(octets);

    expect(brut.latMin, closeTo(-4.32, 1e-7));
    expect(brut.lonMax, closeTo(15.296, 1e-7));

    const centre = LimitesGraphe(
      nord: -4.315,
      sud: -4.322,
      est: 15.297,
      ouest: 15.289,
    );
    expect(brut.couvre(centre), isTrue);

    const dehors = LimitesGraphe(
      nord: -4.00,
      sud: -4.10,
      est: 15.30,
      ouest: 15.20,
    );
    expect(brut.couvre(dehors), isFalse);

    final dans = brut.segmentsDans(centre);
    expect(dans.length, 3);
  });

  test('magic et version corrompus rejetés', () {
    final octets = GrapheCodec.encoderSegments(_jeu());

    final magicCasse = Uint8List.fromList(octets);
    magicCasse[0] = 0x00;
    expect(() => GrapheCodec.decoderHorsLigne(magicCasse),
        throwsFormatException);

    final versionCasse = Uint8List.fromList(octets);
    versionCasse[5] = 0xFF;
    expect(() => GrapheCodec.decoderHorsLigne(versionCasse),
        throwsFormatException);
  });
}