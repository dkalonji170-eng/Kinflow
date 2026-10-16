import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'diagnostics_service.dart';
import 'supabase_service.dart';

/// Service global de partage de position.
/// Tant que l'application est au premier plan, ce service publie la position
/// de l'utilisateur sur Supabase (table `positions_amis`) avec un throttling
/// raisonnable. À l'arrière-plan, il s'arrête complètement (comportement normal).
class PositionPartageService with WidgetsBindingObserver {
  PositionPartageService._interne();

  static final PositionPartageService instance =
      PositionPartageService._interne();

  final SupabaseService _supabaseService = SupabaseService();

  StreamSubscription<Position>? _positionStream;
  Timer? _surveillanceTimer;
  Timer? _relanceTimer;
  Timer? _verifTimer;
  bool _started = false;
  bool _observationEnregistree = false;

  /// Vrai si la permission de localisation a déjà été demandée dans cette
  /// session applicative (pour ne pas relancer la boîte de dialogue).
  bool _permissionDemandee = false;

  DateTime? _dernierFixGps;
  DateTime? _dernierePublicationPosition;
  LatLng? _dernierePositionPubliee;

  // Filtre de bruit (identique à l'écran Trafic)
  static const double _precisionGpsMaxMetres = 25;
  static const double _seuilBruitPositionMetres = 1.5;
  static const double _seuilVitesseEffectiveMs = 0.45;
  (LatLng, DateTime)? _positionAcceptee;

  // Throttling (identique à l'écran Trafic)
  static const Duration _delaiMinPublication = Duration(seconds: 15);
  static const double _distanceMinPublicationMetres = 20.0;

  /// Démarre le service (idempotent). À appeler une fois au démarrage de
  /// l'application (après authentification).
  Future<void> start() async {
    if (_started) return;
    _started = true;

    if (!_observationEnregistree) {
      WidgetsBinding.instance.addObserver(this);
      _observationEnregistree = true;
    }

    // S'assure que le partage est actif côté serveur.
    await _supabaseService.assurerPartagePosition();

    // Tant que l'appli est au premier plan, on réessaie toutes les 30 s si le
    // flux n'a pas pu démarrer (GPS activé après coup, permission accordée
    // entre-temps…).
    _verifTimer?.cancel();
    _verifTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_started || _positionStream != null) return;
      if (!_auPremierPlan) return;
      unawaited(_demarrerFluxSiPossible());
    });

    // Si déjà au premier plan, démarre immédiatement le flux.
    if (_auPremierPlan) {
      unawaited(_demarrerFluxSiPossible());
    }
  }

  /// Vrai si l'application est au premier plan (état inconnu = on suppose oui).
  bool get _auPremierPlan {
    final etat = WidgetsBinding.instance.lifecycleState;
    return etat == null || etat == AppLifecycleState.resumed;
  }

  /// Arrête complètement le service (réinitialise les timers/flux).
  void stop() {
    _started = false;
    if (_observationEnregistree) {
      WidgetsBinding.instance.removeObserver(this);
      _observationEnregistree = false;
    }
    _arreterFlux();
    _verifTimer?.cancel();
    _verifTimer = null;
    _permissionDemandee = false;
  }

  void _arreterFlux() {
    _positionStream?.cancel();
    _positionStream = null;
    _surveillanceTimer?.cancel();
    _surveillanceTimer = null;
    _relanceTimer?.cancel();
    _relanceTimer = null;
    _dernierFixGps = null;
    _positionAcceptee = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Journal.i('POSITION', 'Application au premier plan : démarrage partage position global');
      unawaited(_demarrerFluxSiPossible());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // On s'arrête uniquement quand l'appli quitte réellement le premier plan.
      // `inactive` est transitoire (tiroir de notifications, boîte de dialogue,
      // sélecteur d'applis) : inutile de couper le suivi pour si peu.
      Journal.i('POSITION', 'Application en arrière-plan : arrêt partage position global');
      _arreterFlux();
    }
  }

  Future<void> _demarrerFluxSiPossible() async {
    if (!_started) return;
    if (_positionStream != null) return;

    // Vérifie que l'utilisateur est connecté.
    if (!_supabaseService.isSignedIn) {
      Journal.i('POSITION', 'Partage global : utilisateur non connecté, flux non démarré');
      return;
    }

    // Vérifie le service de localisation (GPS).
    final serviceActif = await Geolocator.isLocationServiceEnabled();
    if (!serviceActif) {
      Journal.a('POSITION', 'Partage global : service de localisation désactivé');
      _arreterFlux();
      return;
    }

    // Permission : on la demande une seule fois par session applicative, au
    // premier essai. Ensuite on se contente de vérifier, pour ne jamais faire
    // surgir la boîte de dialogue à l'improviste.
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && !_permissionDemandee) {
      _permissionDemandee = true;
      try {
        Journal.i('POSITION', 'Partage global : demande de permission localisation');
        permission = await Geolocator.requestPermission();
      } catch (e) {
        Journal.a('POSITION', 'Partage global : demande de permission impossible',
            {'erreur': '$e'});
      }
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      Journal.a('POSITION', 'Partage global : permission localisation refusée/indéfinie',
          {'permission': '$permission'});
      _arreterFlux();
      return;
    }

    _surveillanceTimer?.cancel();
    _surveillanceTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_started) {
        _surveillanceTimer?.cancel();
        _surveillanceTimer = null;
        return;
      }
      final dernier = _dernierFixGps;
      if (dernier == null ||
          DateTime.now().difference(dernier) > const Duration(seconds: 60)) {
        Journal.a('POSITION', 'Partage global : aucun fix GPS depuis 60 s, redémarrage');
        _positionStream?.cancel();
        _positionStream = null;
        if (!_started) return;
        unawaited(_demarrerFluxSiPossible());
      }
    });

    _dernierFixGps = DateTime.now();
    DateTime? dernierFixJournalise;
    Position? dernierePositionJournalisee;

    void journaliserFix(Position position) {
      final maintenant = DateTime.now();
      final precedente = dernierePositionJournalisee;
      bool significatif = false;
      if (precedente != null) {
        final metres = const Distance().distance(
          LatLng(precedente.latitude, precedente.longitude),
          LatLng(position.latitude, position.longitude),
        );
        significatif = metres > 15 ||
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
      Journal.i('POSITION', 'Partage global : nouveau fix GPS reçu', {
        'precision_m': position.accuracy,
        'vitesse_ms': position.speed,
        'cap_deg': position.heading,
      });
    }

    try {
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 1,
        ),
      ).listen(
        (Position position) {
          _dernierFixGps = DateTime.now();
          journaliserFix(position);

          // Filtre précision
          if (position.accuracy > _precisionGpsMaxMetres &&
              _positionAcceptee != null) {
            return;
          }

          // Filtre bruit
          final pointFix = LatLng(position.latitude, position.longitude);
          final accepte = _positionAcceptee ?? (pointFix, DateTime.now());
          _positionAcceptee = accepte;
          final dureeSec = DateTime.now().difference(accepte.$2).inMilliseconds / 1000.0;
          final distanceDepuisAcceptee = const Distance().distance(
            accepte.$1,
            pointFix,
          );
          final vitesseEffectiveMs = dureeSec > 0 ? distanceDepuisAcceptee / dureeSec : 0;
          if (distanceDepuisAcceptee < _seuilBruitPositionMetres &&
              vitesseEffectiveMs < _seuilVitesseEffectiveMs) {
            return;
          }
          _positionAcceptee = (pointFix, DateTime.now());

          // Publier avec throttling
          final maintenant = DateTime.now();
          final derniere = _dernierePublicationPosition;
          final dernierePoint = _dernierePositionPubliee;
          final delaiEcoule = derniere == null ||
              maintenant.difference(derniere) >= _delaiMinPublication;
          final bougeAssez = dernierePoint == null ||
              const Distance().distance(dernierePoint, pointFix) >=
                  _distanceMinPublicationMetres;
          if (!delaiEcoule && !bougeAssez) {
            return;
          }

          _dernierePublicationPosition = maintenant;
          _dernierePositionPubliee = pointFix;

          // Jamais de publication sans session : après une déconnexion, on ne
          // veut pas recréer de session anonyme pour publier une position.
          if (!_supabaseService.isSignedIn) {
            _arreterFlux();
            return;
          }

          unawaited(
            _supabaseService.publierMaPosition(
              latitude: pointFix.latitude,
              longitude: pointFix.longitude,
              cap: position.heading >= 0 ? position.heading : null,
            ),
          );
        },
        onError: (Object e, StackTrace st) {
          Journal.e('POSITION', 'Partage global : flux GPS interrompu', {'erreur': '$e'});
          debugPrint('[KinFlow] Partage global : flux GPS interrompu: $e');
          _positionStream?.cancel();
          _positionStream = null;
          if (_started) {
            _relanceTimer?.cancel();
            _relanceTimer = Timer(const Duration(seconds: 3), () {
              _relanceTimer = null;
              if (!_started || _positionStream != null) return;
              unawaited(_demarrerFluxSiPossible());
            });
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      Journal.e('POSITION', 'Partage global : impossible de démarrer le flux', {'erreur': '$e'});
      _arreterFlux();
    }
  }
}
