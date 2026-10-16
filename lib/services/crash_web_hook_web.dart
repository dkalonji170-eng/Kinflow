import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Envoie le contenu du plantage au serveur de capture local (localhost:9090)
/// et garde une copie dans localStorage en secours.
void transmettreCrash(String contenu) {
  try {
    web.window.localStorage.setItem('kinflow_dernier_crash', contenu);
  } catch (_) {}
  try {
    final req = web.XMLHttpRequest();
    req.open('POST', 'http://localhost:9090/crash');
    req.setRequestHeader('Content-Type', 'text/plain');
    req.send(contenu.toJS);
  } catch (_) {}
}