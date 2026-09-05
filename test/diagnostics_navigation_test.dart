import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/screens/diagnostics_screen.dart';
import 'package:kinflow/services/diagnostics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Session précédente restaurée + ouverture complète par navigation',
      (tester) async {
    // Simule une session précédente sauvegardée sur disque.
    final anciennes = [
      for (var i = 0; i < 120; i++)
        EntreeJournal(
          sequence: i,
          horodatage: DateTime.now().subtract(Duration(minutes: 120 - i)),
          module: i % 7 == 0 ? 'PLANTAGE' : 'CARTE',
          niveau: i % 7 == 0
              ? NiveauJournal.erreur
              : NiveauJournal.info,
          message: 'Événement ancien $i',
          details: {'zoom': 10.0 + i},
        ).versJson(),
    ];
    SharedPreferences.setMockInitialValues({
      'kinflow_journal_v1': json.encode(anciennes),
    });

    // Force la restauration disque avant l'ouverture.
    Journal.instance; // déclenche le constructeur + chargement async
    await tester.pump(const Duration(milliseconds: 50));

    // La fenêtre est poussée par navigation, comme le vrai bouton.
    final navigateur = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigateur,
      home: const Scaffold(body: SizedBox()),
    ));

    navigateur.currentState!.push(
      MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
    );
    await tester.pump(); // démarre la transition
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(seconds: 1)); // fin de transition

    // Des événements arrivent PENDANT que la fenêtre est ouverte.
    for (var i = 0; i < 8; i++) {
      Journal.i('DIAGNOSTIC', 'Pendant navigation $i');
      if (i % 3 == 0) {
        Journal.e('CARTE', 'Chargement des routes échoué', {'erreur': 'x$i'});
      }
      await tester.pump(const Duration(milliseconds: 130));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.byType(DiagnosticsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Laisse expirer la minuterie de sauvegarde interne du journal.
    await tester.pump(const Duration(seconds: 6));
  });
}
