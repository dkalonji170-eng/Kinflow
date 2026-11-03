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

  testWidgets('bulle vocale : la citation du message répond, en haut', (
    tester,
  ) async {
    var ouvert = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BulleVocale(
            dureeMs: 12000,
            moi: false,
            heure: '12:04',
            formes: const [0.4, 0.7, 0.3],
            citation: InkWell(
              onTap: () => ouvert = true,
              child: const Text('Aperçu du message cité'),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Aperçu du message cité'), findsOneWidget);

    // L'aperçu reste cliquable : on peut revenir au message d'origine.
    await tester.tap(find.text('Aperçu du message cité'));
    expect(ouvert, isTrue);
  });

  testWidgets('bulle vocale : pas de débordement à ×1,5 sur écran étroit', (
    tester,
  ) async {
    // Le libellé « 1,5× » est plus large que « 1× » : il faisait déborder la
    // ligne des temps de quelques pixels. On vérifie le pire cas (320 pt).
    for (final largeur in [320.0, 360.0, 412.0]) {
      tester.view.physicalSize = Size(largeur, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: BulleVocale(
                key: ValueKey(largeur),
                dureeMs: 65000,
                moi: false,
                heure: '12:34',
                avatarId: 'a1',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('1×'));
      await tester.pump();

      expect(find.text('1,5×'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
