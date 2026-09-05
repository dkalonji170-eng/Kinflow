class SearchResult {

  final String nom;
  final String sousTitre;
  final double latitude;
  final double longitude;

  SearchResult({
    required this.nom,
    this.sousTitre = '',
    required this.latitude,
    required this.longitude,
  });

}