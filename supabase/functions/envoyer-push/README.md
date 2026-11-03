# Fonction Edge : envoyer-push

Envoie des notifications Firebase Cloud Messaging (HTTP v1) aux appareils
enregistrés, en respectant `preferences_notifications`.

## Déploiement
```bash
supabase functions deploy envoyer-push --no-verify-jwt
```

## Secrets
- `FCM_SERVICE_ACCOUNT_JSON` : JSON du compte de service Firebase
- `KINFLOW_PUSH_SECRET` : secret partagé avec l'appelant
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`

## Appel
```http
POST /functions/v1/envoyer-push
x-kinflow-secret: <KINFLOW_PUSH_SECRET>
Content-Type: application/json

{
  "user_ids": ["uuid"],
  "categorie": "messages",
  "titre": "Nouveau message",
  "corps": "Jean vous a écrit",
  "data": { "type": "message", "ami_id": "uuid" }
}
```

L'application mobile doit encore enregistrer le jeton FCM via
`enregistrer_token_push` après avoir configuré Firebase/APNs.
