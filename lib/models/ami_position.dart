import 'package:latlong2/latlong.dart';

/// Dernière position connue d'un(e) ami(e), telle qu'affichée sur la carte.
/// Construite à partir d'une ligne renvoyée par la fonction Supabase
/// `mes_amis` : la position est présente dès que le partage est actif, même
/// si le téléphone de l'ami(e) est éteint ou l'appli fermée ([majA] date
/// alors la dernière position enregistrée). [depuisJson] retourne null quand
/// le partage est inactif ou qu'aucune position n'a jamais été enregistrée.
class AmiPosition {
  const AmiPosition({
    required this.id,
    required this.nom,
    required this.position,
    this.avatar,
    this.cap,
    this.majA,
  });

  /// Identité (uuid) de l'ami(e), pour le retirer si besoin.
  final String id;

  /// Prénom + nom, ou libellé de repli.
  final String nom;

  /// Identifiant d'avatar animal (`profiles.avatar`), ou null.
  final String? avatar;

  final LatLng position;

  /// Cap de déplacement en degrés (0 = Nord), si connu.
  final double? cap;

  /// Date de la dernière mise à jour de la position.
  final DateTime? majA;

  /// Construit une position depuis une ligne `mes_amis`. Retourne null quand
  /// aucun partage (ou aucune position enregistrée) n'est disponible.
  static AmiPosition? depuisJson(Map<String, dynamic> json) {
    final latitude = _doubleOuNull(json['latitude']);
    final longitude = _doubleOuNull(json['longitude']);
    if (latitude == null || longitude == null) return null;
    final brut = json['maj_a'];
    return AmiPosition(
      id: json['ami_id']?.toString() ?? '',
      nom: _nomComplet(json),
      avatar: json['avatar'] as String?,
      position: LatLng(latitude, longitude),
      cap: _doubleOuNull(json['cap']),
      majA: brut == null ? null : DateTime.tryParse(brut.toString()),
    );
  }

  /// Prénom + nom, ou un libellé de repli si le profil est vide.
  static String _nomComplet(Map<String, dynamic> profil) {
    final prenom = (profil['prenom'] as String? ?? '').trim();
    final nom = (profil['nom'] as String? ?? '').trim();
    final complet = [prenom, nom].where((s) => s.isNotEmpty).join(' ');
    return complet.isEmpty ? 'Un ami(e)' : complet;
  }

  static double? _doubleOuNull(Object? valeur) {
    if (valeur == null) return null;
    if (valeur is num) return valeur.toDouble();
    return double.tryParse(valeur.toString());
  }
}
