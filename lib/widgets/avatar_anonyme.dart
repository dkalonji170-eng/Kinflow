import 'package:flutter/material.dart';

/// Avatar d'un profil anonyme : un cercle noir barré d'un X blanc.
///
/// Utilisé pour les publications et les commentaires anonymes : ni nom, ni
/// avatar d'animal, seulement ce symbole et « Anonyme ».
class AvatarAnonyme extends StatelessWidget {
  const AvatarAnonyme({super.key, this.taille = 32});

  final double taille;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: taille,
      height: taille,
      decoration: const BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.close, size: taille * 0.56, color: Colors.white),
    );
  }
}
