class PlaceInfo {
  final String nom;
  final String type;
  final String categorie;
  final String adresse;
  final String quartier;
  final String rue;
  final double latitude;
  final double longitude;

  PlaceInfo({
    required this.nom,
    required this.type,
    required this.categorie,
    required this.adresse,
    this.quartier = '',
    this.rue = '',
    required this.latitude,
    required this.longitude,
  });

  String get typeFr {
    final traductions = {
      'school': 'École',
      'university': 'Université',
      'college': 'Collège',
      'hospital': 'Hôpital',
      'clinic': 'Clinique',
      'pharmacy': 'Pharmacie',
      'bank': 'Banque',
      'restaurant': 'Restaurant',
      'cafe': 'Café',
      'pub': 'Bar',
      'hotel': 'Hôtel',
      'supermarket': 'Supermarché',
      'marketplace': 'Marché',
      'shop': 'Magasin',
      'mall': 'Centre commercial',
      'church': 'Église',
      'mosque': 'Mosquée',
      'place_of_worship': 'Lieu de culte',
      'library': 'Bibliothèque',
      'museum': 'Musée',
      'theatre': 'Théâtre',
      'cinema': 'Cinéma',
      'stadium': 'Stade',
      'park': 'Parc',
      'government': 'Bâtiment gouvernemental',
      'townhall': 'Mairie',
      'police': 'Commissariat',
      'fire_station': 'Caserne de pompiers',
      'post_office': 'Bureau de poste',
      'embassy': 'Ambassade',
      'office': 'Bureau',
      'house': 'Maison',
      'apartments': 'Immeuble',
      'residential': 'Résidentiel',
      'commercial': 'Commerce',
      'industrial': 'Industriel',
      'public_building': 'Bâtiment public',
      'factory': 'Usine',
      'warehouse': 'Entrepôt',
      'cathedral': 'Cathédrale',
      'monument': 'Monument',
      'memorial': 'Mémorial',
      'station': 'Gare',
      'airport': 'Aéroport',
      'bus_station': 'Gare routière',
      'taxi': 'Station de taxi',
      'parking': 'Parking',
      'fuel': 'Station-service',
      'car_wash': 'Lavage auto',
      'car_repair': 'Garage',
    };
    return traductions[type] ?? type;
  }

  bool get estBatiment =>
      categorie != 'highway' &&
      categorie != 'railway' &&
      categorie != 'waterway' &&
      type != 'residential' &&
      type != 'road' &&
      type != 'street';
}
