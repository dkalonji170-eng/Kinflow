import 'package:geolocator/geolocator.dart';

import 'diagnostics_service.dart';

class LocationService {

  /// Vérifie que le service de localisation (GPS) du téléphone est actif.
  /// S'il est coupé, ouvre les réglages système pour forcer l'utilisateur
  /// à l'allumer (retourne alors false tant qu'il ne l'a pas activé).
  Future<bool> verifierActiverService() async {
    var serviceActif = await Geolocator.isLocationServiceEnabled();
    if (serviceActif) return true;

    Journal.a('POSITION', 'Service de localisation désactivé, demande d\'activation');
    await Geolocator.openLocationSettings();

    serviceActif = await Geolocator.isLocationServiceEnabled();
    return serviceActif;
  }

  /// Demande un fix GPS unique : vérifie le service de localisation, puis
  /// les permissions, puis interroge le GPS (15 s max). Chaque étape et
  /// chaque échec est consigné dans le journal de diagnostic.
  Future<Position?> obtenirPosition() async {
    Journal.i('POSITION', 'Demande de position envoyée au GPS');

    bool serviceActif =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceActif) {
      Journal.a('POSITION', 'Service de localisation désactivé',
          {'cause': 'Le GPS du téléphone est coupé'});
      return null;
    }


    LocationPermission permission =
        await Geolocator.checkPermission();


    if (permission == LocationPermission.denied) {

      Journal.i('POSITION', 'Permission absente : demande à l\'utilisateur');
      permission =
          await Geolocator.requestPermission();

      if (permission == LocationPermission.denied) {
        Journal.a('POSITION', 'Permission refusée par l\'utilisateur');
        return null;
      }

    }


    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {

      Journal.a('POSITION', 'Accès à la localisation impossible',
          {'permission': '$permission'});
      return null;

    }


    final debut = DateTime.now();
    try {

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final duree = DateTime.now().difference(debut).inMilliseconds;
      Journal.s('POSITION', 'Fix GPS obtenu', {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'precision_m': position.accuracy,
        'vitesse_ms': position.speed,
        'cap_deg': position.heading,
        'duree_ms': duree,
      });
      return position;

    } catch (e) {
      Journal.e('POSITION', 'Fix GPS impossible', {'erreur': '$e'});
      return null;

    }

  }

}
