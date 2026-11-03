// Supabase Edge Function — Envoi de notifications push via Firebase Cloud
// Messaging (HTTP v1).
//
// Secrets requis :
//   FCM_SERVICE_ACCOUNT_JSON : JSON complet du compte de service Firebase
//   KINFLOW_PUSH_SECRET      : secret partagé avec le webhook/appelant
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Corps attendu :
//   {
//     "user_ids": ["uuid", ...],
//     "categorie": "messages" | "embouteillages" | "routes_bloquees" |
//                  "demandes_amis" | "infos",
//     "titre": "...",
//     "corps": "...",
//     "data": { "cle": "valeur" }
//   }
//
// L'envoi respecte `preferences_notifications` (push_actif + catégorie).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const CATEGORIES = new Set([
  "messages",
  "embouteillages",
  "routes_bloquees",
  "demandes_amis",
  "infos",
]);

function base64url(bytes: Uint8Array): string {
  let binaire = "";
  for (const octet of bytes) binaire += String.fromCharCode(octet);
  return btoa(binaire).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlTexte(texte: string): string {
  return base64url(new TextEncoder().encode(texte));
}

function pemVersBuffer(pem: string): ArrayBuffer {
  const contenu = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binaire = atob(contenu);
  const octets = new Uint8Array(binaire.length);
  for (let i = 0; i < binaire.length; i++) octets[i] = binaire.charCodeAt(i);
  return octets.buffer;
}

async function jetonGoogle(compte: {
  client_email: string;
  private_key: string;
}): Promise<string> {
  const maintenant = Math.floor(Date.now() / 1000);
  const entete = base64urlTexte(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64urlTexte(JSON.stringify({
    iss: compte.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: maintenant,
    exp: maintenant + 3600,
  }));
  const aSigner = `${entete}.${claims}`;
  const cle = await crypto.subtle.importKey(
    "pkcs8",
    pemVersBuffer(compte.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cle,
    new TextEncoder().encode(aSigner),
  );
  const assertion = `${aSigner}.${base64url(new Uint8Array(signature))}`;

  const reponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!reponse.ok) {
    throw new Error(`OAuth Google: ${await reponse.text()}`);
  }
  const json = await reponse.json();
  return json.access_token as string;
}

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ erreur: "methode_non_autorisee" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const secretAttendu = Deno.env.get("KINFLOW_PUSH_SECRET");
  if (!secretAttendu ||
      req.headers.get("x-kinflow-secret") !== secretAttendu) {
    return new Response(JSON.stringify({ erreur: "non_autorise" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const compteJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
    if (!compteJson) {
      return new Response(
        JSON.stringify({ erreur: "fcm_non_configure" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    const compte = JSON.parse(compteJson);
    const projet = compte.project_id as string;

    const corps = await req.json();
    const userIds: string[] = Array.isArray(corps.user_ids)
      ? corps.user_ids.filter((e: unknown) => typeof e === "string")
      : [];
    if (userIds.length === 0) {
      return new Response(JSON.stringify({ erreur: "user_ids_manquant" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }
    const categorie = `${corps.categorie ?? ""}`;
    if (!CATEGORIES.has(categorie)) {
      return new Response(JSON.stringify({ erreur: "categorie_invalide" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }
    const titre = `${corps.titre ?? "KinFlow"}`.slice(0, 120);
    const texte = `${corps.corps ?? ""}`.slice(0, 500);

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    });

    const { data: preferences, error: erreurPreferences } = await admin
      .from("preferences_notifications")
      .select("user_id,push_actif," + categorie)
      .in("user_id", userIds);
    if (erreurPreferences) throw erreurPreferences;

    const autorises = new Set(
      (preferences ?? [])
        .filter((p) => p.push_actif === true && p[categorie] === true)
        .map((p) => p.user_id as string),
    );
    // Sans ligne de préférence, on applique les valeurs par défaut (tout actif).
    const avecLigne = new Set((preferences ?? []).map((p) => p.user_id));
    for (const id of userIds) {
      if (!avecLigne.has(id)) autorises.add(id);
    }
    if (autorises.size === 0) {
      return new Response(JSON.stringify({ ok: true, envoyes: 0 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: appareils, error: erreurAppareils } = await admin
      .from("appareils_push")
      .select("token")
      .in("user_id", [...autorises]);
    if (erreurAppareils) throw erreurAppareils;

    const jetons = [...new Set((appareils ?? []).map((a) => a.token as string))];
    if (jetons.length === 0) {
      return new Response(JSON.stringify({ ok: true, envoyes: 0 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const accessToken = await jetonGoogle(compte);
    const data: Record<string, string> = {};
    for (const [cle, valeur] of Object.entries(corps.data ?? {})) {
      data[cle] = `${valeur}`;
    }

    let envoyes = 0;
    const invalides: string[] = [];
    await Promise.all(jetons.map(async (token) => {
      const reponse = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projet}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: titre, body: texte },
              data,
              android: { priority: "HIGH" },
              apns: { payload: { aps: { sound: "default" } } },
            },
          }),
        },
      );
      if (reponse.ok) {
        envoyes++;
      } else {
        const detail = await reponse.text();
        if (detail.includes("UNREGISTERED")) {
          invalides.push(token);
        }
      }
    }));

    if (invalides.length > 0) {
      await admin.from("appareils_push").delete().in("token", invalides);
    }

    return new Response(
      JSON.stringify({ ok: true, envoyes, invalides: invalides.length }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ erreur: "erreur_inconnue", detail: `${e}` }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
