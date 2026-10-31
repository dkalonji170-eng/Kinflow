import 'package:flutter_test/flutter_test.dart';
import 'package:kinflow/services/supabase_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = SupabaseService();

  group('Surnoms locaux des amis', () {
    test('un surnom enregistré est relu', () async {
      SharedPreferences.setMockInitialValues({});
      await service.definirSurnomAmi('ami-1', '  Tonton Joe  ');
      expect(await service.surnomAmi('ami-1'), 'Tonton Joe');
    });

    test('un surnom vide rétablit le nom d\'origine', () async {
      SharedPreferences.setMockInitialValues({});
      await service.definirSurnomAmi('ami-1', 'Tonton Joe');
      await service.definirSurnomAmi('ami-1', '   ');
      expect(await service.surnomAmi('ami-1'), isNull);
    });

    test('la liste des surnoms ignore les clés étrangères', () async {
      SharedPreferences.setMockInitialValues({
        'surnom_ami_ami-1': 'Tonton Joe',
        'surnom_ami_ami-2': 'Maman',
        'autre_cle': 'pas un surnom',
        'surnom_ami_vide': '',
      });
      final surnoms = await service.chargerSurnomsAmis();
      expect(surnoms, {'ami-1': 'Tonton Joe', 'ami-2': 'Maman'});
    });

    test('le surnom remplace prénom + nom sans toucher à la liste', () async {
      final amis = [
        {'ami_id': 'ami-1', 'prenom': 'Joseph', 'nom': 'Kabasele'},
        {'ami_id': 'ami-2', 'prenom': 'Marie', 'nom': 'Ilunga'},
      ];
      final affiches = service.appliquerSurnomsAmis(amis, {
        'ami-1': 'Tonton Joe',
      });
      expect(affiches[0]['prenom'], 'Tonton Joe');
      expect(affiches[0]['nom'], '');
      expect(affiches[1]['prenom'], 'Marie');
      // La liste d'origine (destinée au cache) n'est pas modifiée.
      expect(amis[0]['prenom'], 'Joseph');
      expect(amis[0]['nom'], 'Kabasele');
    });

    test('les surnoms survivent à une déconnexion du compte', () async {
      SharedPreferences.setMockInitialValues({
        SupabaseService.cleCompteLie: true,
        'kinflow_compte_nom': 'Kin',
        'surnom_ami_ami-1': 'Tonton Joe',
      });
      // Déconnexion : le compte lié et les caches partent…
      await service.effacerCompteLieLocal();
      await service.effacerCachesHorsLigne();
      // … mais les surnoms restent sur l'appareil.
      expect(await service.surnomAmi('ami-1'), 'Tonton Joe');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SupabaseService.cleCompteLie), isNull);
    });
  });
}
