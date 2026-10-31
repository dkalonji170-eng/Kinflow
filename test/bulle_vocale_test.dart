import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/widgets/bulle_vocale.dart';

void main() {
  testWidgets('bulle vocale : rendu + choix de la vitesse', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BulleVocale(
            dureeMs: 45000,
            moi: true,
            heure: '12:00',
            formes: [0.3, 0.8, 0.5, 0.9, 0.2],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('1×'), findsOneWidget);
    expect(find.text('00:45'), findsOneWidget);

    await tester.tap(find.text('1×'));
    await tester.pumpAndSettle();
    expect(find.text('1,5×'), findsOneWidget);

    await tester.tap(find.text('1,5×'));
    await tester.pumpAndSettle();
    expect(find.text('2×'), findsOneWidget);

    // Nouvel appui : retour direct à ×1 (pas de menu, pas de tableau).
    await tester.tap(find.text('2×'));
    await tester.pumpAndSettle();
    expect(find.text('1×'), findsOneWidget);
  });
}
