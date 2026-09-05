import 'package:shared_preferences/shared_preferences.dart';
class TrafficService {


  Future<String?> chargerEtat() async {

    final prefs =
        await SharedPreferences.getInstance();

    return prefs.getString("dernier_etat");

  }



  Future<int?> chargerHeure() async {

    final prefs =
        await SharedPreferences.getInstance();

    return prefs.getInt("heure_signalement");

  }



  Future<void> enregistrerEtat(String etat) async {

    final prefs =
        await SharedPreferences.getInstance();


    await prefs.setString(
      "dernier_etat",
      etat,
    );


    await prefs.setInt(
      "heure_signalement",
      DateTime.now().millisecondsSinceEpoch,
    );

  }
  bool peutModifier(int? heure) {

    if (heure == null) {
      return true;
    }


    final maintenant =
        DateTime.now().millisecondsSinceEpoch;


    final difference =
        maintenant - heure;


    return difference >= 15 * 60 * 1000;

  }
}