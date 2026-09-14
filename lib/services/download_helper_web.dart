// Télécharge un fichier sur le web via un lien d'ancrage avec attribut
// `download`, ce qui force le téléchargement au lieu d'ouvrir l'URL.
//
// Utilisé par l'écran d'accueil pour télécharger l'APK Android.
import 'package:web/web.dart' as web;

void telechargerViaAncre(String url, String nomFichier) {
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = nomFichier
    ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
}