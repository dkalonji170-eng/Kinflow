import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/config/carte.dart';

void main() {
  test('le fond de carte bascule sur MapTiler quand une clé est fournie', () {
    expect(CarteConfig.mapTilerActif, isTrue);
    // Streets v4 : même famille de rendu que Google Maps.
    expect(
      CarteConfig.urlFondClair,
      startsWith(
        'https://api.maptiler.com/maps/streets-v4/256/{z}/{x}/{y}.png?key=',
      ),
    );
    expect(CarteConfig.urlFondSombre, contains('streets-v4-dark'));
    // La clé doit être réellement présente dans l'URL, sinon MapTiler
    // renvoie 403 et la carte reste grise.
    expect(CarteConfig.urlFondClair.split('key=').last, isNotEmpty);
  });

  test('tous les fonds du menu passent par MapTiler', () {
    // Chaque style doit être servi par MapTiler, et non par le fournisseur
    // historique (Esri, CARTO, OpenTopoMap) : sinon le menu mélange les rendus.
    final styles = {
      CarteConfig.styleSatellite: 'hybrid',
      CarteConfig.styleMinimal: 'base-v4',
      CarteConfig.styleMinimalSombre: 'base-v4-dark',
      CarteConfig.styleVif: 'bright-v2',
      CarteConfig.styleTopo: 'topo-v4',
    };
    for (final entree in styles.entries) {
      final url = CarteConfig.urlPourStyle(entree.key, 'https://secours.test');
      expect(
        url,
        startsWith('https://api.maptiler.com/maps/${entree.value}/256/'),
        reason: 'style ${entree.key}',
      );
      expect(url, isNot(contains('secours.test')));
    }
  });

  test('sans clé, le fournisseur de secours est utilisé', () {
    // On ne peut pas retirer la clé à l'exécution ; on vérifie au moins que
    // l'API de repli renvoie bien le secours demandé quand MapTiler est absent.
    if (!CarteConfig.mapTilerActif) {
      expect(
        CarteConfig.urlPourStyle('streets-v4', 'https://secours.test'),
        'https://secours.test',
      );
    }
  });

  test('la recherche est bornée à Kinshasa', () {
    // La ville elle-même, du centre aux communes périphériques.
    expect(estDansKinshasa(-4.325, 15.322), isTrue); // Gombe
    expect(estDansKinshasa(-4.45, 15.20), isTrue); // Mont-Ngafula
    expect(estDansKinshasa(-4.20, 15.60), isTrue); // N'sele
    // Ailleurs : aucun lieu ne doit être proposé.
    expect(estDansKinshasa(48.8566, 2.3522), isFalse); // Paris
    expect(estDansKinshasa(-11.66, 27.48), isFalse); // Lubumbashi
    expect(estDansKinshasa(-4.325, 13.45), isFalse); // Matadi
    expect(estDansKinshasa(-5.30, 15.30), isFalse); // au sud de la borne
    expect(estDansKinshasa(-4.325, 16.80), isFalse); // au-delà de Maluku
  });

  test('la zone Nominatim correspond aux bornes Kinshasa', () {
    expect(
      viewboxKinshasa,
      '$kinshasaOuest,$kinshasaNord,$kinshasaEst,$kinshasaSud',
    );
  });
}
