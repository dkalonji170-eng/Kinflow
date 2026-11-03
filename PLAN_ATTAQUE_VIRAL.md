# KinFlow — Plan d'attaque « croissance virale »

Objectif : la boucle **1 info → 1 image Statut WhatsApp → 10 nouveaux users → 10 nouvelles infos**.

---

## 0. Trois constats qui changent le plan

### 0.1 Aujourd'hui, personne ne peut publier d'info
`public.informations` ne contient que `contenu, latitude, longitude, cree_a`.
Aucun `auteur`. Le modèle `InformationVille` le dit noir sur blanc : « Les
utilisateurs n'écrivent rien : ils réagissent en VERT ou ROUGE. »

Donc **+10 points par info publiée est impossible en l'état**. La publication
d'infos par les utilisateurs est le socle de tout le reste : sans elle, pas de
score, pas de « Maire de Ngaliema », pas d'image Statut avec un auteur.

### 0.2 Les états de route ne sont pas partagés
`TrafficService` écrit l'état dans `SharedPreferences` (local, par téléphone).
La table `public.signalements` existe bien côté serveur, mais sa politique RLS
est `select_own` : **chaque utilisateur ne peut lire que ses propres
signalements**. Personne ne peut donc savoir que « Victoire est bloquée »
ailleurs que sur son propre écran.

Conséquence : la notif « ton trajet est bloqué » et l'image « VICTOIRE BLOQUÉE
8h12 » n'ont **aucune donnée fiable** à afficher tant qu'on n'ouvre pas une
lecture agrégée côté serveur.

### 0.3 Il n'y a pas de commune
Aucune colonne `commune` dans `profiles`. Or tout le volet social (classement,
Maire, votes eau/courant) est indexé par commune.

**Ces trois points sont le Sprint 0.** Le reste en découle.

---

## 1. Vue d'ensemble

| # | Chantier | Effort | Valeur virale | Dépend de |
|---|---|---|---|---|
| 0 | Socle : commune + publication d'info + lecture agrégée des états | 2 j | — | — |
| 1 | Générateur d'image Statut WhatsApp | 3 j | ★★★★★ | 0 |
| 2 | Kinflow Score + classement par commune + Maire | 3 j | ★★★★★ | 0 |
| 3 | Votes EAU / COURANT / INTERNET | 2 j | ★★★☆☆ | 0 |
| 4 | Calculateur de coût de trajet | 2 j | ★★★★☆ | 0 |
| 5 | Notif « ton trajet habituel est bloqué » | 3 j | ★★★★☆ | 0 |

Ordre conseillé : **0 → 1 → 2 → 3 → 4 → 5**. L'image Statut d'abord parce que
c'est le seul canal d'acquisition gratuit ; le score ensuite parce qu'il donne
la raison de revenir.

Total : ~15 jours de dev, testable par étapes.

---

## 2. Sprint 0 — Le socle (2 jours)

### SQL (`supabase/migrations/20261104000000_socle_viral.sql`)

```sql
-- 1) Les 24 communes de Kinshasa -------------------------------------------
create table if not exists public.communes (
  nom text primary key,
  latitude double precision,
  longitude double precision
);

insert into public.communes (nom) values
  ('Bandalungwa'),('Barumbu'),('Bumbu'),('Gombe'),('Kalamu'),('Kasa-Vubu'),
  ('Kimbanseke'),('Kinshasa'),('Kintambo'),('Kisenso'),('Lemba'),('Limete'),
  ('Lingwala'),('Makala'),('Maluku'),('Masina'),('Matete'),('Mont-Ngafula'),
  ('Ndjili'),('Ngaba'),('Ngaliema'),('Ngiri-Ngiri'),('Nsele'),('Selembao')
on conflict (nom) do nothing;

-- 2) Commune du profil ------------------------------------------------------
alter table public.profiles add column if not exists commune text;
alter table public.profiles add column if not exists commune_maj_a timestamptz;

-- 3) Infos publiées par les gens -------------------------------------------
alter table public.informations
  add column if not exists auteur uuid
    references public.profiles(id) on delete set null on update cascade,
  add column if not exists commune text,
  add column if not exists type_info text not null default 'info',
  add column if not exists expire_a timestamptz,
  add column if not exists masquee boolean not null default false;

alter table public.informations
  drop constraint if exists informations_type_check;
alter table public.informations
  add constraint informations_type_check
  check (type_info in ('trafic','eau','courant','internet','securite','info'));

create index if not exists informations_commune_idx
  on public.informations (commune, cree_a desc);

-- 4) Publication (RPC, rate-limitée) ---------------------------------------
create or replace function public.publier_info(
  p_contenu text,
  p_type text default 'info',
  p_commune text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_expire_minutes integer default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_commune text;
  v_id uuid;
  v_derniere timestamptz;
begin
  if v_uid is null then raise exception 'non_connecte'; end if;
  if length(trim(coalesce(p_contenu,''))) < 8 then
    raise exception 'contenu_trop_court';
  end if;

  -- max 5 infos / heure et 20 / jour : la boucle virale ne doit pas
  -- devenir un mur de spam.
  select max(cree_a) into v_derniere
    from public.informations where auteur = v_uid;
  if v_derniere is not null and v_derniere > now() - interval '2 minutes' then
    raise exception 'trop_rapide';
  end if;
  if (select count(*) from public.informations
       where auteur = v_uid and cree_a > now() - interval '1 hour') >= 5 then
    raise exception 'trop_d_infos';
  end if;

  select coalesce(p_commune, commune) into v_commune
    from public.profiles where id = v_uid;

  insert into public.informations
    (contenu, auteur, commune, type_info, latitude, longitude, expire_a)
  values
    (trim(p_contenu), v_uid, v_commune, p_type, p_latitude, p_longitude,
     case when p_expire_minutes is null then null
          else now() + make_interval(mins => p_expire_minutes) end)
  returning id into v_id;

  return v_id;
end $$;

grant execute on function public.publier_info(text,text,text,double precision,double precision,integer)
  to authenticated;
```

### Flutter
- `SupabaseService.publierInfo(...)` → renvoie l'`id`.
- `EcranPublierInfo` : champ texte (500 car. max, compteur), sélecteur de type
  (6 puces), commune pré-remplie (modifiable), bouton « Publier ».
- Après publication : **ouvrir directement l'aperçu de l'image Statut** (sprint 1).
- `profil.commune` : sélecteur dans `edit_profile_screen.dart`, modifiable
  1 fois par semaine (`commune_maj_a`).

### Piège à éviter
Ne pas déduire la commune du GPS. À Kinshasa le GPS dérive, et un habitant de
Ngaliema peut poster sur Gombe. On demande, on ne devine pas.

---

## 3. Sprint 1 — Générateur d'image Statut (3 jours)

### Principe
**Ne pas faire une capture d'écran.** Un `RepaintBoundary` dépend d'un widget
affiché, casse en test, et donne une image de la taille de l'écran (donc moche
sur WhatsApp). On dessine l'image **directement au Canvas** : 1080×1080 exact,
déterministe, testable, sans dépendance.

`lib/services/image_statut_service.dart` :

```dart
import 'dart:ui' as ui;

class ImageStatutService {
  static const double taille = 1080;

  Future<Uint8List> generer({
    required String titre,          // « VICTOIRE BLOQUÉE »
    required String detail,         // « Évitez, passez par Ngaba »
    required String type,           // trafic | eau | courant | internet
    required String commune,
    required DateTime heure,
    required String auteur,
    required int nbConfirmations,   // 0 = on n'affiche rien (jamais de faux)
    String? lien,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 1080, 1080));
    // 1. fond dégradé sombre
    // 2. bande de couleur selon le type (jaune trafic, bleu eau…)
    // 3. badge type + emoji
    // 4. titre (TextPainter, maxLines 3, ellipsis)
    // 5. détail
    // 6. commune + heure
    // 7. « Info par @auteur · Vérifié par 12 Kinois » (si >= 3)
    // 8. pied : logo + kinflow.cd + QR code (qr_flutter est déjà installé)
    final image = await recorder.endRecording().toImage(1080, 1080);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}
```

Points techniques :
- `TextPainter` avec `maxLines` + `TextOverflow.ellipsis` : **aucun texte ne
  doit déborder**, c'est le bug n°1 de ce genre de générateur.
- Tester les cas extrêmes : titre de 2 caractères, titre de 120 caractères,
  auteur avec emoji, commune la plus longue (`Mont-Ngafula`).
- L'image est un `Uint8List` : zéro fichier temporaire pour les tests.

### Partage
`pubspec.yaml` : ajouter `share_plus` (et garder `path_provider`, déjà là).

```dart
final octets = await ImageStatutService().generer(...);
final dossier = await getTemporaryDirectory();
final fichier = File('${dossier.path}/kinflow_statut.png');
await fichier.writeAsBytes(octets);
await SharePlus.instance.share(ShareParams(
  files: [XFile(fichier.path)],
  text: 'KinFlow — la circulation de Kin en direct',
));
```

⚠️ L'API de `share_plus` a changé selon les versions majeures
(`Share.shareXFiles` → `SharePlus.instance.share`). J'adapte à la version
réellement résolue au moment du `pub get`.

⚠️ **On ne peut pas poster directement en Statut WhatsApp** : Android n'expose
aucune API publique pour ça (WhatsApp bloque volontairement). Le flux réel est :
bouton « Partager en Statut » → feuille de partage Android → l'utilisateur
choisit WhatsApp → « Mon statut ». C'est 3 gestes, pas 1. Ne pas promettre
mieux : les apps qui prétendent le faire utilisent des contournements qui
cassent à chaque mise à jour de WhatsApp.

### UX (le point critique)
Sur chaque info du fil, un bouton **« Partager en image »** (pas « Partager »).
Un appui → bottom sheet d'aperçu avec l'image générée + 2 boutons :
- « Partager sur WhatsApp » (feuille système)
- « Enregistrer l'image »

L'aperçu avant partage est obligatoire : c'est ce qui fait que les gens
partagent (ils voient que ça fait pro), et ça évite de diffuser une image
cassée.

### Contenu de l'image (validé pour un écran de téléphone)
```
┌──────────────────────────────┐
│  🚧 TRAFIC · NGALIEMA        │  bande jaune
│                              │
│  VICTOIRE                    │  96 px, gras
│  BLOQUÉE                     │
│                              │
│  Depuis 8h12 · évitez,       │  40 px
│  passez par Ngaba            │
│                              │
│  ─────────────────────       │
│  Info par @Grace             │  32 px
│  ✅ Vérifié par 12 Kinois    │  seulement si >= 3
│                              │
│  [QR]  kinflow.cd            │  140 px
└──────────────────────────────┘
```

**Règle absolue : jamais de faux « Vérifié x12 ».** Le chiffre vient de
`count(reactions where sens='VERT')`. Une image qui ment une fois tue la
crédibilité de l'app pour toujours — et à Kinshasa, ça se sait en 48 h.

### Attribution (à ne pas oublier)
Sans ça, tu ne sauras jamais si l'image ramène des users. Le lien de pied
d'image doit être `https://kinflow.cd/i/<code>` (ou le lien Play Store avec
`?ref=<code_ami>`). À l'inscription, on enregistre `parrain` dans une table
`parrainages(user_id, parrain_id, source, cree_a)`. C'est 20 lignes de SQL et
ça transforme « je crois que ça marche » en « 38 % des inscrits viennent d'un
statut ».

---

## 4. Sprint 2 — Kinflow Score + Maire de commune (3 jours)

### Ne pas stocker un compteur, stocker un registre
Un `points integer` sur `profiles` est impossible à auditer et se fait tricher
en 10 minutes. On stocke chaque gain :

```sql
create table if not exists public.actions_score (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  type text not null,          -- info_publiee | info_verifiee | confirmation | penalite
  points integer not null,
  ref_id uuid,                 -- information_id
  commune text,
  cree_a timestamptz not null default now()
);

-- Un même événement ne peut pas être crédité deux fois.
create unique index if not exists actions_score_unicite
  on public.actions_score (user_id, type, ref_id)
  where ref_id is not null;

create index if not exists actions_score_user_idx
  on public.actions_score (user_id, cree_a desc);
```

### Règles de points

| Action | Points | Limite |
|---|---|---|
| Publier une info | +10 | 5/h, 20/j |
| Ton info atteint 3 VERT | +50 (une fois) | — |
| Tu confirmes (VERT) une info d'un autre | +2 | max 20/j |
| Ton info masquée après 3 signalements | −20 | — |

`VERT` existant = confirmation. **Pas de nouvelle table** : on réutilise
`public.reactions`. Un trigger sur `reactions` attribue les points.

```sql
create or replace function public.trigger_points_reaction()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_auteur uuid;
  v_commune text;
  v_verts integer;
begin
  if new.sens <> 'VERT' then return new; end if;

  select auteur, commune into v_auteur, v_commune
    from public.informations where id = new.information_id;

  -- l'auteur ne se confirme pas lui-même
  if v_auteur is not null and v_auteur <> new.user_id then
    insert into public.actions_score (user_id, type, points, ref_id, commune)
    values (new.user_id, 'confirmation', 2, new.information_id, v_commune)
    on conflict do nothing;
  end if;

  select count(*) into v_verts
    from public.reactions
   where information_id = new.information_id and sens = 'VERT';

  if v_auteur is not null and v_verts = 3 then
    insert into public.actions_score (user_id, type, points, ref_id, commune)
    values (v_auteur, 'info_verifiee', 50, new.information_id, v_commune)
    on conflict do nothing;
  end if;

  return new;
end $$;

drop trigger if exists points_reaction on public.reactions;
create trigger points_reaction after insert on public.reactions
  for each row execute function public.trigger_points_reaction();
```

### Classement

```sql
create or replace function public.classement_commune(
  p_commune text,
  p_limite integer default 20
)
returns table (
  rang bigint, user_id uuid, pseudo text, avatar text,
  points bigint, est_maire boolean
)
language sql security definer set search_path = public stable
as $$
  with scores as (
    select a.user_id, sum(a.points)::bigint as points
      from public.actions_score a
     where a.cree_a >= date_trunc('week', now())
     group by a.user_id
  )
  select row_number() over (order by s.points desc, p.pseudo),
         s.user_id, p.pseudo, p.avatar, s.points,
         row_number() over (order by s.points desc, p.pseudo) = 1
    from scores s
    join public.profiles p on p.id = s.user_id
   where p.commune = p_commune
   order by s.points desc, p.pseudo
   limit p_limite;
$$;
```

### Le « Maire »
Titre du **top 1 de la semaine précédente** (stable : on ne change pas de
maire toutes les 5 minutes). Table `titres_communes(commune, user_id, semaine)`
remplie par un `cron` hebdo (ou calculée à la lecture avec
`date_trunc('week', now()) - interval '7 days'`).

Affichage :
- sur l'avatar dans le fil : petite couronne + « Maire de Ngaliema » ;
- sur le profil : badge doré ;
- sur la home : « Maire de ta commune cette semaine : @Grace ».

### Anti-triche (obligatoire dès le jour 1)
- compte de plus de 24 h pour gagner des points ;
- pas de points si l'auteur et le confirmeur partagent IP/appareil (à faire en v2) ;
- 3 signalements (`signalements_utilisateurs` existe déjà) → info masquée + −20 ;
- plafond journalier global (100 pts/jour) : un faux groupe ne peut pas
  exploser le classement en une nuit.

### Écrans
- Onglet « Classement » dans `FilVilleScreen` (ou entrée depuis la home) :
  sélecteur de commune + liste avec rangs 1-20.
- Bandeau « Ma commune » en haut du fil : rang actuel + points + « plus que 40 pts
  pour dépasser @Grace ».

C'est ce dernier bandeau qui crée le réflexe. Pas le classement global.

---

## 5. Sprint 3 — Votes EAU / COURANT / INTERNET (2 jours)

### SQL
```sql
create table if not exists public.votes_services (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  service text not null check (service in ('EAU','COURANT','INTERNET')),
  commune text not null,
  etat text not null check (etat in ('OK','KO')),
  cree_a timestamptz not null default now()
);

create index if not exists votes_services_agg_idx
  on public.votes_services (commune, service, cree_a desc);

create or replace function public.voter_service(
  p_service text, p_etat text, p_commune text default null
) returns boolean
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_commune text;
begin
  if v_uid is null then raise exception 'non_connecte'; end if;
  select coalesce(p_commune, commune) into v_commune
    from public.profiles where id = v_uid;
  if v_commune is null then raise exception 'commune_inconnue'; end if;

  -- un seul vote par service et par tranche de 6 h
  delete from public.votes_services
   where user_id = v_uid and service = p_service
     and cree_a > now() - interval '6 hours';

  insert into public.votes_services (user_id, service, commune, etat)
  values (v_uid, p_service, v_commune, p_etat);
  return true;
end $$;

create or replace function public.etat_services(p_commune text)
returns table (service text, pct_ok integer, nb_votes integer, maj_a timestamptz)
language sql security definer set search_path = public stable
as $$
  select v.service,
         round(100.0 * count(*) filter (where v.etat = 'OK') / count(*))::int,
         count(*)::int,
         max(v.cree_a)
    from public.votes_services v
   where v.commune = p_commune
     and v.cree_a > now() - interval '6 hours'
   group by v.service;
$$;
```

### UI (home)
Trois cartes compactes sous les boutons Trafic / Social :

```
💧 EAU        Ça coule · 68 % · 41 votes
⚡ COURANT    Coupé · 22 % · 37 votes
📶 INTERNET   Lent · 51 % · 18 votes
```

Appui → feuille : « Chez toi, maintenant ? » → **Ça marche / C'est coupé**.
Un seul appui, fermeture immédiate, retour à la home avec la carte mise à jour.

Détails qui comptent :
- afficher **le nombre de votes** : sans lui, personne ne croit au pourcentage ;
- afficher **« il y a 12 min »** : à Kinshasa, une info de 5 h ne vaut rien ;
- si moins de 5 votes : « Pas encore assez de votes dans ta commune » plutôt
  qu'un 50 % trompeur ;
- ne jamais envoyer la position GPS pour ce vote : la commune suffit.

---

## 6. Sprint 4 — Calculateur de coût de trajet (2 jours)

### Le moteur existe déjà
`lib/services/itineraire_service.dart` calcule distance + durée sur le graphe
OSM embarqué de Kinshasa, avec multiplicateurs de trafic
(fluide ×1, léger ×1,8, gros ×3,2, bloqué). `RouteResult` expose
`distanceMeters` et `durationSeconds`. **On ne rajoute aucune API externe.**

### Modèle de prix (données, pas de dur)
```sql
create table if not exists public.tarifs_trajets (
  mode text primary key,            -- moto | esprit_de_mort | wewa_bus
  libelle text not null,
  prise_en_charge_fc integer not null,
  fc_par_km integer not null,
  vitesse_kmh integer not null,
  transbordements integer not null default 0,
  maj_a timestamptz not null default now()
);

insert into public.tarifs_trajets values
  ('moto','Moto',1500,400,22,0,now()),
  ('esprit_de_mort','Esprit de mort',500,120,12,1,now()),
  ('wewa_bus','Wewa + bus',300,100,10,2,now())
on conflict (mode) do nothing;

create table if not exists public.retours_tarifs (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  mode text not null,
  prix_paye_fc integer not null,
  distance_m integer,
  cree_a timestamptz not null default now()
);
```

Les chiffres ci-dessus sont **des hypothèses à calibrer** avec 20 Kinois avant
mise en prod. Le prix d'une moto à Kin varie par quartier et par heure de
pointe ; un tarif faux une fois et l'app perd toute crédibilité. D'où la table
(modifiable sans redéployer l'app) + le bouton « C'était juste ? ».

### Calcul
```
prix  = prise_en_charge + fc_par_km × (distance_km × 1,3)   // détours réels
durée = durée_itineraire × (vitesse_référence / vitesse_mode)
```
On affiche une **fourchette** (`± 20 %`), jamais un prix unique : « 5 500 –
7 000 FC ». Une fourchette est toujours défendable, un chiffre exact est
toujours faux quelque part.

### UX
Home → « Combien pour mon trajet ? » → deux champs (Départ / Arrivée, avec
l'autocomplétion `search_service` déjà présente) → 3 cartes de résultat :

```
🏍️ Moto            6 000 FC · 35 min
🚐 Esprit de mort  1 000 FC · 1 h 15 · 2 changements
🚶 Wewa + bus        800 FC · 1 h 30 · astuce : descends à …
```

Puis : « C'était juste ? » (👍 / 👎 + prix réel) → alimente `retours_tarifs`.

### Bonus viral (gratuit)
Bouton « Envoyer à un ami » sur le résultat → génère une image Statut
« Maison → Gombe : 6 000 FC en moto, 35 min ». Même moteur que le sprint 1.
C'est le contenu le plus partagé le matin.

---

## 7. Sprint 5 — Notif « ton trajet habituel est bloqué » (3 jours)

### Prérequis (le vrai travail)
1. **Centraliser les états de route.** `signalements` est en `select_own`.
   Créer une RPC agrégée qui renvoie des zones (et non des lignes brutes, pour
   la vie privée) :

```sql
create or replace function public.zones_bloquees(p_minutes integer default 30)
returns table (latitude double precision, longitude double precision,
               etat text, temoins integer, maj_a timestamptz)
language sql security definer set search_path = public stable
as $$
  select round(s.latitude, 3), round(s.longitude, 3), s.etat,
         count(distinct s.user_id)::int, max(s.cree_a)
    from public.signalements s
   where s.cree_a > now() - make_interval(mins => p_minutes)
     and s.etat in ('Embouteillage', 'Route bloquée', 'Gros embouteillages')
   group by 1, 2, 3
  having count(distinct s.user_id) >= 2;
$$;
```
   Deux témoins minimum : un seul signalement ne doit jamais déclencher une notif.

2. **Trajets habituels**
```sql
create table if not exists public.trajets_habituels (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id)
    on delete cascade on update cascade,
  libelle text not null,
  depart_lat double precision not null,
  depart_lon double precision not null,
  arrivee_lat double precision not null,
  arrivee_lon double precision not null,
  heure_depart time not null,
  jours smallint[] not null default '{1,2,3,4,5}',
  actif boolean not null default true,
  cree_a timestamptz not null default now()
);
```

### MVP (2 j) — local, sans serveur
Au lancement de l'app (et au retour au premier plan) :
1. charger `zones_bloquees(30)` ;
2. pour chaque trajet actif du jour dont l'heure de départ est dans
   `[now, now+45 min]`, vérifier si une zone bloquée est à moins de 400 m de
   l'itinéraire (distance point-segment sur la polyline, simple) ;
3. si oui → bandeau sur la home + notification locale
   (`flutter_local_notifications`) : « Ton trajet Ngaliema → UNIKIN est bloqué.
   Pars 30 min avant. »

Avantage : aucune infra, ça marche même si l'Edge Function est en retard.
Limite : si l'app n'est pas ouverte, pas de notif.

### v2 (1 j) — push serveur
Edge Function `alertes-trajets` déclenchée par `pg_cron` toutes les 15 min :
elle lit `trajets_habituels` + `zones_bloquees`, calcule les correspondances,
et envoie via l'infra `envoyer-push` **déjà en place** (`appareils_push`,
`preferences_notifications`). Ajouter une préférence `trajets_habituels`
(aujourd'hui absente de `preferences_notifications`).

Anti-spam : **1 notif maximum par trajet et par jour**. Une app qui notifie
trop se fait désinstaller le jour même.

---

## 8. Ordre de livraison et jalons

| Semaine | Livrable | Critère de réussite |
|---|---|---|
| S1 | Sprint 0 + 1 | 10 images Statut partagées, 1 nouveau user identifié par parrainage |
| S2 | Sprint 2 | 50 infos publiées, 1 classement de commune vivant |
| S3 | Sprint 3 + 4 | 30 % des utilisateurs actifs votent eau/courant |
| S4 | Sprint 5 + polish | 1 notif sauvée = 1 user qui revient |

**Métriques à instrumenter dès le sprint 1** (sinon on navigue à vue) :
- images générées / partagées (ratio > 0,5 = bon) ;
- inscrits par parrainage / total ;
- infos publiées par jour et par commune ;
- confirmations par info (médiane > 3 = la boucle tourne) ;
- rétention J1 / J7 ;
- ouvertures de l'app par user et par jour (objectif 2, comme la météo).

---

## 9. Risques réels (Kinshasa, pas Paris)

| Risque | Impact | Parade |
|---|---|---|
| Fausse alerte « route bloquée » | Danger physique + crédibilité morte | expiration auto 60 min, 2 témoins pour la carte, bouton « c'est faux » |
| Rumeurs / politique | Signalements, stores | types limités (trafic, eau, courant, internet, sécurité), pas de texte libre dans les images sans modération |
| Fermes de comptes pour le classement | Classement pourri | compte > 24 h, plafond 100 pts/j, 1 confirmation par info |
| Coût Supabase (images, votes) | Facture | images générées côté téléphone (0 stockage), votes purgés > 30 j |
| Batterie / data | Désinstallation | pas de GPS continu, pas de polling < 30 s, images 1080 px PNG ~200 Ko |
| WhatsApp change son API | Partage cassé | on utilise la feuille de partage système, jamais une API non publique |
| `share_plus` / Android 13+ | Partage KO | tester sur un vrai Android avant de crier victoire |

---

## 10. Ce qu'on fait maintenant

**Ordre exact :**
1. Exécuter `supabase/CORRIGER_BUCKET_PHOTOS.sql` (photos cassées, et l'image
   Statut en aura besoin pour les infos avec photo).
2. Sprint 0 : SQL socle + `commune` + `publier_info`.
3. Sprint 1 : `ImageStatutService` + aperçu + partage.

**Trois décisions à prendre avant que je code :**
1. **Le lien de pied d'image** : tu as un domaine `kinflow.cd` ? Sinon on met
   le lien Play Store avec `?ref=<code_ami>` — mais il faut que l'app soit
   publiée pour que ça convertisse.
2. **La commune** : demandée à l'inscription, ou seulement à la première
   publication ? (je recommande : à la première publication, pour ne pas
   bloquer l'inscription).
3. **Les tarifs** : on part sur mes hypothèses (moto 1 500 + 400/km) et on
   calibre avec des retours, ou tu me donnes tes vrais prix de départ ?
