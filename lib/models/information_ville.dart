/// Une information publiée par KinFlow dans le fil de la ville.
/// Les utilisateurs n'écrivent rien : ils réagissent en VERT (info
/// confirmée) ou en ROUGE (info fausse), une réaction par personne,
/// et peuvent déposer un émoji (les plus populaires d'abord).
class InformationVille {
  final String id;
  final String contenu;
  final double? latitude;
  final double? longitude;
  final int nbVerts;
  final int nbRouges;

  /// 'VERT', 'ROUGE', ou null si le visiteur n'a pas encore réagi.
  final String? maReaction;

  /// Émojis déposés sur l'info : (émoji, nombre de réactions), triés par
  /// popularité décroissante.
  final List<(String, int)> emojis;

  /// Les émojis que le visiteur a lui-même déposés sur cette info.
  final Set<String> mesEmojis;

  /// true si KinFlow a épinglé cette info : elle reste en haut du fil.
  final bool epinglee;

  final DateTime creeA;

  const InformationVille({
    required this.id,
    required this.contenu,
    this.latitude,
    this.longitude,
    required this.nbVerts,
    required this.nbRouges,
    this.maReaction,
    this.emojis = const [],
    this.mesEmojis = const {},
    this.epinglee = false,
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
      emojis: _parseEmojis(json['emojis']),
      mesEmojis: _parseMesEmojis(json['mes_emojis']),
      epinglee: json['epinglee'] == true,
      creeA:
          DateTime.tryParse((json['cree_a'] as String?) ?? '')?.toLocal() ??
              DateTime.now(),
    );
  }

  static List<(String, int)> _parseEmojis(Object? valeur) {
    if (valeur is! List) return const [];
    final resultat = <(String, int)>[];
    for (final x in valeur) {
      if (x is! Map) continue;
      final e = x['e'];
      final c = x['c'];
      if (e is String && e.isNotEmpty) {
        resultat.add((e, (c as num?)?.toInt() ?? 0));
      }
    }
    resultat.sort((a, b) => b.$2.compareTo(a.$2));
    return resultat;
  }

  static Set<String> _parseMesEmojis(Object? valeur) {
    if (valeur is! List) return const {};
    return {...valeur.whereType<String>()};
  }

  bool get etreConfirme => maReaction == 'VERT';
  bool get etreSignale => maReaction == 'ROUGE';

  /// Total des réactions (pouces + émojis) : utilisé pour trier par popularité.
  int get nbReactionsTotal =>
      nbVerts + nbRouges + emojis.fold(0, (somme, e) => somme + e.$2);
}