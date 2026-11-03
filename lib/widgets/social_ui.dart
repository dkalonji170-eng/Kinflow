import 'package:flutter/material.dart';

import '../theme/kinflow_theme.dart';

/// Boîte à outils visuelle de la section Sociale : dégradés, ombres, en-tête,
/// pastilles de statistiques, squelettes de chargement et états vides.
///
/// Tout est volontairement simple et très lisible (grandes zones tactiles,
/// contrastes forts, libellés en français) pour convenir à tous les âges.
abstract final class SocialUI {
  /// Dégradé vert de l'en-tête (marque KinFlow).
  static const LinearGradient degradeEntete = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [KinColors.primaryFonce, KinColors.primary, KinColors.primaryClair],
  );

  /// Dégradé ambre de mise en avant (nouvelles infos, épinglé).
  static const LinearGradient degradeAccent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [KinColors.accent, KinColors.accentTranche],
  );

  /// Ombre douce et moderne pour les cartes.
  static List<BoxShadow> ombreDouce({Color? teinte, double opacite = 0.07}) {
    final couleur = teinte ?? Colors.black;
    return [
      BoxShadow(
        color: couleur.withValues(alpha: opacite),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ];
  }

  /// Rayon standard des grandes cartes.
  static const double rayonCarte = 20;
}

/// Fait scintiller son [child] : un reflet clair traverse le contenu en boucle.
/// Utilisé pour les squelettes de chargement (bien plus agréable qu'un simple
/// rond qui tourne).
class Scintillement extends StatefulWidget {
  const Scintillement({super.key, required this.child});

  final Widget child;

  @override
  State<Scintillement> createState() => _ScintillementState();
}

class _ScintillementState extends State<Scintillement>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controleur = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _controleur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.colorScheme.surfaceContainerHighest;
    final reflet = Color.alphaBlend(
      theme.colorScheme.surface.withValues(alpha: 0.75),
      base,
    );
    return AnimatedBuilder(
      animation: _controleur,
      builder: (context, enfant) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) => LinearGradient(
          colors: [base, reflet, base],
          stops: const [0.35, 0.5, 0.65],
          transform: _GlissementDegrade(_controleur.value),
        ).createShader(rect),
        child: enfant,
      ),
      child: widget.child,
    );
  }
}

class _GlissementDegrade extends GradientTransform {
  const _GlissementDegrade(this.valeur);

  final double valeur;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * (valeur * 2 - 1) * 1.4,
      0,
      0,
    );
  }
}

/// Un rectangle gris arrondi utilisé dans les squelettes de chargement.
class BlocSquelette extends StatelessWidget {
  const BlocSquelette({
    super.key,
    this.largeur,
    this.hauteur = 12,
    this.rayon = 8,
    this.forme = BoxShape.rectangle,
  });

  final double? largeur;
  final double hauteur;
  final double rayon;
  final BoxShape forme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: largeur,
      height: hauteur,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        shape: forme,
        borderRadius: forme == BoxShape.circle
            ? null
            : BorderRadius.circular(rayon),
      ),
    );
  }
}

/// Titre de section avec un sous-titre optionnel et un élément à droite.
class TitreSection extends StatelessWidget {
  const TitreSection({
    super.key,
    required this.titre,
    this.sousTitre,
    this.trailing,
    this.icone,
  });

  final String titre;
  final String? sousTitre;
  final Widget? trailing;
  final IconData? icone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icone != null) ...[
          Icon(icone, size: 20, color: KinColors.primary),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titre,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (sousTitre != null)
                Text(
                  sousTitre!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// État vide soigné : une icône dans une pastille colorée, un titre, un
/// message et une action facultative.
class EspaceVideSocial extends StatelessWidget {
  const EspaceVideSocial({
    super.key,
    required this.icone,
    required this.titre,
    required this.message,
    this.action,
    this.couleur,
  });

  final IconData icone;
  final String titre;
  final String message;
  final Widget? action;
  final Color? couleur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final teinte = couleur ?? KinColors.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    teinte.withValues(alpha: 0.22),
                    teinte.withValues(alpha: 0.08),
                  ],
                ),
              ),
              child: Icon(icone, size: 46, color: teinte),
            ),
            const SizedBox(height: 18),
            Text(
              titre,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
