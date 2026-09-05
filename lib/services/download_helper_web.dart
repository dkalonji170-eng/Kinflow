// Télécharge un fichier sur le web via un lien d'ancrage avec attribut
// `download`, ce qui force le téléchargement au lieu d'ouvrir l'URL.
//
// Utilisé par l'écran d'accueil pour télécharger l'APK Android.
import 'dart:html' as html;

void telechargerViaAncre(String url, String nomFichier) {
  final anchor = html.AnchorElement(href: url)
    ..download = nomFichier
    ..style.display = 'none';
  html.document.body?.children.add(anchor);
  anchor.click();
  anchor.remove();
}
