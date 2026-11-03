/// Un commentaire (ou une réponse) sur un reportage.
///
/// `parent` non nul = réponse à un autre commentaire. Un commentaire anonyme
/// masque le nom et l'avatar : l'interface affiche « Anonyme ».
class Commentaire {
  const Commentaire({
    required this.id,
    required this.contenu,
    required this.creeA,
    this.parent,
    this.anonyme = false,
    this.auteurNom,
    this.auteurAvatar,
    this.nbReactions = 0,
    this.monEmoji,
    this.jePeuxSupprimer = false,
  });

  final String id;
  final String? parent;
  final String contenu;
  final DateTime creeA;
  final bool anonyme;
  final String? auteurNom;
  final String? auteurAvatar;
  final int nbReactions;

  /// L'emoji que j'ai posé sur ce commentaire (un seul par personne).
  final String? monEmoji;

  final bool jePeuxSupprimer;

  bool get estReponse => parent != null && parent!.isNotEmpty;

  String get nomAffiche {
    final nom = auteurNom?.trim() ?? '';
    return anonyme || nom.isEmpty ? 'Anonyme' : nom;
  }

  Commentaire copyWith({
    int? nbReactions,
    String? monEmoji,
    bool retirerEmoji = false,
  }) {
    return Commentaire(
      id: id,
      parent: parent,
      contenu: contenu,
      creeA: creeA,
      anonyme: anonyme,
      auteurNom: auteurNom,
      auteurAvatar: auteurAvatar,
      nbReactions: nbReactions ?? this.nbReactions,
      monEmoji: retirerEmoji ? null : (monEmoji ?? this.monEmoji),
      jePeuxSupprimer: jePeuxSupprimer,
    );
  }

  factory Commentaire.depuisJson(Map<String, dynamic> json) {
    final nomBrut = (json['auteur_nom'] as String?)?.trim() ?? '';
    final avatarBrut = (json['auteur_avatar'] as String?)?.trim() ?? '';
    final emojiBrut = (json['mon_emoji'] as String?)?.trim() ?? '';
    final parentBrut = json['parent']?.toString().trim() ?? '';
    return Commentaire(
      id: json['id']?.toString() ?? '',
      parent: parentBrut.isEmpty ? null : parentBrut,
      contenu: (json['contenu'] ?? '').toString(),
      creeA:
          DateTime.tryParse((json['cree_a'] ?? '').toString())?.toLocal() ??
          DateTime.now(),
      anonyme: json['anonyme'] == true,
      auteurNom: nomBrut.isEmpty ? null : nomBrut,
      auteurAvatar: avatarBrut.isEmpty ? null : avatarBrut,
      nbReactions: (json['nb_reactions'] as num?)?.toInt() ?? 0,
      monEmoji: emojiBrut.isEmpty ? null : emojiBrut,
      jePeuxSupprimer: json['je_peux_supprimer'] == true,
    );
  }
}
