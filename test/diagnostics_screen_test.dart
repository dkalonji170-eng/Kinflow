import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/screens/diagnostics_screen.dart';
import 'package:kinflow/services/diagnostics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Journal.instance.vider();
  });

  /// Laisse expirer les minuteries internes du journal (sauvegarde 5 s,
  /// notification 120 ms) pour que le harnais de test ne les signale pas.
  Future<void> laisserMinuteriesSEteindre(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets(
      'Ouverture du journal avec erreurs non vues ne déborde pas la pile',
      (tester) async {
    for (var i = 0; i < 50; i++) {
      Journal.i('TEST', 'Événement numéro $i', {'valeur': i * 1.5});
    }
    Journal.e('TEST', 'Erreur de test');
    Journal.a('TEST', 'Alerte de test');

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DiagnosticsScreen()),
    ));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    expect(find.byType(DiagnosticsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await laisserMinuteriesSEteindre(tester);
  });

  testWidgets('Nouveaux événements pendant que la fenêtre est ouverte',
      (tester) async {
    for (var i = 0; i < 30; i++) {
      Journal.i('TEST', 'Avant ouverture $i');
    }

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DiagnosticsScreen()),
    ));
    await tester.pump();

    for (var i = 0; i < 15; i++) {
      Journal.i('TEST', 'Pendant ouverture $i', {'index': i.toDouble()});
      Journal.e('TEST', 'Erreur pendant ouverture $i');
      await tester.pump(const Duration(milliseconds: 130));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await laisserMinuteriesSEteindre(tester);
  });

  testWidgets('Export du rapport complet (bouton copier)', (tester) async {
    for (var i = 0; i < 200; i++) {
      Journal.i('CARTE', 'Geste carte $i', {'zoom': 12.0 + i * 0.1});
    }
    final texte = Journal.instance.exporterTexte();
    expect(texte, contains('RAPPORT DE DIAGNOSTIC'));
    await laisserMinuteriesSEteindre(tester);
  });
}
