import 'package:flutter/material.dart';

/// Pastille de grade d'un utilisateur (profil d'un ami, listes).
///
/// Elle n'affiche QUE le grade : aucun compteur, aucun nombre de
/// signalements, aucun palier. La progression d'un compte ne se lit pas en
/// chiffres — elle se voit au grade.
class RangSignalementsBadge extends StatelessWidget {
  final String rangNom;
  final String rangCouleur;
  final int niveau;
  final bool compact;

  const RangSignalementsBadge({
    super.key,
    required this.rangNom,
    required this.rangCouleur,
    required this.niveau,
    this.compact = false,
  });

  Color get _couleur {
    try {
      final hex = rangCouleur.replaceAll('#', '');
      return Color(int.parse('FF$hex', radix: 16));
    } catch (_) {
      return Colors.grey;
    }
  }

  IconData get _icone {
    switch (rangNom) {
      case 'Légende':
        return Icons.emoji_events;
      case 'Expert':
        return Icons.military_tech;
      case 'Gardien':
        return Icons.security;
      case 'Sentinelle':
        return Icons.radar;
      case 'Vigilant':
        return Icons.visibility;
      case 'Contributeur':
        return Icons.verified_user;
      case 'Apprenti':
        return Icons.shield_outlined;
      case 'Débutant':
      default:
        return Icons.shield;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _couleur.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _couleur.withValues(alpha: 0.6), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icone, size: 14, color: _couleur),
            const SizedBox(width: 4),
            Text(
              rangNom,
              style: TextStyle(
                color: _couleur,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _couleur.withValues(alpha: 0.18),
            _couleur.withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _couleur.withValues(alpha: 0.8), width: 1.2),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _couleur.withValues(alpha: 0.18),
              shape: BoxShape.circle,
              border: Border.all(
                color: _couleur.withValues(alpha: 0.9),
                width: 1,
              ),
            ),
            child: Icon(_icone, size: 24, color: _couleur),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  rangNom,
                  style: TextStyle(
                    color: _couleur,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Grade $niveau sur 8',
                  style: TextStyle(
                    color: _couleur.withValues(alpha: 0.95),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
