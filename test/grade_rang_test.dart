import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/widgets/grade_rang.dart';

void main() {
  Future<void> afficher(WidgetTester tester, int niveau) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: GradeRang(niveau: niveau)),
        ),
      ),
    );
  }

  group('GradeRang', () {
    testWidgets('niveau 1 : un écu', (tester) async {
      await afficher(tester, 1);
      expect(find.byIcon(Icons.shield_rounded), findsOneWidget);
    });

    testWidgets('niveau 2 : deux écus', (tester) async {
      await afficher(tester, 2);
      expect(find.byIcon(Icons.shield_rounded), findsNWidgets(2));
    });

    testWidgets('niveau 3 : trois écus', (tester) async {
      await afficher(tester, 3);
      expect(find.byIcon(Icons.shield_rounded), findsNWidgets(3));
    });

    testWidgets('niveaux 4 et 5 : une puis deux médailles', (tester) async {
      for (var niveau = 4; niveau <= 5; niveau++) {
        await afficher(tester, niveau);
        expect(find.byIcon(Icons.shield_rounded), findsNothing);
        expect(
          find.byIcon(Icons.workspace_premium_rounded),
          findsNWidgets(niveau - 3),
        );
      }
    });

    testWidgets('niveau 6 : un faucon de feu', (tester) async {
      await afficher(tester, 6);
      expect(find.byIcon(Icons.workspace_premium_rounded), findsNothing);
      expect(find.text('🦅'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
    });

    testWidgets('niveau 7 : un faucon de feu plus ardent', (tester) async {
      await afficher(tester, 7);
      expect(find.text('🦅'), findsOneWidget);
      expect(find.text('🔥'), findsNWidgets(2));
    });

    testWidgets('niveau 8 : le faucon légendaire', (tester) async {
      await afficher(tester, 8);
      expect(find.text('🦅'), findsOneWidget);
      expect(find.text('🔥'), findsNothing);
    });

    testWidgets('un niveau hors bornes est ramené dans 1..8', (tester) async {
      await afficher(tester, 0);
      expect(find.byIcon(Icons.shield_rounded), findsOneWidget);
      await afficher(tester, 99);
      expect(find.text('🦅'), findsOneWidget);
    });

    test('les 8 grades ont un nom', () {
      expect(GradeRang.noms, hasLength(8));
      expect(GradeRang.noms.first, 'Débutant');
      expect(GradeRang.noms.last, 'Légende');
    });

    test('la progression suit les seuils internes du serveur', () {
      // Grade atteint selon le nombre de signalements (jamais affiché).
      expect(GradeRang.niveauPour(0), 1);
      expect(GradeRang.niveauPour(1), 2);
      expect(GradeRang.niveauPour(4), 2);
      expect(GradeRang.niveauPour(5), 3);
      expect(GradeRang.niveauPour(250), 8);
      expect(GradeRang.niveauPour(9999), 8);

      // Premier signalement de chaque grade.
      expect(GradeRang.seuil(1), 0);
      expect(GradeRang.seuil(2), 1);
      expect(GradeRang.seuil(8), 250);

      // Jauge interne du grade.
      expect(GradeRang.progression(1, 0), 0);
      expect(GradeRang.progression(2, 3), closeTo(0.5, 1e-9));
      expect(GradeRang.progression(8, 400), 1);
    });

    test('chaque grade a sa couleur, du plus terne au plus vif', () {
      final couleurs = {
        for (var n = 1; n <= 8; n++) GradeRang.couleur(n),
      };
      expect(couleurs, hasLength(8));
    });
  });
}
