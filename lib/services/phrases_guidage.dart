import 'package:shared_preferences/shared_preferences.dart';

import 'voix_guidage.dart' show TypeVirage;

/// Une phrase de guidage vocal éditée dans les Réglages (écran
/// « Guidage vocal »). La clé est stable sur disque, le titre et l'aide
/// servent à l'affichage du champ.
class PhraseGuidage {
  final String cle;
  final String titre;
  final String aide;

  const PhraseGuidage(this.cle, this.titre, this.aide);
}

/// Persistance et valeurs par défaut des phrases de guidage vocal.
///
/// Le guidage prononce 14 phrases (le départ, 4 niveaux d'annonce par côté,
/// plus l'arrivée). L'utilisateur peut remplacer chacune par sa propre
/// formule — c'est toujours la voix du téléphone (synthèse) qui la lit. Une
/// phrase personnalisée vide est ignorée : le texte par défaut est alors
/// utilisé.
abstract final class PhrasesGuidage {
  static const String _prefixe = 'phrases_guidage_';

  static const Map<String, String> _defaut = {
    'depart': 'Itinéraire tracé avec succès.',
    'gauche_0': 'Dans 300 mètres, tournez à gauche.',
    'gauche_1': 'Dans 100 mètres, tournez à gauche.',
    'gauche_2': 'Dans 50 mètres, tournez à gauche.',
    'gauche_3': 'Veuillez tourner à gauche.',
    'droite_0': 'Dans 300 mètres, tournez à droite.',
    'droite_1': 'Dans 100 mètres, tournez à droite.',
    'droite_2': 'Dans 50 mètres, tournez à droite.',
    'droite_3': 'Veuillez tourner à droite.',
    'demitour_0': 'Dans 300 mètres, faites demi-tour.',
    'demitour_1': 'Dans 100 mètres, faites demi-tour.',
    'demitour_2': 'Dans 50 mètres, faites demi-tour.',
    'demitour_3': 'Veuillez faire demi-tour.',
    'arrivee':
        'Vous êtes arrivé à destination. Merci de nous avoir accordé votre '
        'attention. À bientôt pour d\'autres aventures.',
  };

  /// Les 14 phrases éditables, dans l'ordre d'affichage des Réglages.
  static const List<PhraseGuidage> editables = [
    PhraseGuidage('depart', 'Départ', 'Prononcée dès que l\'itinéraire est tracé.'),
    PhraseGuidage('gauche_0', 'À gauche — 300 m', 'Annoncée 300 m avant le virage.'),
    PhraseGuidage('gauche_1', 'À gauche — 100 m', 'Annoncée 100 m avant le virage.'),
    PhraseGuidage('gauche_2', 'À gauche — 50 m', 'Annoncée 50 m avant le virage.'),
    PhraseGuidage('gauche_3', 'À gauche — imminent', 'Annoncée juste avant le virage.'),
    PhraseGuidage('droite_0', 'À droite — 300 m', 'Annoncée 300 m avant le virage.'),
    PhraseGuidage('droite_1', 'À droite — 100 m', 'Annoncée 100 m avant le virage.'),
    PhraseGuidage('droite_2', 'À droite — 50 m', 'Annoncée 50 m avant le virage.'),
    PhraseGuidage('droite_3', 'À droite — imminent', 'Annoncée juste avant le virage.'),
    PhraseGuidage('demitour_0', 'Demi-tour — 300 m', 'Annoncée 300 m avant le virage.'),
    PhraseGuidage('demitour_1', 'Demi-tour — 100 m', 'Annoncée 100 m avant le virage.'),
    PhraseGuidage('demitour_2', 'Demi-tour — 50 m', 'Annoncée 50 m avant le virage.'),
    PhraseGuidage('demitour_3', 'Demi-tour — imminent', 'Annoncée juste avant le virage.'),
    PhraseGuidage('arrivee', 'Arrivée', 'Prononcée à l\'approche de la destination.'),
  ];

  /// Valeurs par défaut (aucune personnalisation).
  static Map<String, String> parDefaut() => Map.unmodifiable(_defaut);

  /// Clé de disque (avec préfixe) d'une phrase personnalisée.
  static String cleStockage(String cle) => _prefixe + cle;

  /// Clé logique d'une phrase de virage selon le type et le niveau
  /// d'annonce (0 = 300 m, 1 = 100 m, 2 = 50 m, 3 = imminent).
  static String clePour(TypeVirage type, int niveau) {
    final base = switch (type) {
      TypeVirage.gauche => 'gauche',
      TypeVirage.droite => 'droite',
      TypeVirage.demiTour => 'demitour',
    };
    return '${base}_$niveau';
  }

  /// Phrase par défaut d'une annonce de virage.
  static String defautPour(TypeVirage type, int niveau) =>
      _defaut[clePour(type, niveau)]!;

  /// Phrase par défaut prononcée dès que l'itinéraire est tracé.
  static String defautDepart() => _defaut['depart']!;

  /// Phrase par défaut d'arrivée.
  static String defautArrivee() => _defaut['arrivee']!;

  /// Les phrases à utiliser, personnalisées si présentes (non vides), sinon
  /// les valeurs par défaut.
  static Future<Map<String, String>> charger() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final e in _defaut.entries)
        e.key: _vigoureuse(prefs.getString(cleStockage(e.key))) ?? e.value,
    };
  }

  /// Enregistre les phrases personnalisées (toutes les clés, défauts inclus).
  static Future<void> sauvegarder(Map<String, String> phrases) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in _defaut.entries) {
      final texte = phrases[entry.key];
      if (texte == null) continue;
      await prefs.setString(cleStockage(entry.key), texte.trim());
    }
  }

  /// Efface toutes les personnalisations : les phrases par défaut reprennent.
  static Future<void> reinitialiser() async {
    final prefs = await SharedPreferences.getInstance();
    for (final cle in _defaut.keys) {
      await prefs.remove(cleStockage(cle));
    }
  }

  /// Retourne [texte] nettoyé, ou null s'il est vide/absent.
  static String? _vigoureuse(String? texte) {
    if (texte == null) return null;
    final t = texte.trim();
    return t.isEmpty ? null : t;
  }
}