# Fonction Edge : supprimer-compte

Suppression complète d'un compte KinFlow :
1. Supprime les fichiers de l'utilisateur dans `messages_vocaux` et `messages_images`.
2. Appelle `public.purger_compte(uid)` en `service_role`.
3. Appelle `auth.admin.deleteUser(uid)`.

## Déploiement
```bash
supabase functions deploy supprimer-compte --no-verify-jwt
```

## Sécrets requis
- SUPABASE_URL
- SUPABASE_SERVICE_ROLE_KEY

L'appel doit inclure `Authorization: Bearer <access_token>` de l'utilisateur.
