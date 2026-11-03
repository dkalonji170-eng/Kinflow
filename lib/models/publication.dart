/// Un reportage publié dans l'espace d'un informateur.
///
/// Contrairement aux [InformationVille] (le fil de la ville, alimenté par
/// KinFlow), une publication appartient à un espace et n'est visible que par
/// les personnes qui possèdent le lien, ou qui le suivent.
class Publication {
  const Publication({
    required this.id,
    required this.titre,
    required this.contenu,
    required this.typeInfo,
    required this.creeA,
    this.lieu,
    this.photos = const [],
    this.statut = 'publie',
    this.anonyme = false,
    this.auteurNom,
    this.auteurAvatar,
    this.nbLikes = 0,
    this.nbCommentaires = 0,
    this.jaiLike = false,
    this.jePeuxSupprimer = false,
  });

  final String id;
  final String titre;
  final String contenu;

  /// 'trafic', 'eau', 'courant', 'internet', 'securite' ou 'info'.
  final String typeInfo;

  final DateTime creeA;
  final String? lieu;

  /// Chemins Storage des photos (bucket privé `publications_photos`).
  final List<String> photos;

  final String statut;

  /// Publication anonyme : le nom et l'avatar sont masqués côté serveur.
  final bool anonyme;

  final String? auteurNom;
  final String? auteurAvatar;

  final int nbLikes;
  final int nbCommentaires;
  final bool jaiLike;

  /// Vrai si je peux supprimer ce reportage (auteur ou propriétaire de
  /// l'espace).
  final bool jePeuxSupprimer;

  bool get aDesPhotos => photos.isNotEmpty;

  String get nomAffiche {
    final nom = auteurNom?.trim() ?? '';
    return anonyme || nom.isEmpty ? 'Anonyme' : nom;
  }

  Publication copyWith({int? nbLikes, int? nbCommentaires, bool? jaiLike}) {
    return Publication(
      id: id,
      titre: titre,
      contenu: contenu,
      typeInfo: typeInfo,
      creeA: creeA,
      lieu: lieu,
      photos: photos,
      statut: statut,
      anonyme: anonyme,
      auteurNom: auteurNom,
      auteurAvatar: auteurAvatar,
      nbLikes: nbLikes ?? this.nbLikes,
      nbCommentaires: nbCommentaires ?? this.nbCommentaires,
      jaiLike: jaiLike ?? this.jaiLike,
      jePeuxSupprimer: jePeuxSupprimer,
    );
  }

  factory Publication.depuisJson(Map<String, dynamic> json) {
    final brutPhotos = json['photos'];
    final photos = <String>[];
    if (brutPhotos is List) {
      for (final p in brutPhotos) {
        final chemin = p?.toString().trim() ?? '';
        if (chemin.isNotEmpty) photos.add(chemin);
      }
    }
    final lieuBrut = (json['lieu'] as String?)?.trim() ?? '';
    final nomBrut = (json['auteur_nom'] as String?)?.trim() ?? '';
    final avatarBrut = (json['auteur_avatar'] as String?)?.trim() ?? '';
    return Publication(
      id: json['id']?.toString() ?? '',
      titre: (json['titre'] ?? '').toString(),
      contenu: (json['contenu'] ?? '').toString(),
      typeInfo: (json['type_info'] ?? 'info').toString(),
      lieu: lieuBrut.isEmpty ? null : lieuBrut,
      photos: photos,
      statut: (json['statut'] ?? 'publie').toString(),
      anonyme: json['anonyme'] == true,
      auteurNom: nomBrut.isEmpty ? null : nomBrut,
      auteurAvatar: avatarBrut.isEmpty ? null : avatarBrut,
      nbLikes: (json['nb_likes'] as num?)?.toInt() ?? 0,
      nbCommentaires: (json['nb_commentaires'] as num?)?.toInt() ?? 0,
      jaiLike: json['jai_like'] == true,
      jePeuxSupprimer: json['je_peux_supprimer'] == true,
      creeA:
          DateTime.tryParse((json['cree_a'] ?? '').toString())?.toLocal() ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> versJson() => {
    'id': id,
    'titre': titre,
    'contenu': contenu,
    'type_info': typeInfo,
    'lieu': lieu,
    'photos': photos,
    'statut': statut,
    'anonyme': anonyme,
    'auteur_nom': auteurNom,
    'auteur_avatar': auteurAvatar,
    'nb_likes': nbLikes,
    'nb_commentaires': nbCommentaires,
    'jai_like': jaiLike,
    'cree_a': creeA.toIso8601String(),
  };
}
