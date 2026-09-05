#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# KinFlow — Déploiement du site web
# ---------------------------------------------------------------------------
# Usage :
#   ./deployer_web.sh            → identique à "netlify" (recommandé)
#   ./deployer_web.sh netlify    → compile, publie la branche "gh-pages" avec
#                                  uniquement le site compilé. Netlify (connecté
#                                  au dépôt GitHub) déploie alors automatiquement.
#   ./deployer_web.sh pages      → alias de "netlify"
#   ./deployer_web.sh zip        → compile et crée "kinflow-web.zip"
#                                  (à déposer sur app.netlify.com/drop si besoin)
#
# Quand tu modifies le code, relance : ./deployer_web.sh
# Le site se mettra à jour tout seul (aucune action côté utilisateur).
# ---------------------------------------------------------------------------
set -e

cd "$(dirname "$0")"

echo "▶ Compilation du site web..."
flutter build web

ZIP="kinflow-web.zip"
if [ "$1" = "zip" ]; then
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

# ---------------------------------------------------------------------------
# Publication du site (Netlify connecté au dépôt GitHub)
# ---------------------------------------------------------------------------
if [ "$1" = "netlify" ] || [ "$1" = "pages" ] || [ -z "$1" ]; then
  echo "▶ Publication du site web sur GitHub ($(git remote get-url origin 2>/dev/null))..."
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "✗ Aucun dépôt distant."
    echo "  D'abord :  git remote add origin https://github.com/dkalonji170-eng/kinflow.git"
    exit 1
  fi

  # 1) Historique du code source sur "master".
  git add -A
  git commit -m "KinFlow $(date '+%Y-%m-%d %H:%M')" || true
  git push -u origin master 2>&1 | tail -3 || true

  # 2) Reconstruit la branche "gh-pages" avec UNIQUEMENT le site compilé,
  #    dans un répertoire de travail temporaire (le code source reste intact).
  TMP_DIR=$(mktemp -d)
  rm -f "$TMP_DIR/.keep" 2>/dev/null || true
  if git show-ref --verify --quiet refs/heads/gh-pages; then
    git worktree add "$TMP_DIR" gh-pages >/dev/null 2>&1 || TMP_DIR_EXISTS=1
  else
    git worktree add --detach "$TMP_DIR" >/dev/null 2>&1 || TMP_DIR_EXISTS=1
  fi

  if [ -n "$TMP_DIR_EXISTS" ]; then
    echo "✗ Impossible de préparer la branche gh-pages."
    rm -rf "$TMP_DIR"
    exit 1
  fi

  (
    cd "$TMP_DIR"
    if git show-ref --verify --quiet refs/heads/gh-pages 2>/dev/null; then
      git rm -rq --ignore-unmatch -- . 2>/dev/null || true
      find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf -- {} +
    fi
    cp -r "$OLDPWD/build/web/." .
    git add -A
    git commit -m "Site web KinFlow $(date '+%Y-%m-%d %H:%M')" || true
    git push -u origin gh-pages 2>&1 | tail -3
  )
  git worktree remove --force "$TMP_DIR"

  echo ""
  echo "✓ Site compilé et envoyé sur la branche gh-pages !"
  echo "  Netlify déploie automatiquement ; ton site sera à jour dans ~1 min sur :"
  echo "    https://kinflow.netlify.app"
  exit 0
fi

echo "Usage : ./deployer_web.sh [netlify|pages|zip]"
exit 1