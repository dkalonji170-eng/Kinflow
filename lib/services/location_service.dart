import 'dart:async';

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
  /// les permissions, puis interroge le GPS (délai borné, avec repli sur la
  /// dernière position connue). Chaque étape et chaque échec est consigné
  /// dans le journal de diagnostic.
  Future<Position?> obtenirPosition() async {
    Journal.i('POSITION', 'Demande de position envoyée au GPS');
    try {
      return await _obtenirPositionInterne();
    } catch (e) {
      // Certains téléphones rejettent une PermissionException, une
      // PlatformException ou « User denied Geolocation » au niveau du canal :
      // on la capture pour ne jamais la laisser remonter en erreur non gérée.
      Journal.e('POSITION', 'Erreur du service de localisation', {
        'erreur': '$e',
      });
      return null;
    }
  }

  Future<Position?> _obtenirPositionInterne() async {
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
    final position = await _fixGpsLePlusPrecis();

    if (position == null) {
      Journal.e('POSITION', 'Aucun fix GPS obtenu dans le délai imparti');
      return null;
    }

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
  }

  /// Fix GPS le plus précis possible, sans faire patienter l'utilisateur.
  ///
  /// Pendant le délai alloué, on écoute le flux à précision maximale et on
  /// garde la fix avec la MEILLEURE accuracy (au lieu de renvoyer la première,
  /// souvent encore en cours de convergence). Trois sorties possibles :
  ///  - dès qu'une fix est excellente (≤ [precisionExcellente]) : réponse
  ///    quasi immédiate ;
  ///  - après [delaiMin], si on a déjà une fix correcte
  ///    (≤ [precisionAcceptable]) : on ne fait pas attendre pour un gain
  ///    marginal ;
  ///  - au plus tard à [dureeMax] : on renvoie la meilleure fix obtenue. Si
  ///    le flux ne donne rien, repli sur la dernière position connue (si elle
  ///    est fraîche) avant d'abandonner.
  Future<Position?> _fixGpsLePlusPrecis({
    Duration dureeMax = const Duration(seconds: 12),
    Duration delaiMin = const Duration(milliseconds: 3000),
    double precisionExcellente = 20.0,
    double precisionAcceptable = 40.0,
  }) async {
    final completer = Completer<Position?>();
    Position? meilleure;
    Timer? minuteurMax;
    Timer? minuteurMin;
    StreamSubscription<Position>? sub;

    void finaliser([Position? fix]) {
      minuteurMax?.cancel();
      minuteurMin?.cancel();
      sub?.cancel();
      if (!completer.isCompleted) completer.complete(fix ?? meilleure);
    }

    sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen(
      (fix) {
        if (meilleure == null || fix.accuracy < meilleure!.accuracy) {
          meilleure = fix;
        }
        // Fix excellente : on répond tout de suite.
        if (fix.accuracy <= precisionExcellente) {
          finaliser(fix);
          return;
        }
        // Après un court délai, une fix « correcte » suffit : pas besoin de
        // viser la précision maximale au prix de l'attente.
        if (minuteurMin != null && !minuteurMin.isActive) {
          if (fix.accuracy <= precisionAcceptable) finaliser(fix);
        }
      },
      onError: (Object e, StackTrace stack) {
        Journal.e(
          'POSITION',
          'Flux de précision interrompu, meilleure fix retenue',
          {'erreur': '$e'},
        );
        finaliser(meilleure);
      },
      onDone: () => finaliser(meilleure),
      cancelOnError: true,
    );

    minuteurMin = Timer(delaiMin, () {
      final fix = meilleure;
      if (fix != null && fix.accuracy <= precisionAcceptable) finaliser(fix);
    });

    minuteurMax = Timer(dureeMax, () async {
      // Le flux n'a rien donné : avant d'abandonner, on tente la dernière
      // position connue du téléphone si elle est suffisamment fraîche.
      var source = 'flux';
      if (meilleure == null) {
        try {
          final derniere = await Geolocator.getLastKnownPosition()
              .timeout(const Duration(seconds: 2));
          if (derniere != null &&
              DateTime.now().difference(derniere.timestamp).inMinutes < 5) {
            meilleure = derniere;
            source = 'derniere_connue';
          }
        } catch (_) {
          // Pas de dernière position exploitable : on reste sur le flux.
        }
      }
      if (meilleure != null) {
        Journal.s('POSITION', 'Fix GPS : délai épuisé, meilleure fix retenue', {
          'precision_m': meilleure!.accuracy,
          'source': source,
        });
      } else {
        // Aucune fix : ne pas annoncer un succès trompeur. L'erreur finale
        // est consignée par l'appelant (_obtenirPositionInterne).
        Journal.a('POSITION', 'Aucune fix GPS reçue dans le délai imparti', {
          'duree_ms': dureeMax.inMilliseconds,
        });
      }
      finaliser(meilleure);
    });

    return completer.future;
  }

}
