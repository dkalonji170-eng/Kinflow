import 'package:flutter/material.dart';

import 'services/diagnostics_service.dart';
import 'services/supabase_service.dart';

class ThemeProvider extends ChangeNotifier {
  bool modeSombre = false;

  ThemeProvider();

  ThemeMode get themeMode =>
      modeSombre ? ThemeMode.dark : ThemeMode.light;

  /// Applique le thème d'un compte (ou force le mode clair à la première
  /// ouverture quand aucun compte n'est connecté).
  void appliquerTheme(bool sombre) {
    if (modeSombre == sombre) return;
    Journal.i('REGLAGES', 'Changement de thème appliqué',
        {'mode': sombre ? 'sombre' : 'clair'});
    modeSombre = sombre;
    notifyListeners();
  }

  /// Change le thème et l'enregistre sur le compte connecté.
  Future<void> changerMode(bool valeur) async {
    Journal.i('REGLAGES', 'Interrupteur de thème actionné',
        {'vers': valeur ? 'sombre' : 'clair'});
    appliquerTheme(valeur);
    await SupabaseService().saveTheme(valeur);
  }
}
