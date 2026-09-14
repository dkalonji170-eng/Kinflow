// Peintres custom de la carte : épingle « goutte » et pin d'étape.
// Extraits de `traffic_map.dart` pour alléger le widget principal.
import 'dart:math' show acos, atan2, cos, sin;

import 'package:flutter/material.dart';

/// Peint une épingle « goutte » classique : corps en couleur, aiguille grise
/// au centre, pointe effilée vers le bas.
class PeintreEpingle extends CustomPainter {
  final Color couleur;

  PeintreEpingle(this.couleur);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final centreX = w / 2;
    final rayon = w * 0.30;
    final centreCorps = Offset(centreX, h * 0.30);
    final pointe = Offset(centreX, h);
    final d = pointe.dy - centreCorps.dy;
    final theta = acos((rayon / d).clamp(-1.0, 1.0));
    final tj1 = Offset(
      centreCorps.dx - rayon * sin(theta),
      centreCorps.dy + rayon * cos(theta),
    );
    final tj2 = Offset(
      centreCorps.dx + rayon * sin(theta),
      centreCorps.dy + rayon * cos(theta),
    );

    final corps = Path()
      ..moveTo(tj1.dx, tj1.dy)
      ..lineTo(pointe.dx, pointe.dy)
      ..lineTo(tj2.dx, tj2.dy)
      ..arcTo(
        Rect.fromCircle(center: centreCorps, radius: rayon),
        atan2(tj2.dy - centreCorps.dy, tj2.dx - centreCorps.dx),
        2 * theta,
        false,
      )
      ..close();

    // Corps en relief : dégradé radial (source de lumière en haut à gauche)
    // pour un effet sphérique 3D, puis reflet spéculaire.
    final corps3d = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.38, -0.45),
        radius: 1.05,
        colors: [
          _eclaircir(couleur, 0.28),
          couleur,
          _assombrir(couleur, 0.25),
        ],
      ).createShader(
        Rect.fromCircle(center: centreCorps, radius: rayon * 1.7),
      );
    canvas.drawPath(corps, corps3d);

    // Liseré sombre sur le bas/contour pour détacher du fond.
    canvas.drawPath(
      corps,
      Paint()
        ..color = _assombrir(couleur, 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Reflet spéculaire (éclat) en haut à gauche du corps.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centreCorps.dx - rayon * 0.35, centreCorps.dy - rayon * 0.5),
        width: rayon * 0.62,
        height: rayon * 0.28,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );

    // Aiguille grise au centre du corps : anneau foncé + cœur clair.
    final centreAiguille = Offset(centreX, centreCorps.dy);
    canvas.drawCircle(
      centreAiguille,
      rayon * 0.34,
      Paint()..color = const Color(0xFF757575),
    );
    canvas.drawCircle(
      centreAiguille,
      rayon * 0.26,
      Paint()..color = const Color(0xFFBDBDBD),
    );
    canvas.drawCircle(
      centreAiguille,
      rayon * 0.20,
      Paint()..color = const Color(0xFFE0E0E0),
    );
  }

  @override
  bool shouldRepaint(covariant PeintreEpingle oldDelegate) =>
      oldDelegate.couleur != couleur;
}

Color _eclaircir(Color c, double delta) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
}

Color _assombrir(Color c, double delta) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness((hsl.lightness - delta).clamp(0.0, 1.0)).toColor();
}

/// Pin d'étape « Ajouter à l'itinéraire » : une goutte ambre en relief comme
/// l'épingle, surmontée d'un badge blanc numéroté pour la distinguer du point
/// vert de destination. La pointe en bas sert d'ancre géographique.
class PeintreEtape extends CustomPainter {
  final Color couleur;
  final String numero;

  PeintreEtape(this.couleur, this.numero);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final centreX = w / 2;
    final rayon = w * 0.30;
    final centreCorps = Offset(centreX, h * 0.30);
    final pointe = Offset(centreX, h);
    final d = pointe.dy - centreCorps.dy;
    final theta = acos((rayon / d).clamp(-1.0, 1.0));
    final tj1 = Offset(
      centreCorps.dx - rayon * sin(theta),
      centreCorps.dy + rayon * cos(theta),
    );
    final tj2 = Offset(
      centreCorps.dx + rayon * sin(theta),
      centreCorps.dy + rayon * cos(theta),
    );

    final corps = Path()
      ..moveTo(tj1.dx, tj1.dy)
      ..lineTo(pointe.dx, pointe.dy)
      ..lineTo(tj2.dx, tj2.dy)
      ..arcTo(
        Rect.fromCircle(center: centreCorps, radius: rayon),
        atan2(tj2.dy - centreCorps.dy, tj2.dx - centreCorps.dx),
        2 * theta,
        false,
      )
      ..close();

    final corps3d = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.38, -0.45),
        radius: 1.05,
        colors: [
          _eclaircir(couleur, 0.28),
          couleur,
          _assombrir(couleur, 0.25),
        ],
      ).createShader(
        Rect.fromCircle(center: centreCorps, radius: rayon * 1.7),
      );
    canvas.drawPath(corps, corps3d);

    canvas.drawPath(
      corps,
      Paint()
        ..color = _assombrir(couleur, 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Badge blanc numéroté au centre du corps.
    final centreBadge = Offset(centreX, centreCorps.dy);
    canvas.drawCircle(
      centreBadge,
      rayon * 0.62,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      centreBadge,
      rayon * 0.62,
      Paint()
        ..color = _assombrir(couleur, 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    final texte = TextPainter(
      text: TextSpan(
        text: numero,
        style: TextStyle(
          color: couleur,
          fontSize: rayon * 1.05,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    texte.paint(
      canvas,
      Offset(
        centreBadge.dx - texte.width / 2,
        centreBadge.dy - texte.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant PeintreEtape oldDelegate) =>
      oldDelegate.couleur != couleur || oldDelegate.numero != numero;
}