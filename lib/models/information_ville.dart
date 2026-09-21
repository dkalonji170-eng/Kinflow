/// Une information publiée par KinFlow dans le fil de la ville.
/// Les utilisateurs n'écrivent rien : ils réagissent en VERT (info
/// confirmée) ou en ROUGE (info fausse), une réaction par personne.
class InformationVille {
  final String id;
  final String contenu;
  final double? latitude;
  final double? longitude;
  final int nbVerts;
  final int nbRouges;

  /// 'VERT', 'ROUGE', ou null si le visiteur n'a pas encore réagi.
  final String? maReaction;
  final DateTime creeA;

  const InformationVille({
    required this.id,
    required this.contenu,
    this.latitude,
    this.longitude,
    required this.nbVerts,
    required this.nbRouges,
    this.maReaction,
    required this.creeA,
  });

  factory InformationVille.depuisJson(Map<String, dynamic> json) {
    return InformationVille(
      id: json['id'] as String,
      contenu: (json['contenu'] as String?) ?? '',
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      nbVerts: (json['nb_verts'] as num?)?.toInt() ?? 0,
      nbRouges: (json['nb_rouges'] as num?)?.toInt() ?? 0,
      maReaction: json['ma_reaction'] as String?,
      creeA:
          DateTime.tryParse((json['cree_a'] as String?) ?? '')?.toLocal() ??
              DateTime.now(),
    );
  }

  bool get viensDeConfirmer => maReaction == 'VERT';
  bool get viensDeSignaler => maReaction == 'ROUGE';
}