import 'package:flutter_compass/flutter_compass.dart';
import 'dart:async';

import 'diagnostics_service.dart';

class CompassService {

  static bool _indisponibiliteSignalee = false;

  Stream<double?> get direction {

    final evenements = FlutterCompass.events;

    if (evenements == null) {

      if (!_indisponibiliteSignalee) {
        _indisponibiliteSignalee = true;
        Journal.a('BOUSSOLE',
            'Capteur de boussole indisponible sur cet appareil');
      }

      // Boussole indisponible (par ex. sur le web).
      return const Stream<double?>.empty();

    }

    Journal.i('BOUSSOLE', 'Flux de boussole ouvert');

    return evenements.map((event) {

      return event.heading;

    });

  }

  void dispose() {
    // nettoyage
  }

}
