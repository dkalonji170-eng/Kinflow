import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/models/information_ville.dart';

void main() {
  group('InformationVille.depuisJson', () {
    test('lit source_url pour le lien « Plus d\'informations »', () {
      final info = InformationVille.depuisJson({
        'id': '1',
        'contenu': 'Un titre assez long pour passer toutes les vérifications',
        'source_url': 'https://www.radiookapi.net/actualite/2026/09/23/example',
        'latitude': -4.325,
        'longitude': 15.322,
        'nb_verts': 3,
        'nb_rouges': 1,
        'cree_a': '2026-09-23T10:00:00Z',
      });
      expect(
        info.sourceUrl,
        'https://www.radiookapi.net/actualite/2026/09/23/example',
      );
    });

    test('sourceUrl est null sans source_url (info publiée à la main)', () {
      final info = InformationVille.depuisJson({
        'id': '2',
        'contenu': 'Un titre assez long pour passer toutes les vérifications',
        'nb_verts': 0,
        'nb_rouges': 0,
        'cree_a': '2026-09-23T10:00:00Z',
      });
      expect(info.sourceUrl, isNull);
    });
  });

  group('InformationVille.copyWith', () {
    InformationVille base() => InformationVille(
      id: 'info-1',
      contenu: 'Une info avec image et épinglage',
      sourceUrl: 'https://exemple.cd/article',
      imageUrl: 'https://exemple.cd/photo.jpg',
      latitude: -4.325,
      longitude: 15.322,
      nbVerts: 3,
      nbRouges: 1,
      maReaction: 'VERT',
      emojis: const [('🔥', 2)],
      mesEmojis: const {'🔥'},
      epinglee: true,
      creeA: DateTime.utc(2026, 10, 31, 12),
    );

    test('conserve image et épinglage lors d\'une réaction optimiste', () {
      final copie = base().copyWith(nbVerts: 4, maReaction: 'ROUGE');

      expect(copie.imageUrl, 'https://exemple.cd/photo.jpg');
      expect(copie.epinglee, isTrue);
      expect(copie.sourceUrl, 'https://exemple.cd/article');
      expect(copie.nbVerts, 4);
      expect(copie.maReaction, 'ROUGE');
      expect(copie.creeA, DateTime.utc(2026, 10, 31, 12));
    });

    test('conserve l\'image lors d\'un changement d\'émoji', () {
      final copie = base().copyWith(
        emojis: const [('❤️', 5)],
        mesEmojis: const {'❤️'},
      );

      expect(copie.imageUrl, 'https://exemple.cd/photo.jpg');
      expect(copie.epinglee, isTrue);
      expect(copie.emojis, [('❤️', 5)]);
      expect(copie.mesEmojis, {'❤️'});
    });

    test('effacerReaction remet maReaction à null', () {
      final copie = base().copyWith(effacerReaction: true);

      expect(copie.maReaction, isNull);
      expect(copie.imageUrl, 'https://exemple.cd/photo.jpg');
      expect(copie.epinglee, isTrue);
    });
  });

  group('InformationVille.appliquerEmoji (un seul émoji par personne)', () {
    test('pose l\'émoji choisi quand aucun n\'est posé', () {
      final (emojis, mes) = InformationVille.appliquerEmoji(
        const [('❤️', 3)],
        const {},
        '🔥',
      );
      expect(mes, {'🔥'});
      expect(emojis, [('❤️', 3), ('🔥', 1)]);
    });

    test('retaper le même émoji le retire', () {
      final (emojis, mes) = InformationVille.appliquerEmoji(
        const [('🔥', 2)],
        const {'🔥'},
        '🔥',
      );
      expect(mes, isEmpty);
      expect(emojis, [('🔥', 1)]);
    });

    test('une ligne tombe à 0 quand le dernier utilisateur la retire', () {
      final (emojis, mes) = InformationVille.appliquerEmoji(
        const [('🔥', 1), ('❤️', 4)],
        const {'🔥'},
        '🔥',
      );
      expect(mes, isEmpty);
      expect(emojis, [('❤️', 4)]);
    });

    test('poser un autre émoji remplace le précédent', () {
      final (emojis, mes) = InformationVille.appliquerEmoji(
        const [('😂', 7), ('🔥', 2), ('❤️', 1)],
        const {'🔥'},
        '😂',
      );
      final compteur = <String, int>{for (final (e, c) in emojis) e: c};
      expect(mes, {'😂'});
      expect(compteur['😂'], 8);
      expect(compteur['🔥'], 1);
      expect(compteur['❤️'], 1);
    });

    test('remplacement quand le précédent était le seul de son espèce', () {
      final (emojis, mes) = InformationVille.appliquerEmoji(
        const [('😢', 5), ('🔥', 1)],
        const {'🔥'},
        '😢',
      );
      expect(mes, {'😢'});
      expect(emojis, [('😢', 6)]);
    });
  });
}
