// =====================================================================
// ORLEOO — Edge Function « orleoo-push » : envoie les notifications sur téléphone
//
// Appelée uniquement par la base (public.send_push) avec l'en-tête x-orleoo-hook.
// Secrets (Supabase > Edge Functions > Secrets, JAMAIS dans le site) :
//   VAPID_PUBLIC_KEY   clé publique (la même que CONFIG.vapidPublicKey dans le site)
//   VAPID_PRIVATE_KEY  clé privée
//   PUSH_HOOK_SECRET   même valeur que le secret « push_hook_secret » du coffre de la base
// SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis automatiquement.
// À déployer avec la vérification JWT désactivée (l'en-tête secret la remplace).
// =====================================================================
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const HOOK = Deno.env.get("PUSH_HOOK_SECRET") ?? "";
webpush.setVapidDetails("mailto:orleoo.contact@gmail.com", Deno.env.get("VAPID_PUBLIC_KEY") ?? "", Deno.env.get("VAPID_PRIVATE_KEY") ?? "");
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// comparaison à temps constant
function same(a: string, b: string) {
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST" || !HOOK || !same(req.headers.get("x-orleoo-hook") ?? "", HOOK)) return new Response("Interdit", { status: 403 });
  const { user_id, title, body, url } = await req.json().catch(() => ({}));
  if (!user_id || !title) return new Response("Requête incomplète", { status: 400 });
  const { data: subs } = await admin.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", user_id);
  const payload = JSON.stringify({ title: String(title).slice(0, 80), body: String(body ?? "").slice(0, 180), url: String(url ?? "#/").slice(0, 200) });
  let sent = 0;
  for (const s of subs ?? []) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "normal" });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await admin.from("push_subscriptions").delete().eq("id", s.id);   // appareil désabonné
      else console.error("push", code);
    }
  }
  return new Response(JSON.stringify({ sent }), { headers: { "content-type": "application/json" } });
});
