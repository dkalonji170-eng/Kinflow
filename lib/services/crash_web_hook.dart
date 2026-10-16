import 'crash_web_hook_stub.dart'
    if (dart.library.js_interop) 'crash_web_hook_web.dart' as impl;

/// Transmet un contenu de plantage au serveur de capture local
/// (fonctionne uniquement sur le web ; no-op ailleurs).
void transmettreCrash(String contenu) => impl.transmettreCrash(contenu);