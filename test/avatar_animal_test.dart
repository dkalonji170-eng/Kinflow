import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/widgets/avatar_animal.dart';

void main() {
  group('avatarsAnimaux', () {
    test('propose exactement 10 animaux, tous avec un id unique', () {
      expect(avatarsAnimaux.length, 10);
      final ids = avatarsAnimaux.map((a) => a.id).toSet();
      expect(ids.length, 10, reason: 'deux animaux partagent le même id');
    });

    test('chaque animal a emoji, nom et couleur', () {
      for (final a in avatarsAnimaux) {
        expect(a.emoji, isNotEmpty);
        expect(a.nom, isNotEmpty);
        expect(a.couleur, isA<Color>());
      }
    });

    test('avatarParId retrouve chaque animal proposé', () {
      for (final a in avatarsAnimaux) {
        expect(avatarParId(a.id)?.id, a.id);
      }
    });

    test('avatarParId retourne null pour vide, null ou inconnu', () {
      expect(avatarParId(null), isNull);
      expect(avatarParId(''), isNull);
      expect(avatarParId('dinosaure'), isNull);
    });
  });

  group('AvatarAnimalWidget', () {
    testWidgets('affiche l\'animal choisi en cercle coloré', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AvatarAnimalWidget(taille: 90, avatarId: 'lion'),
          ),
        ),
      );
      expect(find.text('🦁'), findsOneWidget);
    });

    testWidgets('affiche l\'icône personne sans avatar', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AvatarAnimalWidget(taille: 90, avatarId: null),
          ),
        ),
      );
      expect(find.byIcon(Icons.person), findsOneWidget);
    });

    testWidgets('affiche l\'icône personne pour un id inconnu', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AvatarAnimalWidget(taille: 90, avatarId: 'x'),
          ),
        ),
      );
      expect(find.byIcon(Icons.person), findsOneWidget);
    });
  });
}