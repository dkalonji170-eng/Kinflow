# Modifications à appliquer — KinFlow

Récapitulatif de tout ce qui a été modifié : suppression des grades, verrouillage
en portrait, et suppression de l'indicateur « en ligne ».

---

## 1. Suppression des grades / rangs / séries

### Fichiers à supprimer
- `lib/services/rang_service.dart`
- `lib/services/serie_activite_service.dart`
- `lib/widgets/carte_grade.dart`
- `lib/widgets/grade_rang.dart`
- `lib/widgets/rang_signalements_badge.dart`
- `test/grade_rang_test.dart`

### Autres restes supprimés
- `lib/widgets/social_ui.dart` : classe `PastilleStat` (pastille de statistique
  utilisée par les anciens grades) retirée.
- `supabase/migrations/20261028000000_rangs_par_signalements.sql` : supprimée.
- `supabase/migrations/20261031000000_rangs_par_activite.sql` : supprimée.
- Les commentaires mentionnant `activite_utilisateur` dans
  `supabase/migrations/20261102040000_purge_compte.sql` et
  `supabase/AUDIT_SQL_A_EXECUTER.sql` sont nettoyés.

> `20261103000000_suppression_grades.sql` est conservée : elle supprime les
> objets déjà créés sur les bases existantes.

### Fichiers déjà nettoyés (plus aucun import ni appel)
- `lib/main.dart`
- `lib/models/information_ville.dart`
- `lib/screens/ami_ia_screen.dart`
- `lib/screens/chat_ami_screen.dart`
- `lib/screens/code_screen.dart`
- `lib/screens/edit_profile_screen.dart`
- `lib/screens/fil_ville_screen.dart`
- `lib/screens/home_screen.dart`
- `lib/screens/login_screen.dart`
- `lib/screens/notifications_screen.dart`
- `lib/screens/profile_screen.dart`
- `lib/screens/report_problem_screen.dart`
- `lib/screens/search_screen.dart`
- `lib/screens/settings_screen.dart`
- `lib/screens/traffic_screen.dart`
- `lib/services/ia_service.dart`
- `lib/services/position_partage_service.dart`
- `lib/services/supabase_service.dart`
- `lib/widgets/avatar_animal.dart`
- `lib/widgets/bulle_vocale.dart`
- `lib/widgets/profil_ami_dialog.dart`
- `lib/widgets/traffic_map.dart`
- `lib/widgets/traffic_state_sheet.dart`
- `test/avatar_animal_test.dart`
- `test/bulle_vocale_test.dart`
- `test/information_ville_test.dart`

### SQL à exécuter sur Supabase
Fichier : `supabase/migrations/20261103000000_suppression_grades.sql`

```sql
drop function if exists public.mon_rang_signalements();
drop function if exists public.rang_signalements_utilisateur(uuid);
drop function if exists public.compter_signalements_utilisateur(uuid);
drop function if exists public.rang_depuis_jours(integer);

drop table if exists public.activite_utilisateur;

select pg_notify('pgrst', 'reload schema');
```

---

## 2. Verrouillage en portrait

### `lib/main.dart`
Déjà présent dans `_runApp()` :

```dart
if (!kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS)) {
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
}
```

Import nécessaire :
```dart
import 'package:flutter/foundation.dart'
    show kIsWeb, PlatformDispatcher, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, DeviceOrientation, SystemChrome;
```

### `android/app/src/main/AndroidManifest.xml`
Dans la balise `<activity android:name=".MainActivity" ...>` :

```xml
android:screenOrientation="portrait"
```

### `ios/Runner/Info.plist`
Remplacer les deux tableaux d'orientations par :

```xml
<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
</array>
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
</array>
```

---

## 3. Suppression de l'indicateur « en ligne »

La présence était déduite de `maj_a` (mise à jour de position < 5 min).
Tous les affichages correspondants sont retirés.

### `lib/widgets/social_ui.dart`
Supprimer entièrement la classe `PastillePresence` (et son commentaire
« Petite pastille ronde de présence »).

### `lib/screens/fil_ville_screen.dart`
Supprimer la méthode `_positionRecente` :

```dart
/// Vrai si la position de l'ami(e) a été mise à jour très récemment
/// (moins de 5 minutes) : sert de pastille « en ligne ».
bool _positionRecente(Map<String, dynamic> ami) {
  final brut = ami['maj_a'];
  final majA = brut == null ? null : DateTime.tryParse(brut.toString());
  if (majA == null) return false;
  return DateTime.now().difference(majA.toLocal()).inMinutes < 5;
}
```

Dans `_carteAmi`, supprimer `final recent = _positionRecente(ami);`
et remplacer le `Stack` de l'avatar par le simple `GestureDetector` :

```dart
GestureDetector(
  onTap: () => ouvrirProfilAmi(
    context,
    userId: ami['ami_id'] as String? ?? '',
    nom: _nomComplet(ami),
    avatarId: ami['avatar'] as String?,
  ),
  child: AvatarAnimalWidget(
    taille: 52,
    avatarId: ami['avatar'] as String?,
  ),
),
```

### `lib/screens/chat_ami_screen.dart`
Supprimer le getter `_amiEnLigne` et simplifier le sous-titre :

```dart
/// Sous-titre de l'en-tête : état de la discussion.
String _sousTitreEntete() {
  return 'Discussion privée';
}
```

Dans l'en-tête, remplacer le `Stack` de l'avatar par le `GestureDetector`
seul (suppression du `Positioned` avec `PastillePresence`).

Couleur du sous-titre : toujours `theme.colorScheme.onSurfaceVariant`
(suppression du vert « en ligne »).

Retirer l'argument `majA` lors de la construction de `AmiPosition` :

```dart
final position = AmiPosition(
  id: widget.amiId,
  nom: widget.nom,
  avatar: widget.avatar,
  position: LatLng(latitude, longitude),
  cap: _double(resultat['cap']),
);
```

### `lib/models/ami_position.dart`
Supprimer le champ `majA` (constructeur, propriété et lecture de `json['maj_a']`).

### `lib/widgets/traffic_map.dart`
Supprimer le badge « âge de la dernière position » (bloc
`if (ami.majA != null) ...` avec `tempsRelatif(ami.majA!)`).
Supprimer aussi l'import devenu inutile :

```dart
import '../utils/temps_relatif.dart';
```

---

## 4. Menu ami par appui long + blocages dans la fenêtre Amis

### Nouveaux fichiers
- `lib/widgets/menu_ami.dart` : menu partagé (mêmes actions que les trois
  points de la discussion).
- `lib/widgets/autorisations_localisation_sheet.dart` : feuille des
  autorisations extraite du chat, réutilisée par le menu.

### `lib/screens/fil_ville_screen.dart`
- Import de `menu_ami.dart` et `blocked_users_screen.dart`.
- Sur la carte d'un ami, ajouter l'appui long :

```dart
onTap: () => _ouvrirDiscussionAmi(ami),
onLongPress: () => _ouvrirMenuAmi(ami),
```

- Nouvelle méthode `_ouvrirMenuAmi` (voir le fichier).
- Dans le menu ⋮ de l'en-tête, ajouter l'entrée « Utilisateurs bloqués » :

```dart
const PopupMenuDivider(),
const PopupMenuItem(
  value: 'bloques',
  child: ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(Icons.block),
    title: Text('Utilisateurs bloqués'),
  ),
),
```

et le traitement :

```dart
} else if (valeur == 'bloques') {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
  );
}
```

### `lib/screens/chat_ami_screen.dart`
- `_ouvrirAutorisations` délègue maintenant à
  `ouvrirAutorisationsLocalisation(...)`.
- Import du nouveau widget.

### `lib/screens/settings_screen.dart`
- Supprimer l'entrée « Utilisateurs bloqués » et son import
  `blocked_users_screen.dart`.
- Supprimer l'entrée « Partage de position » (déplacée dans le menu ⋮ des
  amis) ainsi que l'import `partage_position_screen.dart`.
- Déplacer « Mon compte » juste au-dessus de « Déconnexion ».

### `lib/screens/fil_ville_screen.dart` (menu ⋮)
Ajouter l'entrée « Partage de position » qui ouvre `PartagePositionScreen` :

```dart
} else if (valeur == 'position') {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const PartagePositionScreen()),
  );
}
```

et l'élément de menu correspondant (icône `Icons.share_location`).

### Menu ⋮ de la discussion privée (`lib/screens/chat_ami_screen.dart`)
Ajout de deux entrées en bas du menu : « Signaler » et « Bloquer ».

- « Signaler » ouvre le choix du motif puis la description, comme la fiche
  ami.
- « Bloquer » demande confirmation, bloque l'utilisateur puis ferme la
  discussion et rafraîchit la liste des amis.

Les deux actions sont mutualisées dans `lib/widgets/actions_ami.dart`
(`signalerUtilisateur`, `bloquerUtilisateur`, `debloquerUtilisateur`) et
réutilisées par `profil_ami_dialog.dart` et `menu_ami.dart` (menu de l'appui
long sur un ami), pour garder les trois menus identiques.

---

## 5. Suppression de « Ma maison » (recherche de lieu et carte)

Le domicile enregistré n'est plus proposé ni affiché : seul « Mon travail »
reste disponible comme lieu personnel.

### `lib/screens/search_screen.dart`
- Suppression du paramètre `onDemanderPoserMaison`, du champ `_maison`, de
  `_chargerMaison`, `_persisterMaison` et `_choisirMaison`.
- La tuile « Ma maison » et son action « Placer sur la carte » sont retirées :
  seule la tuile « Mon travail » subsiste.
- Clé `lieu_maison` : plus jamais lue ni écrite.

### `lib/screens/traffic_screen.dart`
- Suppression de `_maisonPoint`, du chargement de `lieu_maison` et de toutes
  les branches « maison ».
- `_demanderPoserLieu(TypeLieuPose)` devient `_demanderPoserTravail()`.
- `_onPoserLieu` ne persiste plus que `lieu_travail`.
- `_estLieuPersonnel` / `_estPointPersonnel` ne considèrent plus que
  « Mon travail ».

### `lib/widgets/traffic_map.dart`
- Suppression du champ/paramètre `pointMaison`, du marqueur `badge_maison` et
  de la branche maison de `_typeLieuPersonnel`.
- `enum TypeLieuPose` ne contient plus que `travail`.

---

## 6. Badges des lieux visibles sur la carte

Les pastilles des lieux (POIs) et du lieu de travail ne s'affichaient pas.

### `lib/services/poi_service.dart`
- Un miroir Overpass qui répond autre chose que `200` (429, 504 mais aussi
  500/502/503) ne fait plus échouer tout le chargement : on passe au miroir
  suivant. Avant, un simple `502` du premier serveur laissait la carte sans
  aucun badge.
- Un seul échec est compté par passe de chargement (et non un par miroir) :
  le disjoncteur ne s'ouvre plus après un unique essai raté.
- Délai court (0,7 s → 1,4 s → 2,8 s) entre deux miroirs, `Retry-After`
  plafonné à 10 s.

### `lib/widgets/traffic_map.dart`
- Zoom d'ouverture de la carte passé de 13 à **14** (= `zoomMinPois`) : les
  badges s'affichent dès l'ouverture, sans devoir zoomer à la main.
- Badge du lieu de travail : taille minimale de **22 px** au lieu de
  disparaître sous ~15 de zoom (`_BadgeAncrageZoom._taillePourZoom`).
- Le badge du travail n'est construit qu'à partir de `zoomMinPois` (14), via
  `_lieuxPersonnelsVisibles`, comme les POIs.

---

## 7. Téléversement des photos

Cause trouvée sur le projet Supabase : le bucket privé **`messages_images`
n'existe pas** (l'API Storage répond `Bucket not found` / `NoSuchBucket`).
La fonction `public.puis_voir_image` manque aussi. La migration
`20261030000000_messages_images.sql` n'a donc pas été appliquée (ou seulement
en partie).

### À exécuter sur Supabase

Ouvrir `supabase/CORRIGER_BUCKET_PHOTOS.sql` dans **SQL Editor** et lancer le
script entier. Il crée le bucket, la fonction de visibilité et les trois
politiques Storage (insert / select / delete), puis recharge le cache.

> ⚠️ Ne pas relancer `20261030000000_messages_images.sql` en entier : il
> redéfinit `envoyer_message_ami` sans `p_reply_to_message_id` et casserait
> les réponses aux messages.

### `lib/services/supabase_service.dart`
- `_detailErreur` reconnaît désormais `StorageException` : bucket manquant,
  droits refusés, fichier trop lourd, au lieu d'un texte technique.

### `lib/screens/chat_ami_screen.dart`
- La bulle en échec affiche le détail lisible dans le SnackBar
  (« Photo non envoyée : Stockage des médias non configuré… »).

---

## Vérification

```bash
flutter analyze
# No issues found!
```
