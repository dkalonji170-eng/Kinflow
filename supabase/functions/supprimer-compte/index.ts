// Supabase Edge Function — Suppression complète du compte utilisateur.
// Requiert l'en-tête Authorization: Bearer <access_token> de l'utilisateur.
// Nécessite les secrets : SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ erreur: "methode_non_autorisee" }),
      {
        status: 405,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      },
    );
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(
        JSON.stringify({ erreur: "serveur_non_configure" }),
        {
          status: 500,
          headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
        },
      );
    }

    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace("Bearer ", "").trim();
    if (!token) {
      return new Response(
        JSON.stringify({ erreur: "non_authentifie" }),
        {
          status: 401,
          headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
        },
      );
    }

    // Client avec le jeton utilisateur pour identifier le compte.
    const supabaseUtilisateur = createClient(supabaseUrl, serviceRoleKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: utilisateur, error: erreurUtilisateur } =
      await supabaseUtilisateur.auth.getUser(token);
    if (erreurUtilisateur || !utilisateur?.user?.id) {
      return new Response(
        JSON.stringify({ erreur: "session_invalide" }),
        {
          status: 401,
          headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
        },
      );
    }

    const uid = utilisateur.user.id;
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // 1) Lister et supprimer les fichiers Storage personnels.
    // Les chemins sont $uid/$amiId/fichier : on descend récursivement.
    const buckets = ["messages_vocaux", "messages_images"];
    const listerRecursif = async (
      bucket: string,
      prefixe: string,
    ): Promise<string[]> => {
      const { data, error } = await admin.storage
        .from(bucket)
        .list(prefixe, { limit: 1000 });
      if (error || !data) return [];
      const fichiers: string[] = [];
      for (const element of data) {
        const chemin = `${prefixe}/${element.name}`;
        // Un dossier n'a pas d'id et pas de metadata.
        const estDossier = !element.id && !element.metadata;
        if (estDossier) {
          fichiers.push(...await listerRecursif(bucket, chemin));
        } else {
          fichiers.push(chemin);
        }
      }
      return fichiers;
    };

    for (const bucket of buckets) {
      try {
        const chemins = await listerRecursif(bucket, uid);
        if (chemins.length > 0) {
          await admin.storage.from(bucket).remove(chemins);
        }
      } catch (_) {
        // Si un bucket n'existe pas ou si le list échoue, on continue quand même.
      }
    }

    // 2) Purge des données applicatives (toutes les tables KinFlow).
    const { error: erreurPurge } = await admin.rpc("purger_compte", {
      p_uid: uid,
    });
    if (erreurPurge) {
      return new Response(
        JSON.stringify({ erreur: "echec_purge", detail: erreurPurge.message }),
        {
          status: 500,
          headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
        },
      );
    }

    // 3) Suppression définitive du compte Auth.
    const { error: erreurAuth } = await admin.auth.admin.deleteUser(uid);
    if (erreurAuth) {
      return new Response(
        JSON.stringify({ erreur: "echec_suppression_auth", detail: erreurAuth.message }),
        {
          status: 500,
          headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
        },
      );
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(
      JSON.stringify({ erreur: "erreur_inconnue" }),
      {
        status: 500,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      },
    );
  }
});
