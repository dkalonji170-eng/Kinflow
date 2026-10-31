/// Configuration de l'ami(e) IA « Kinflow ».
///
/// Kinflow utilise Google Gemini (offre GRATUITE) comme cerveau. Il faut créer
/// une clé API gratuite une seule fois sur https://aistudio.google.com/apikey
/// puis la coller ci-dessous.
///
/// NOTE SÉCURITÉ : une clé placée dans le code de l'app est visible par qui
/// décompile l'APK. C'est acceptable pour un usage personnel. Si l'app est
/// publiée au grand public, il faudra passer par une fonction serveur
/// (ex. Supabase Edge Function) pour garder la clé secrète côté serveur.
abstract final class IAConfig {
  /// Clé API Gemini — À REMPLACER par ta clé gratuite.
  static const String cleApi = 'MET_TON_ICI_LA_CLE_GEMINI';

  /// Modèle utilisé. `gemini-2.0-flash` est rapide et éligible au quota gratuit.
  static const String modele = 'gemini-2.0-flash';

  /// URL de base de l'API Gemini.
  static const String _base = 'https://generativelanguage.googleapis.com/v1beta';

  /// Endpoint complet de génération de contenu.
  static Uri get endpointGenerer => Uri.parse(
        '$_base/models/$modele:generateContent',
      );

  /// Vrai si une clé a bien été renseignée (sinon on affiche un message clair).
  static bool get estConfiguree =>
      cleApi.isNotEmpty && cleApi != 'MET_TON_ICI_LA_CLE_GEMINI';
}
