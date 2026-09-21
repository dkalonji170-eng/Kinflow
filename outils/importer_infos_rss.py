#!/usr/bin/env python3
"""Robot RSS du « Fil Social » de KinFlow.

Lit les flux RSS des médias congolais, garde les articles pertinents
(Kinshasa + actualité nationale utile, hors guerre à l'Est et hors autres
villes/provinces) et les publie dans le fil Social via Supabase (fonction
publier_infos_rss). Un même article ne passe qu'une fois.

Usage :
  CLE_IMPORT_RSS=<clé> python3 outils/importer_infos_rss.py

(SUPABASE_URL et SUPABASE_ANON_KEY sont réglés par défaut sur le projet
KinFlow ; ils peuvent être surchargés par des variables d'environnement.)

Programmé dans .github/workflows/importer_infos.yml (toutes les 30 minutes).
"""

import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

# Flux RSS des médias congolais qui couvrent Kinshasa.
FLUX = [
    ("Radio Okapi", "https://www.radiookapi.net/rss.xml"),
    ("Actualite.cd", "https://actualite.cd/feed"),
    ("LePotentiel.cd", "https://lepotentiel.cd/feed"),
]

# À noter :
# - Beto.cd, Mediacongo.net et 7sur7.cd n'ont pas de flux RSS accessible
#   (protection anti-robot ou pas de flux) : leurs infos restent à publier
#   manuellement via le Table Editor Supabase.

# Un article est retenu s'il :
#   1) parle de Kinshasa (ou d'un de ses quartiers), OU
#   2) parle du pays en général (mots nationaux / vie de la ville) ET ne
#      concerne pas la guerre à l'Est ni une autre ville/province.
LIEUX_KINSHASA = [
    "kinshasa", "ngaliema", "ngaba", "masina", "ndjili", "limete",
    "bandalungwa", "kintambo", "gombe", "barumbu", "kisenso",
    "ngafula", "selembao", "ngiri", "matonge", "binza", "kingabwa",
    "nsele", "maluku", "lukunga", "makala", "bumbu", "kalamu",
    "lingwala", "kalamu", "funa", "tchad",
]

SIGNES_NATION = [
    "rdc", "rd congo", "republique democratique du congo",
    "congolais", "congolaise", "leopards",
]

SIGNES_VIE_KINOISE = [
    "snel", "regideso", "voirie", "bitumage", "rond-point",
    "boulevard", "avenue",
]

# Sujets hors sujet pour ce fil : guerre à l'Est, autres villes/provinces,
# Congo-Brazzaville. Un article « Kinshasa » qui les mentionne reste gardé.
ZONES_A_ECARTER = [
    # Guerre / Est du pays (expressions puis lieux)
    "est de la rdc", "dans l'est", "a l'est", "est du pays",
    "de l'est", "nord-est", "sud-est", "au nord-est",
    "kivu", "goma", "bukavu", "beni", "ituri", "rutshuru", "masisi",
    "walikale", "lubero", "bunia", "uvira", "fizi", "mwenga", "butembo",
    "nyiragongo", "kalehe", "minova", "kanya bayonga", "kamango",
    # Autres grandes villes / provinces
    "lubumbashi", "likasi", "kolwezi", "kisangani", "mbuji-mayi",
    "kananga", "matadi", "boma", "moanda", "mbandaka", "gbadolite",
    "gemena", "isiro", "buta", "kalemie", "kindu", "kikwit", "kenge",
    "tshikapa", "ilebo", "kamina", "kabinda", "kaniama", "tshela",
    "kimpese", "mbanza-ngungu", "inho", "boende", "lisala", "bumba",
    "basankusu", "aketi", "opala", "yangambi", "basoko", "tshudi-loto",
    "katako-kombe", "lodja", "lusambo", "mwene-ditu", "kabalo", "kongolo",
    # Provinces / autres pays frontaliers fréquents dans les titres
    "katanga", "kasai", "maniema", "tshopo", "kwilu", "kwango",
    "mai-ndombe", "sankuru", "lomami", "tanganyika", "haut-katanga",
    "haut-lomami", "lualaba", "sud-ubangi", "nord-ubangi", "equateur",
    "bandundu", "kongo central", "brazzaville", "congo-brazzaville",
    "angola", "zambie", "rwanda", "ouganda", "burundi", "soudan du sud",
    "cameroun", "gabon", "republique centrafricaine", "tanzanie",
]

# Un vrai titre d'info fait plus de 20 caractères : élimine les articles
# factices type « 2026 Kinshasa » présents sur certains flux.
LONGUEUR_MIN = 20

# Taille max d'une info dans l'app.
TAILLE_MAX = 500

SUPABASE_URL = os.environ.get(
    "SUPABASE_URL", "https://qosznioaonumbdjhiwuj.supabase.co"
)
SUPABASE_ANON_KEY = os.environ.get(
    "SUPABASE_ANON_KEY", "sb_publishable_V4nWfOHrOlBvN8G6Kfh1XA_1AUCF7n3"
)
CLE_IMPORT_RSS = os.environ.get("CLE_IMPORT_RSS", "")


def _nom_local(tag: str) -> str:
    """Nom de balise sans le préfixe d'espace de noms XML."""
    return tag.rsplit("}", 1)[-1]


def sans_accents(texte: str) -> str:
    """Minuscules sans accents pour chercher des mots-clés."""
    texte = texte.lower()
    texte = "".join(
        c for c in unicodedata.normalize("NFD", texte)
        if unicodedata.category(c) != "Mn"
    )
    return texte


def concerne_kinshasa_ou_pays(texte: str) -> bool:
    t = sans_accents(texte)
    if any(mot in t for mot in LIEUX_KINSHASA):
        return True
    if any(mot in t for mot in ZONES_A_ECARTER):
        return False
    return any(mot in t for mot in SIGNES_NATION) or any(
        mot in t for mot in SIGNES_VIE_KINOISE
    )


def nettoyer(texte: str) -> str:
    """Enlève balises HTML et entités, condense les espaces, tronque."""
    texte = re.sub(r"<[^>]+>", " ", texte or "")
    texte = re.sub(r"&(amp|#0?39|apos);", "'", texte)
    texte = re.sub(r"&(quot|#34);", '"', texte)
    texte = re.sub(r"&lt;", "<", texte)
    texte = re.sub(r"&gt;", ">", texte)
    texte = re.sub(r"&#x?[0-9a-fA-F]+;", " ", texte)
    texte = re.sub(r"\s+", " ", texte).strip()
    return texte[:TAILLE_MAX]


def _reparer_entites(donnees: bytes) -> bytes:
    """Certains flux contiennent des entités XML non déclarées (&scaron;…).
    On échappe les & qui ne forment pas une entité XML valide."""
    texte = donnees.decode("utf-8", "replace")
    texte = re.sub(
        r"&(?!(?:#\d+|#x[0-9a-fA-F]+|amp|lt|gt|quot|apos);)", "&amp;", texte
    )
    return texte.encode("utf-8")


def lire_flux(url: str):
    req = urllib.request.Request(
        url, headers={"User-Agent": "KinFlowBot/1.0 (fil social)"}
    )
    with urllib.request.urlopen(req, timeout=25) as rep:
        return rep.read()


def articles_du_flux(url: str):
    """Retourne la liste des (titre, lien) du flux RSS."""
    donnees = lire_flux(url)
    racine = ET.fromstring(_reparer_entites(donnees))
    resultats = []
    for noeud in racine.iter():
        if _nom_local(noeud.tag) != "item":
            continue
        titre = ""
        lien = ""
        for enfant in noeud:
            nom = _nom_local(enfant.tag)
            if nom == "title" and not titre:
                titre = enfant.text or ""
            elif nom == "link" and not lien:
                lien = enfant.text or ""
        if titre:
            resultats.append((titre, lien))
    return resultats


def publier(contenu: str, url_src: str):
    """Appelle publier_infos_rss. True = publié, False = déjà connu, None = erreur."""
    corps = json.dumps({
        "p_contenu": contenu,
        "p_url": url_src,
        "p_cle": CLE_IMPORT_RSS,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/rpc/publier_infos_rss",
        data=corps,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "apikey": SUPABASE_ANON_KEY,
            "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as rep:
            brut = rep.read().decode("utf-8", "replace").strip().lower()
        return brut == "true"
    except urllib.error.URLError as e:
        print(f"    échec réseau : {e}")
        return None


def nettoyer_anciennes():
    """Supprime les infos de plus de 3 jours (recyclage du fil).
    Retourne le nombre supprimé."""
    if not CLE_IMPORT_RSS:
        return 0
    corps = json.dumps({"p_cle": CLE_IMPORT_RSS}).encode("utf-8")
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/rpc/nettoyer_anciennes_infos",
        data=corps,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "apikey": SUPABASE_ANON_KEY,
            "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as rep:
            brut = rep.read().decode("utf-8", "replace").strip()
        return int(brut) if brut.isdigit() else 0
    except urllib.error.URLError as e:
        print(f"    échec nettoyage : {e}")
        return 0


def main():
    if not CLE_IMPORT_RSS:
        print("Aucune clé CLE_IMPORT_RSS fournie : rien n'a été importé.")
        sys.exit(2)

    publies = 0
    deja_connus = 0
    echoues = 0
    vus = set()

    for media, url in FLUX:
        try:
            articles = articles_du_flux(url)
        except Exception as e:  # noqa: BLE001 — le robot continue sans mourir
            echoues += 1
            print(f"[{media}] échec de lecture : {e}")
            continue

        ajoutes = 0
        for titre, lien in articles:
            propre = nettoyer(titre)
            if len(propre) < LONGUEUR_MIN or not concerne_kinshasa_ou_pays(propre):
                continue
            cle_unique = propre.lower()
            if cle_unique in vus:
                continue
            vus.add(cle_unique)
            ok = publier(propre, lien)
            if ok is True:
                publies += 1
                ajoutes += 1
            elif ok is False:
                deja_connus += 1
            else:
                echoues += 1
        print(f"[{media}] {len(articles)} articles lus, {ajoutes} nouveaux publiés.")

    print(
        f"Résumé : {publies} publié(s), {deja_connus} déjà connu(s), "
        f"{echoues} erreur(s)."
    )

    recyclage = nettoyer_anciennes()
    print(f"Recyclage : {recyclage} ancienne(s) info(s) supprimée(s).")

    sys.exit(0 if echoues == 0 else 1)


if __name__ == "__main__":
    main()