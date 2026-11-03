import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/widgets/citation_message.dart';

void main() {
  group('CitationMessage', () {
    testWidgets('affiche le nom et le résumé du message cité', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CitationMessage(nom: 'Awa', resume: 'On se retrouve où ?'),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Awa'), findsOneWidget);
      expect(find.text('On se retrouve où ?'), findsOneWidget);
    });

    testWidgets('reste cliquable pour revenir au message d\'origine', (
      tester,
    ) async {
      var appuis = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CitationMessage(
              nom: 'Vous',
              resume: 'Message vocal',
              onTap: () => appuis++,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(CitationMessage));
      await tester.pumpAndSettle();
      expect(appuis, 1);
    });

    testWidgets('tronque un résumé long au lieu de déborder', (tester) async {
      final long = 'x' * 400;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: CitationMessage(nom: 'Awa', resume: long),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(long), findsOneWidget);
    });
  });
}
