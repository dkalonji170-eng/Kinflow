import 'package:flutter/material.dart';

enum EtatTrafic {
  fluide('Fluide', Color(0xFFAAE600)),
  embouteillageLeger('Embouteillages léger', Colors.orange),
  grosEmbouteillages('Gros embouteillages', Colors.red),
  routeBloquee('Route bloquée', Colors.black);

  const EtatTrafic(this.libelle, this.couleur);

  final String libelle;
  final Color couleur;

  static EtatTrafic? depuisLibelle(String libelle) {
    for (final etat in EtatTrafic.values) {
      if (etat.libelle == libelle) return etat;
    }
    return null;
  }
}
