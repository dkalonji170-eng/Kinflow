#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# KinFlow — Déploiement sans GitHub (option : TOKEN INTROUVABLE / révoqué)
# ---------------------------------------------------------------------------
# Usage :  ./deployer_zap.sh
#   Compile le site Flutter, le mets dans kinflow-web.zip, puis affiche
#   les 3 étapes pour le mettre en ligne sur app.netlify.com/drop
#   (aucun token GitHub requis).
set -e

cd "$(dirname "$0")"

echo "▶ Compilation finale du site web..."
flutter build web

echo "▶ Création de kinflow-web.zip..."
ZIP="kinflow-web.zip"
rm -f "$ZIP"
cd build/web
# Intègre la carte claire (si présente) servie à la racine.
for src in ../kinshasa.fmtc ../../assets/kinshasa.fmtc; do
  if [ -s "$src" ]; then
    cp "$src" ./kinshasa.fmtc
    echo "  ✓ Carte claire incluse ($src)"
    break
  fi
done
if command -v zip >/dev/null 2>&1; then
  zip -rq "../../$ZIP" .
else
  python3 -c "
import zipfile, os, sys
z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED)
for root, dirs, files in os.walk('.'):
    for f in files:
        p = os.path.join(root, f)
        z.write(p, os.path.relpath(p, '.'))
z.close()
" "../../$ZIP"
fi
cd ../..

echo ""
echo "✓ Terminé → $ZIP"
echo ""
echo "  3 étapes pour mettre en ligne (SANS GitHub) :"
echo "    1. Ouvre https://app.netlify.com/drop"
echo "    2. Glisse-dépose le fichier $ZIP"
echo "    3. Attends ~1 minute (adresse style https://xxx.netlify.app)"
echo ""
echo "  ⚠ La carte claire est téléchargée sur le site (kinflow .fmtc)."
