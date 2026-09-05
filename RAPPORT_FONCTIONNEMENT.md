# KinFlow — Rapport complet de fonctionnement

> Document de référence : décrit **ce qui fait fonctionner l'application en dehors du code** :
> les services en ligne, les comptes, les urls, les clés, le déploiement, la base de données.
> Garde-le précieusement : si tu perds la discussion, ce fichier te permet de tout reconstruire.

Date de rédaction : 5 septembre 2026.
Version de l'app (pubspec.yaml) : `1.0.0+1`.

---

## 1. Vue d'ensemble — les acteurs de l'écosystème

KinFlow est une application de **carte-trafic collaboratif** (signalements d'état de route,
itinéraires, cartographie, détection de la circulation à Kinshasa). Elle repose sur **6 acteurs extérieurs** :

| # | Acteur | Rôle | URL | Coût |
|---|--------|------|-----|------|
| 1 | **Supabase** | Base de données + authentification anonyme (le « cerveau » des données) | https://qosznioaonumbdjhiwuj.supabase.co | Gratuit (plan Free) |
| 2 | **GitHub** | Hébergement du code source et du site compilé | https://github.com/dkalonji170-eng/kinflow | Gratuit (dépôt privé) |
| 3 | **Netlify** | Hébergeur du site web accessible au public | https://kinflow.netlify.app | Gratuit (plan Free) |
| 4 | **Cartographie (tuiles)** | Les fonds de carte (OpenStreetMap, satellites, sombre) | voir §6 | Gratuit (licences à respecter) |
| 5 | **Itinéraire & géocodage** | Calcul de routes (OSRM), recherche d'adresses (Photon, Nominatim, Overpass) | voir §7 | Gratuit |
| 6 | **Flutter** | Le framework qui compile le code en site web | local, installé sur la machine de dev | Gratuit |

Quand quelqu'un ouvre `https://kinflow.netlify.app`, il reçoit le site compilé (HTML + JavaScript).
Ce JavaScript appelle directement, depuis le **navigateur du visiteur** : Supabase (données),
les serveurs de cartes et les services d'itinéraire/géocodage.

---

## 2. Comptes et identifiants — LE POINT CRITIQUE

### 2.1 Compte GitHub
- **Nom d'utilisateur** : `dkalonji170-eng`
- **Adresse email** : `dkalonji170-eng@users.noreply.github.com` (email privé de GitHub)
- **Email de connexion** (fourni à GitHub) : `dkalonji170@gmail.com`
- **Mot de passe du compte** : celui que tu as défini sur GitHub — **non connu du rapport**
  (retrouvable via « Mot de passe oublié » sur github.com). Pense à le garder dans un gestionnaire de mots de passe.
- **Dépôt** : `dkalonji170-eng/kinflow` → https://github.com/dkalonji170-eng/kinflow
  - **Visibilité : PRIVÉ** (important : NE JAMAIS LE PASSER EN PUBLIC, voir §9).
  - Branche **`master`** : le code source (modifications, historique).
  - Branche **`gh-pages`** : le site web **déjà compilé** (38 fichiers, uniquement le site).

### 2.2 Jeton d'accès GitHub (SENSIBLE — à ne jamais diffuser)
- **Type** : token classique (« classic »), autorisation `repo`.
- **Valeur** : limitée ici volontairement — voir le fichier `~/.git-credentials` de la machine de dev.
  ⚠️ Ce token donne un accès **en écriture à ton dépôt GitHub**. C'est une clé d'accès, pas un mot de passe de compte.
- **Où il est stocké sur la machine de dev** :
  - `~/.git-credentials` (fichier texte, mode 600) — utilisé automatiquement par git pour pousser le code.
- **Comment le révoquer (à faire si tu le communiques à quelqu'un)** :
  https://github.com/settings/tokens → supprimer le token « kinflow » → puis générer un nouveau token
  (même paramètres : note « kinflow », case `repo`) et remplacer la ligne dans `~/.git-credentials`.

### 2.3 Compte Netlify
- **Pas de mot de passe séparé** : l'accès se fait par **« Sign up with GitHub »** (OAuth).
  Pour te connecter : https://app.netlify.com → « Login with GitHub » → ton compte `dkalonji170-eng`.
- **Équipe / site** : « kinflow » (site racine du compte).
- **URL publique du site** : **https://kinflow.netlify.app**

### 2.4 Compte Supabase
- **Code projet (ref)** : `qosznioaonumbdjhiwuj`
- **URL du projet** : https://qosznioaonumbdjhiwuj.supabase.co
- **Tableau de bord (admin)** : https://supabase.com/dashboard/project/qosznioaonumbdjhiwuj
- **Mot de passe du tableau de bord** : celui créé à la création du projet — **non connu du rapport**
  (« Mot de passe oublié » possible). Donne accès à toute la base ; très sensible.
- **Identifiants d'API** visibles dans le dashboard → `Settings` → `API` :
  - *URL de projet* (la même que ci-dessus).
  - *« publishable key »* (clé anon) : **VISIBLE DANS LE CODE** — c'est normal, c'est fait pour.
    Valeur : `sb_publishable_V4nWfOHrOlBvN8G6Kfh1XA_1AUCF7n3`
  - *`service_role` key* : **SECRÈTE**, seule clé qui contourne la sécurité. N'apparaît PAS dans le code
    et ne doit JAMAIS y apparaître. À ne partager avec personne.

### 2.5 Fichier de configuration Supabase (dans le code)
Fichier : `lib/config/supabase_config.dart`
```dart
url     = 'https://qosznioaonumbdjhiwuj.supabase.co'
anonKey = 'sb_publishable_V4nWfOHrOlBvN8G6Kfh1XA_1AUCF7n3'
```
Ces 2 valeurs sont **embarquées dans le site compilé** : tout visiteur peut les lire
(elles voyagent dans le code JavaScript). C'est **le principe normal de Supabase** : la sécurité
ne repose pas sur ces 2 lignes mais sur les **règles de la base (RLS)** décrites en §5.

---

## 3. Le chemin du code jusqu'au site (déploiement, travaille de bout en bout)

### 3.1 Le principe
```
Tu modifies le code (sur la machine de dev)
        │
        ▼
flutter build web            → produit le site compilé dans le dossier build/web/
        │
        ▼
Branche "gh-pages" (GitHub)  → reçoit UNIQUEMENT le site compilé (pas le code source)
        │
        ▼
Netlify détecte la mise à jour (dépôt connecté, branche de production = gh-pages)
        │
        ▼
https://kinflow.netlify.app   → mis à jour ~1 minute plus tard, sans action des utilisateurs
```

### 3.2 La seule commande à retenir pour publier une mise à jour
Dans le dossier du projet (sur la machine de dev) :

```bash
./deployer_web.sh
```
(alias : `./deployer_web.sh netlify`)

Ce script fait automatiquement :
1. `flutter build web` (compile le site).
2. Met la branche `master` à jour (historique du code source) et la pousse sur GitHub.
3. Reconstruit la branche `gh-pages` **avec seulement le site compilé** (dans un répertoire temporaire,
   le code source n'est jamais perturbé) et la pousse.
4. Netlify, automatiquement connecté, déploie le nouveau site.

Autres variantes du script :
- `./deployer_web.sh zip` → crée `kinflow-web.zip` (12 Mo) prêt à glisser-déposer sur
  https://app.netlify.com/drop (secours si le déploiement automatique ne marche pas).

### 3.3 Configuration exacte de Netlify (à ne pas changer par erreur)
- **Repository lié** : `github.com/dkalonji170-eng/Kinflow`
- **Base directory** : `/` (racine)
- **Build command** : *(vide)* — Netlify ne compile pas, il publie tel quel ✅
- **Publish directory** : *(vide)* → signifie « la racine » (le contenu entier de la branche gh-pages) ✅
- **Functions directory** : *(non utilisé)*
- **Production branch** : `gh-pages` ✅ (PAS `master` — sinon Netlify essaierait de compiler et échouerait)
- **Branch deploys** : *None* (seulement la branche de production)
- **Deploy Previews** : *None*
- **Build image** : Ubuntu Noble 24.04 (par défaut) — inutilisée car aucun build.
- Plan **Free** : 100 Go de bande passante / mois, cryptage HTTPS automatique (obligatoire).
  Suffisant pour démarrer.

### 3.4 Pourquoi cette configuration ?
- Le **premier essai** (branche `master` + build command `flutter build web --release` sur Netlify) a
  **échoué** : l'utilitaire Flutter n'est pas installé sur les machines Netlify, donc la compilation
  en ligne est impossible (ou très lourde). D'où la solution retenue : compiler chez nous et publier
  le résultat sur `gh-pages`.

---

## 4. Ce qui est embarqué dans le site compilé (dossier `build/web/`)

`flutter build web` produit un dossier autonome (~33 Mo) contenant entre autres :
- `index.html` : point d'entrée du site.
- `main.dart.js` (3,3 Mo) : **toute l'application** en JavaScript (le code compile).
- `flutter_bootstrap.js`, `flutter.js`, `flutter_service_worker.js` : chargement Flutter + service worker.
- `manifest.json` : l'app web est une **PWA** (« Progressive Web App ») → sur mobile, l'utilisateur peut
  l'ajouter à l'écran d'accueil :
  menu navigateur (Chrome/Edge/Safari) → « Ajouter à l'écran d'accueil ».
- `canvaskit/` : moteur de rendu WebGL de Flutter.
- `icons/`, `favicon.png`, `assets/` : icônes et ressources.

⚠️ **Conséquence importante** : puisque `main.dart.js` contient tout le code, le « fonctionnement »
des appels Supabase (URL + clé anon) est lisible par n'importe quel visiteur **sur n'importe quel
hébergeur** (Netlify, GitHub Pages, Vercel...). Ce n'est pas un défaut : c'est le fonctionnement
d'une application web connectée à Supabase. La protection des données vient des **règles de la base**
(§5), jamais de la clé anon.

---

## 5. Supabase — la base de données et la sécurité (CŒUR DU SUJET)

### 5.1 Comment ça marche techniquement
- Supabase = **PostgreSQL** (base relationnelle) + **PostgREST** (API web qui transforme les requêtes
  en URL REST) + **GoTrue** (gestion des identités) exposés derrière 1 URL.
- Depuis l'app, on parle à Supabase via le paquet `supabase_flutter` (v2.8.4) :
  - **Auth** : connexion **anonyme** (`signInAnonymously`). Chaque visiteur/installation reçoit un
    **ID secret** (`auth.uid()`), sans nom ni mot de passe. Ce ID est l'identité de la personne.
  - **Données** : requêtes « `.from('profiles')` / `.from('signalements')` » sur les tables,
    et appels de fonctions via `.rpc('nom_fonction', {…})`.
- Le client garde la session (reconnexion si le navigateur l'a oubliée).

### 5.2 Les tables
**Table `profiles`** (les identités/utilisateurs) — colonnes :
`id` (uuid, = auth.uid()), `nom`, `prenom`, `sexe`, `date`, `telephone`, `email`,
`code` (unique, 8 caractères, sûrs : `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`), `mode_sombre` (booléen).

**Table `signalements`** (états de route signalés) — colonnes :
`id`, `user_id` (uuid), `etat` (texte), `latitude`, `longitude`, `cap` (direction du regard, optionnel),
`cree_a` (date), + colonnes **stockées calculées** pour les stats :
`jour_semaine_local` (1-7, fuseau **Africa/Kinshasa**), `heure_locale` (0-23),
avec **index** `signalements_creneau_idx` et `signalements_cree_a_idx` pour aller vite.

**Table `signalements_stats_creneau`** (synthèse statistique) — colonnes :
`periode` (ex. `2026-W32` semaine ISO ou `2026-08` mois), `jour_semaine`, `heure`, `etat`, `nb`, `maj_a`.
Clé primaire : `(periode, jour_semaine, heure, etat)`.

**Table `signalements_archive_etat`** — suivi de la dernière borne d'archivage (1 ligne, `id=1`).

### 5.3 Les fonctions (RPC) — appelées par l'app avec `.rpc(...)`
| Fonction | Rôle | Comment |
|----------|------|---------|
| `adopter_profil(code_saisi, nom_saisi)` | Connecte un compte existant via nom + code | `SECURITY DEFINER` (outrepasse RLS avec prudence, retourne le profil JSONB ou null) |
| `code_unique_disponible(p_code)` | Vérifie la disponibilité d'un code | `SECURITY DEFINER` (outrepasse RLS : évite de pouvoir lister les codes des autres) |
| `signaler_etat(p_etat, lat, lng, cap)` | Dépose un signalement ; le user_id vient de la session, jamais du client | retourne boolean |
| `signalements_recents()` | Les signalements des **60 dernières minutes**, anonymisés (pas de user_id) | retourne table |
| `signalements_archiver(granularite)` | Agrége les signalements par **semaine** ou **mois** dans stats_creneau (à lancer chaque lundi/1er du mois) | retourne texte |
| `signalements_stats_consulter(periode)` | Distribution (jour × heure × état) d'une période ou « toutes » | retourne table |
| `signalements_bruts_creneau(jour, heure, depuis)` | Signalements bruts d'un créneau pour reconstruire les zones | retourne table |

### 5.4 La sécurité — RLS (Row Level Security) — LE point à comprendre
- **RLS est activée sur `profiles` et `signalements`** : chaque ligne ne se lit/s'écrit que si
  `auth.uid() = id (ou user_id)`. Un visiteur ne peut donc **jamais** lire ou modifier les données d'autrui,
  même s'il connaît les URL.
- Les fonctions **`SECURITY DEFINER`** outrepasse RLS **exprès**, seulement pour :
  la connexion par code + nom, la vérification de disponibilité d'un code, le dépôt anonymisé des
  signalements, la lecture des signalements récents (anonymisés — la liste ne contient aucune identité).
- Connexions qui perdent leurs données : quand tu « adoptes » un profil (connexion par code), 
  l'identité anonyme du profil est **transférée** vers ta session (suppression de l'ancienne ligne, mise à jour de l'id).
- Le fuseau horaire des stats est **Africa/Kinshasa** (UTC+1, pas d'heure d'été) : si le fuseau
  changeait, les colonnes stockées devraient être régénérées.

### 5.5 Où sont appliquées les règles (les fichiers de migration)
Dossier `supabase/migrations/` — fichiers envoyés à Supabase par l'éditeur SQL du tableau de bord :
1. `20260807000000_adopter_profil_fixe.sql` → fonction `adopter_profil` + index unique sur `code`.
2. `20260807010000_mode_sombre.sql` → colonne `mode_sombre` sur profiles.
3. `20260807020000_rls_profiles.sql` → activation RLS + politiques sur profiles + `code_unique_disponible`.
4. `20260807030000_signalements.sql` → table signalements, RLS, `signaler_etat`, `signalements_recents`.
5. `20260808000000_stats_historiques.sql` → colonnes dérivées, stats_creneau, archivage, consultations.

Pour appliquer une modification dans le code SQL du projet :
Tableau de bord Supabase → `SQL Editor` → coller le contenu → « Run ».
(Ou `supabase db push` si la CLI Supabase est installée sur une machine avec le fichier de connexion.)

---

## 6. Les fonds de carte (tuiles) — dépend de 3 fournisseurs

Les cartes sont assemblées tuile par tuile (carrés de 256×256 px), téléchargées au fil du déplacement.

| Style | Serveur | Usage |
|-------|---------|-------|
| Carte sombre/route | https://tile.openstreetmap.org/{z}/{x}/{y}.png | carte principale |
| Imagerie satellite | https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x} | fond satellite (Esri) |
| Sombre épuré | https://basemaps.cartocdn.com/rastertiles/dark_only_labels/{z}/{x}/{y}.png | rendu sombre |

- **Limitations** : serveurs gratuits, une **politique d'utilisation raisonnable** est demandée
  (pas de téléchargement massif ; la carte hors ligne est donc **pré-téléchargée en petites zones**).
- **Mise en cache locale** : le paquet **`flutter_map_tile_caching` (FMTC, v10.0.0)** stocke les tuiles
  déjà vues **sur l'appareil** (sur navigateur : stockage du navigateur ; sur mobile : disque de l'app).
  La zone **Kinshasa** est pré-découpée et pré-téléchargée : fichier `assets/kinshasa.fmtc`.
- **Consommation data** : chaque tuile ≈ quelques dizaines de **Ko**. Sur web, les tuiles du
  service FMTC coûtent de la mémoire du navigateur et de la bande passante téléchargée.
  (Un diagnostic « consommation de données en Mo par service » existe côté développeur, invisible pour l'utilisateur.)

---

## 7. Itinéraire, recherche d'adresses, réseau routier

### 7.1 Itinéraire routier — **OSRM** (calcul de trajet)
Serveurs utilisés (repli automatique si un serveur est en panne) :
1. `https://router.project-osrm.org` (serveur public principal)
2. `https://routing.openstreetmap.de/routed-car` (miroir)
3. `https://routing.fossgis.de/routed-car` (miroir)
Format : API standard OSRM ; requêtes de type « profile car », JSON.

### 7.2 Recherche d'adresses / lieux — **Photon** et **Nominatim**
- Photon : `https://photon.komoot.io/api/?q=…` (recherche rapide d'adresses).
- Nominatim : `https://nominatim.openstreetmap.org/search` (recherche) et
  `https://nominatim.openstreetmap.org/reverse` (adresse depuis des coordonnées = géocodage inverse).
  ⚠️ **Règle à respecter** : max **1 requête/seconde** et un User-Agent identifiable.

### 7.3 Données routières — **Overpass API** (extraction du réseau)
Serveurs utilisés :
1. `https://overpass-api.de/api/interpreter`
2. `https://overpass.kumi.systems/api/interpreter`
3. `https://overpass.private.coffee/api/interpreter`
Usage : requêtes (query Overpass QL) pour récupérer les routes, nœuds, sens de circulation
(autour de la position de l'utilisateur, ou à proximité d'un chemin).

### 7.4 Détection de la direction
- **Boussole** : le capteur magnétique du téléphone (`flutter_compass`) oriente la carte selon le regard.
- **Localisation** : GPS du téléphone (`geolocator` v13.0.4), avec demandes de permission automatiques.

---

## 8. L'environnement de développement (ce qu'il faut pour reconstruire)

- **Flutter 3.38.5**, canal stable (contrôlé par `flutter doctor`).
- **SDK Dart** : `^3.10.4` (pubspec.yaml).
- Le projet a été développé sur **Linux** ; la machine de dev possède : Flutter, Git,
  et les outils de base (le dossier `windows/`, `android/`, `web/` contient les cibles de compilation).
- **Dépendances principales** (pubspec.yaml) :
  `flutter_map` 7.0.2, `flutter_map_tile_caching` 10.0.0, `latlong2` 0.9.1, `http` 1.2.2,
  `geolocator` 13.0.4, `flutter_compass` 0.8.0, `connectivity_plus` 6.1.3, `supabase_flutter` 2.8.4,
  `shared_preferences` 2.5.3, `provider` 6.1.2, `path_provider` 2.1.4, `url_launcher` 6.3.1.
- **Données locales côté utilisateur** (sur son appareil) : `shared_preferences` (réglages, thème…),
  cache des tuiles FMTC, session Supabase, fichier ZIP enregistré pour la carte hors ligne.

---

## 9. Sécurité et bonnes pratiques — À GARDER EN TÊTE ⚠️

1. **Le dépôt GitHub est PRIVÉ et doit le rester.** Il contient le code source complet avec les
   migrations SQL, la configuration Supabase et ce rapport (qui référence des secrets).
   GitHub Pages **gratuit exige un dépôt public** → c'est pour ça qu'on a choisi Netlify, qui accepte
   les dépôts privés.
2. **La clé anon Supabase est publique par conception** (elle est dans le site). Ne te méfie pas d'elle.
   La sécurité vient des **règles RLS** : ne jamais les désactiver, ne jamais diffuser la clé
   `service_role`.
3. **Le jeton GitHub** (`~/.git-credentials`) permet d'écrire sur ton dépôt. Ne le partage jamais ;
   révoque-le vite si tu l'as envoyé à quelqu'un (GitHub → Settings → Developer settings → Tokens).
4. **Fusion avec le public** : le site Netlify est public (c'est voulu), mais il ne sert que la branche
   `gh-pages` (le site compilé) — jamais le code source ni les migrations.
5. **Sandbox de développement** : sur la machine de dev, `curl` est cassé et `api.github.com` est
   bloqué en sortie → les actions doivent passer par `git push` et par l'interface web de GitHub/Netlify.
6. **Fichier parasite**: un vieux binaire `-` (12 Mo) existe à la racine du projet ;
   il est exclu des commits par `.gitignore` (ligne `/-`). Ne le réintroduis pas.

---

## 10. Dépannage mental — « Si X ne marche plus »

| Symptôme | Cause probable | Réparation |
|----------|----------------|------------|
| Le site ne se met pas à jour après une modif | Le script n'a pas été relancé, ou le push a échoué (mauvaise clé dans `~/.git-credentials`) | Relancer `./deployer_web.sh` ; vérifier `~/.git-credentials` ; les erreurs réseau GitHub sont parfois « remote hung up » → augmenter le tampon (`git config http.postBuffer 52428800`) |
| « Something went wrong » en activant GitHub Pages | Dépôt privé (Pages gratuit = public) — NORMAL | Pas grave : on utilise Netlify, pas GitHub Pages |
| Netlify montre « Build failed » | La branche de production est passée à `master`, ou un build command non vide | Remettre branche = `gh-pages`, Build command vide, Publish directory vide (voir §3.3) |
| Les données Supabase ne se sauvegardent pas | RLS qui bloque, ou identité anonyme non obtenue, ou migration non appliquée | Vérifier SQL Editor (le dossier `supabase/migrations/`) ; vérifier la connexion réseau du visiteur |
| Les tuiles ne se chargent pas / carte vide | Serveur de tuiles surchargé ou bloqué, ou cache FMTC corrompu | Réessayer plus tard ; vider le cache de l'application |
| Les itinéraires ne sortent pas | Serveur OSRM public saturé | L'app bascule automatiquement sur les miroirs (laisser quelques secondes) |

---

## 11. Liens utiles — tout au même endroit

- Site public : **https://kinflow.netlify.app**
- Admin Netlify : https://app.netlify.com
- Dépôt GitHub : https://github.com/dkalonji170-eng/kinflow
- Admin Supabase : https://supabase.com/dashboard/project/qosznioaonumbdjhiwuj
- Éditeur SQL Supabase (pour relancer les migrations) : dashboard → « SQL Editor »
- Jeton GitHub : https://github.com/settings/tokens
- Dropper de secours (si le déploiement auto casse) : `./deployer_web.sh zip` puis https://app.netlify.com/drop

---

*Fin du rapport. En cas de doute, commence par la section 2 (comptes), puis la section 3 (déploiement), puis la section 5 (Supabase).*