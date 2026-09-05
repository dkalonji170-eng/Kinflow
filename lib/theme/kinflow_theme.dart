import 'package:flutter/material.dart';

/// Palette de la marque KinFlow.
///
/// Le vert « circulation » est la couleur principale : il évoque à la fois
/// le trafic fluide (V = vert, feu agissant) et la vie urbaine de Kinshasa.
/// L'ambre sert de couleur d'appui pour les actions importantes.
abstract final class KinColors {
  // Brand
  static const primary = Color(0xFF0A6E45);
  static const primaryFonce = Color(0xFF075238);
  static const primaryClair = Color(0xFF1B8A5C);
  static const accent = Color(0xFFF2A900);
  static const accentTranche = Color(0xFFE98B00);

  // États de trafic (repris du modèle : à conserver identiques)
  static const fluide = Color(0xFFAAE600);
  static const fluideFonce = Color(0xFF8FC400);
  static const embouteillageLeger = Color(0xFFFFA000);
  static const embouteillageLegerFonce = Color(0xFFF5820B);
  static const grosEmbouteillages = Color(0xFFE53935);
  static const grosEmbouteillagesFonce = Color(0xFFC62828);
  static const routeBloquee = Color(0xFF1C1C1E);
  static const routeBloqueeFonce = Color(0xFF000000);

  // Neutres
  static const fondClair = Color(0xFFF4F7F5);
  static const surfaceClair = Colors.white;
  static const texteClair = Color(0xFF13201A);
  static const texteSecondaireClair = Color(0xFF5C6F66);

  static const fondSombre = Color(0xFF0E1210);
  static const surfaceSombre = Color(0xFF161C19);
  static const texteSombre = Color(0xFFEAF2EE);
  static const texteSecondaireSombre = Color(0xFF9FB3A9);
}

/// Thème clair de l'application.
ThemeData construireThemeClair() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: KinColors.primary,
    brightness: Brightness.light,
    primary: KinColors.primary,
    secondary: KinColors.accent,
    surface: KinColors.surfaceClair,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: KinColors.fondClair,
    appBarTheme: const AppBarTheme(
      backgroundColor: KinColors.surfaceClair,
      foregroundColor: KinColors.texteClair,
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 2,
      titleTextStyle: TextStyle(
        color: KinColors.texteClair,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: KinColors.surfaceClair,
      indicatorColor: KinColors.primary.withValues(alpha: 0.14),
      surfaceTintColor: Colors.transparent,
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? KinColors.primary
              : KinColors.texteSecondaireClair,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? KinColors.primary
              : KinColors.texteSecondaireClair,
        ),
      ),
    ),
    cardTheme: const CardThemeData(
      color: KinColors.surfaceClair,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFE3E9E5),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF2F5F3),
      hintStyle: const TextStyle(color: KinColors.texteSecondaireClair),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: KinColors.primary, width: 1.6),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: KinColors.texteClair,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: KinColors.surfaceClair,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      showDragHandle: true,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: KinColors.primary,
      foregroundColor: Colors.white,
      elevation: 3,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: KinColors.primary,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFFEFF3F0),
      selectedColor: KinColors.primary.withValues(alpha: 0.15),
      labelStyle: const TextStyle(color: KinColors.texteClair, fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide.none,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: KinColors.surfaceClair,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? KinColors.primary
            : null,
      ),
    ),
  );
}

/// Thème sombre de l'application.
ThemeData construireThemeSombre() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: KinColors.primary,
    brightness: Brightness.dark,
    primary: const Color(0xFF4CD98E),
    secondary: KinColors.accent,
    surface: KinColors.surfaceSombre,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: KinColors.fondSombre,
    appBarTheme: const AppBarTheme(
      backgroundColor: KinColors.surfaceSombre,
      foregroundColor: KinColors.texteSombre,
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 2,
      titleTextStyle: TextStyle(
        color: KinColors.texteSombre,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: KinColors.surfaceSombre,
      indicatorColor: const Color(0xFF4CD98E).withValues(alpha: 0.16),
      surfaceTintColor: Colors.transparent,
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? const Color(0xFF4CD98E)
              : KinColors.texteSecondaireSombre,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? const Color(0xFF4CD98E)
              : KinColors.texteSecondaireSombre,
        ),
      ),
    ),
    cardTheme: const CardThemeData(
      color: KinColors.surfaceSombre,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF262E2A),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF212825),
      hintStyle: const TextStyle(color: KinColors.texteSecondaireSombre),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF4CD98E), width: 1.6),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFFEAF2EE),
      contentTextStyle: const TextStyle(color: Color(0xFF0E1210), fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: KinColors.surfaceSombre,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      showDragHandle: true,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF4CD98E),
      foregroundColor: Color(0xFF0E1210),
      elevation: 3,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFF4CD98E),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFF232A27),
      selectedColor: const Color(0xFF4CD98E).withValues(alpha: 0.18),
      labelStyle: const TextStyle(color: KinColors.texteSombre, fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide.none,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: KinColors.surfaceSombre,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Color(0xFF4CD98E)
            : null,
      ),
    ),
  );
}

/// Widget utilitaire : pastille de couleur d'un état de trafic.
class PastilleEtatTrafic extends StatelessWidget {
  const PastilleEtatTrafic({super.key, required this.couleur, this.taille = 14});

  final Color couleur;
  final double taille;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        color: couleur,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black.withValues(alpha: 0.15)),
      ),
    );
  }
}