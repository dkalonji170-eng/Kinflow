import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb, PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'theme_provider.dart';
import 'theme/kinflow_theme.dart';
import 'screens/auth_screen.dart';
import 'services/tile_download_service.dart';
import 'services/tile_seed_service.dart';
import 'services/supabase_service.dart';
import 'services/crash_reporter.dart';
import 'services/diagnostics_service.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

late final TileDownloadService tileDownloadService;

final Completer<void> fmtcReady = Completer<void>();
Future<void> get waitForFmtc => fmtcReady.future;

bool fmtcSucceeded = false;
bool _fmtcStarted = false;

/// Garde-fou anti-boucle : si la gestion d'un plantage en déclenche un
/// autre (ex. erreur pendant l'erreur), on n'empile pas la pile.
int _profondeurPlantage = 0;

void _signalerPlantage(String origine, Object erreur, [StackTrace? stack]) {
  if (_profondeurPlantage >= 2) return;
  _profondeurPlantage++;
  try {
    Journal.e('PLANTAGE', 'Erreur non gérée ($origine)', {'erreur': '$erreur'});
    reportCrash(origine, erreur, stack ?? StackTrace.current);
  } catch (_) {
    // Impossible de consigner : on n'insiste pas.
  } finally {
    _profondeurPlantage--;
  }
}

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      Journal.i('DEMARRAGE', 'Application lancée');

      FlutterError.onError = (details) {
        _signalerPlantage('FlutterError', details.exception, details.stack);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        _signalerPlantage('PlatformDispatcher', error, stack);
        return true;
      };

      await _runApp();
    },
    (error, stack) {
      _signalerPlantage('ZonedGuarded', error, stack);
    },
  );
}

Future<void> _runApp() async {
  tileDownloadService = TileDownloadService();

  final app = ChangeNotifierProvider(
    create: (_) => ThemeProvider(),
    child: const MyApp(),
  );

  if (kIsWeb) {
    await SupabaseService().init();
    if (SupabaseService().initError != null) {
      runApp(ErrorCatcherApp(erreur: SupabaseService().initError));
      return;
    }
    runApp(app);
    return;
  }

  unawaited(SupabaseService().init());

  runApp(app);
}

class ErrorCatcherApp extends StatelessWidget {
  final Object? erreur;
  const ErrorCatcherApp({super.key, this.erreur});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1a1a2e),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 64, color: Colors.redAccent),
                const SizedBox(height: 24),
                const Text(
                  'Erreur de connexion',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    erreur?.toString() ?? 'Aucune erreur capturée',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(
                        text: erreur?.toString() ?? 'Aucune erreur capturée',
                      ),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Erreur copiée dans le presse-papiers'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copier l\'erreur'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Ouvre la console du navigateur (F12)\nou regarde le terminal',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> initFmtc() async {
  if (kIsWeb) {
    if (!fmtcReady.isCompleted) fmtcReady.complete();
    return;
  }
  if (_fmtcStarted) return;
  _fmtcStarted = true;
  try {
    await FMTCObjectBoxBackend().initialise();
    await FMTCStore('kinshasa').manage.create();
    debugPrint('[KinFlow] FMTC initialisé');
    Journal.s('TUILES', 'Cache de cartes (FMTC) initialisé');
    fmtcSucceeded = true;
    if (!fmtcReady.isCompleted) fmtcReady.complete();
    await TileSeedService.ensureSeeded();
  } catch (e) {
    debugPrint('[KinFlow] Erreur init FMTC: $e');
    Journal.e('TUILES', 'Échec initialisation du cache FMTC', {'erreur': '$e'});
    if (!fmtcReady.isCompleted) fmtcReady.completeError(e);
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      debugShowCheckedModeBanner: false,

      title: 'KinFlow',

      theme: construireThemeClair(),

      darkTheme: construireThemeSombre(),

      themeMode: themeProvider.themeMode,

      home: const AuthScreen(),
    );
  }
}
