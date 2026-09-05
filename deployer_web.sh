#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# KinFlow — Déploiement du site web
# ---------------------------------------------------------------------------
# Usage :
#   ./deployer_web.sh zip      → reconstruit le site et crée "kinflow-web.zip"
#                                (prêt à glisser-déposer sur netlify.com)
#   ./deployer_web.sh pages    → reconstruit et pousse vers GitHub Pages
#                                (nécessite d'abord : git remote add origin <url>)
#
# Quand tu modifies le code, relance ce script : tout le monde verra alors la
# nouvelle version (aucune action côté utilisateur).
# ---------------------------------------------------------------------------
set -e

cd "$(dirname "$0")"

echo "▶ Compilation du site web..."
flutter build web

ZIP="kinflow-web.zip"
if [ "$1" = "zip" ] || [ -z "$1" ]; then
  echo "▶ Création de $ZIP (prêt pour Netlify / Vercel)..."
  rm -f "$ZIP"
  cd build/web
  if command -v zip >/dev/null 2>&1; then
    zip -rq "../../$ZIP" .
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import zipfile, os, sys
z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED)
for root, dirs, files in os.walk('.'):
    for f in files:
        p = os.path.join(root, f)
        z.write(p, os.path.relpath(p, '.'))
z.close()
" "../../$ZIP"
  else
    tar -czf "../../$ZIP" .
  fi
  cd ../..
  echo "✓ Terminé ! Dépose $ZIP sur https://app.netlify.com/drop"
  exit 0
fi

if [ "$1" = "pages" ]; then
  echo "▶ Publication sur GitHub Pages ($(git remote get-url origin 2>/dev/null))..."
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "✗ Aucun dépôt distant."
    echo "  D'abord :  git remote add origin https://github.com/dkalonji170-eng/kinflow.git"
    exit 1
  fi

  # 1) On commite le code source et on le pousse (historique des versions).
  git add -A
  git commit -m "KinFlow $(date '+%Y-%m-%d %H:%M')" || true
  git push -u origin master 2>&1 | tail -3 || true

  # 2) La branche "gh-pages" ne contient que le site compilé (build/web/).
  #    GitHub Pages la sert tel quel, donc on renouvelle son contenu.
  echo "▶ Mise à jour de la branche gh-pages (le site web)..."
  if git show-ref --verify --quiet refs/heads/gh-pages; then
    git checkout gh-pages
    git rm -rq --ignore-unmatch -- . 2>/dev/null || true
  else
    git checkout --orphan gh-pages
  fi
  cp -f -r ../build/web/* .
  git add -A
  git commit -m "Site web KinFlow $(date '+%Y-%m-%d %H:%M')" || true
  git push -u origin gh-pages 2>&1 | tail -3
  git checkout master

  echo ""
  echo "✓ Site poussé sur GitHub Pages !"
  echo "  Active la publication (1 seule fois) ici :"
  echo "    https://github.com/dkalonji170-eng/kinflow/settings/pages"
  echo "  → Source : 'Deploy from a branch' → branche 'gh-pages' → / (root)"
  echo "  Votre site sera en ligne sur :"
  echo "    https://dkalonji170-eng.github.io/kinflow/"
  exit 0
fi

echo "Usage : ./deployer_web.sh zip | pages"
exit 1