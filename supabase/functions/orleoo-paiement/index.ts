// =====================================================================
// ORLEOO — Edge Function « orleoo-paiement » (préparation Mangopay)
//
// ⚠️ PAS ENCORE ACTIVE. À déployer et tester en SANDBOX Mangopay avant tout
//    paiement réel. Tant que site_settings.payment_mode = 'demo', le site ne
//    l'appelle pas.
//
// Secrets à créer dans Supabase > Edge Functions > Secrets (JAMAIS dans le site) :
//   MANGOPAY_CLIENT_ID   identifiant client Mangopay
//   MANGOPAY_API_KEY     clé API Mangopay (secrète)
//   MANGOPAY_BASE        https://api.sandbox.mangopay.com (test) puis https://api.mangopay.com
//   SITE_URL             https://revoocontact-blip.github.io/revoo/
// SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis automatiquement par Supabase.
//
// Parcours prévu (argent bloqué jusqu'à la réception) :
//   1. Le site appelle start_checkout (SQL) : articles réservés 30 min.
//   2. Le site appelle cette fonction { action: "payer", checkout } :
//      compte Mangopay de l'acheteur + porte-monnaie créés si besoin,
//      puis paiement par carte sur la page sécurisée Mangopay (3-D Secure).
//   3. Mangopay prévient cette fonction (webhook) : paiement réussi
//      → finalize_checkout (SQL) crée les commandes ; échec → fail_checkout.
//   4. Réception confirmée → { action: "liberer", order } : virement interne
//      du porte-monnaie de l'acheteur vers celui du vendeur.
//   5. Le vendeur demande un virement vers sa banque (KYC obligatoire chez Mangopay).
// =====================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const MP_BASE = Deno.env.get("MANGOPAY_BASE") ?? "https://api.sandbox.mangopay.com";
const MP_ID = Deno.env.get("MANGOPAY_CLIENT_ID") ?? "";
const MP_KEY = Deno.env.get("MANGOPAY_API_KEY") ?? "";
const SITE_URL = Deno.env.get("SITE_URL") ?? "";
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const cents = (euros: number) => Math.round(Number(euros) * 100);
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...cors } });
const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
};

// ---------- Mangopay : jeton OAuth puis appels API ----------
let token: { value: string; until: number } | null = null;
async function mpToken() {
  if (token && token.until > Date.now() + 60_000) return token.value;
  const r = await fetch(`${MP_BASE}/v2.01/oauth/token`, {
    method: "POST",
    headers: { authorization: "Basic " + btoa(`${MP_ID}:${MP_KEY}`), "content-type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials",
  });
  if (!r.ok) throw new Error("Connexion Mangopay impossible");
  const d = await r.json();
  token = { value: d.access_token, until: Date.now() + d.expires_in * 1000 };
  return token.value;
}
async function mp(path: string, method = "GET", body?: unknown, idempotencyKey?: string) {
  const headers: Record<string, string> = { authorization: "Bearer " + (await mpToken()), "content-type": "application/json" };
  if (idempotencyKey) headers["idempotency-key"] = idempotencyKey;   // évite un double paiement si on réessaie
  const r = await fetch(`${MP_BASE}/v2.01/${MP_ID}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`Mangopay ${path} : ${d?.Message ?? r.status}`);
  return d;
}

// ---------- Compte Mangopay + porte-monnaie d'un membre ----------
async function ensureAccount(userId: string, who: { firstName: string; lastName: string; email: string }) {
  const { data: acc } = await admin.from("payment_accounts").select("*").eq("user_id", userId).maybeSingle();
  if (acc?.provider_user_id && acc?.wallet_id) return acc;
  // À vérifier en sandbox : champs exigés selon la catégorie (PAYER pour acheter ;
  // OWNER avec adresse, date de naissance, nationalité pour recevoir de l'argent).
  const user = acc?.provider_user_id ? { Id: acc.provider_user_id } : await mp("/users/natural", "POST", {
    FirstName: who.firstName, LastName: who.lastName, Email: who.email,
    UserCategory: "PAYER", TermsAndConditionsAccepted: true, Tag: userId,
  }, `user-${userId}`);
  const wallet = await mp("/wallets", "POST", { Owners: [user.Id], Currency: "EUR", Description: "Porte-monnaie Orleoo", Tag: userId }, `wallet-${userId}`);
  const row = { user_id: userId, provider_user_id: user.Id, wallet_id: wallet.Id, updated_at: new Date().toISOString() };
  await admin.from("payment_accounts").upsert(row);
  return row;
}

// ---------- 1. Payer un panier ou un complément d'échange ----------
async function payer(req: Request, body: any) {
  const jwt = (req.headers.get("authorization") ?? "").replace("Bearer ", "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Connexion requise" }, 401);
  const { data: c } = await admin.from("checkouts").select("*").eq("id", body.checkout).maybeSingle();
  if (!c || c.buyer_id !== user.id) return json({ error: "Paiement introuvable" }, 404);
  if (c.status !== "en_attente" || new Date(c.expires_at) < new Date()) return json({ error: "Ce paiement a expiré : recommence depuis ton panier." }, 409);
  const first = String(body.firstName ?? "").trim(), last = String(body.lastName ?? "").trim();
  if (!first || !last) return json({ error: "Indique ton prénom et ton nom (exigés par notre prestataire de paiement)." }, 400);
  const acc = await ensureAccount(user.id, { firstName: first, lastName: last, email: user.email ?? "" });
  // Paiement par carte sur la page sécurisée Mangopay : Orleoo ne voit jamais les numéros de carte.
  const payin = await mp("/payins/card/web", "POST", {
    AuthorId: acc.provider_user_id, CreditedWalletId: acc.wallet_id,
    DebitedFunds: { Currency: "EUR", Amount: cents(c.amount) + cents(c.fee) },
    Fees: { Currency: "EUR", Amount: cents(c.fee) },                  // frais Orleoo prélevés ici
    ReturnURL: `${SITE_URL}#/compte/achats?paiement=${c.id}`,
    CardType: "CB_VISA_MASTERCARD", Culture: "FR", Tag: c.id,
  }, `payin-${c.id}`);
  await admin.from("checkouts").update({ provider_payin_id: payin.Id }).eq("id", c.id);
  return json({ redirect: payin.RedirectURL });
}

// ---------- 2. Webhook Mangopay (à déclarer dans le tableau de bord Mangopay) ----------
// Mangopay appelle cette URL avec ?EventType=...&RessourceId=... : on relit toujours
// le paiement chez Mangopay au lieu de croire le message.
async function webhook(url: URL) {
  const type = url.searchParams.get("EventType") ?? "";
  const id = url.searchParams.get("RessourceId") ?? "";
  if (!id || !type.startsWith("PAYIN_NORMAL_")) return new Response("ok");
  const payin = await mp(`/payins/${id}`);
  const checkout = payin.Tag;
  if (payin.Status === "SUCCEEDED") await admin.rpc("finalize_checkout", { p_checkout: checkout, p_payin: payin.Id });
  else if (payin.Status === "FAILED") await admin.rpc("fail_checkout", { p_checkout: checkout, p_status: "echoue" });
  return new Response("ok");
}

// ---------- 3. Libérer l'argent vers le vendeur (après réception) ----------
// À appeler depuis le serveur uniquement (tâche planifiée ou modération), jamais depuis le navigateur.
async function liberer(body: any) {
  const { data: o } = await admin.from("orders").select("*").eq("id", body.order).maybeSingle();
  if (!o || o.status !== "received" || o.demo) return json({ error: "Commande non éligible" }, 409);
  const { data: buyer } = await admin.from("payment_accounts").select("*").eq("user_id", o.buyer_id).maybeSingle();
  const { data: seller } = await admin.from("payment_accounts").select("*").eq("user_id", o.seller_id).maybeSingle();
  if (!buyer?.wallet_id || !seller?.wallet_id) return json({ error: "Le vendeur doit d'abord activer son porte-monnaie" }, 409);
  const t = await mp("/transfers", "POST", {
    AuthorId: buyer.provider_user_id, DebitedWalletId: buyer.wallet_id, CreditedWalletId: seller.wallet_id,
    DebitedFunds: { Currency: "EUR", Amount: cents(o.price) }, Fees: { Currency: "EUR", Amount: 0 }, Tag: o.id,
  }, `transfer-${o.id}`);
  await admin.from("wallet_moves").update({ status: "disponible", order_id: o.id, provider_ref: t.Id, updated_at: new Date().toISOString() })
    .eq("user_id", o.seller_id).eq("kind", "vente").eq("status", "bloque").eq("provider_ref", o.payment_id);
  return json({ ok: true });
}

// À FAIRE avec Mangopay avant l'ouverture : remboursements (POST /payins/{id}/refunds),
// compte bancaire du vendeur (POST /users/{id}/bankaccounts/iban), vérification d'identité
// (KYC), virements vers la banque (POST /payouts/bankwire), complément d'échange.

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const url = new URL(req.url);
  try {
    if (req.method === "GET") return await webhook(url);
    const body = await req.json().catch(() => ({}));
    if (body.action === "payer") return await payer(req, body);
    if (body.action === "liberer") {
      // réservé au serveur : la clé service_role doit être présentée
      if ((req.headers.get("authorization") ?? "") !== `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`) return json({ error: "Interdit" }, 403);
      return await liberer(body);
    }
    return json({ error: "Action inconnue" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: "Le paiement n'a pas pu aboutir. Réessaie dans un instant." }, 500);
  }
});
