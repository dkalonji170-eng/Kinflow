// Télécharge un fichier via un lien d'ancrage.
//
// Implémentation conditionnelle : sur le web (`dart:html`), crée une ancre
// avec attribut `download` pour forcer le téléchargement ; sur les autres
// plateformes, no-op (l'écran utilise alors `url_launcher`).
import 'download_helper_io.dart'
    if (dart.library.html) 'download_helper_web.dart' as impl;

void telechargerViaAncre(String url, String nomFichier) {
  impl.telechargerViaAncre(url, nomFichier);
}
