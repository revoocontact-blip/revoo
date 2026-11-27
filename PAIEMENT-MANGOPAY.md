# Orleoo : brancher le paiement Mangopay

Tout est prêt côté site et base de données. Aujourd'hui le site est en **mode démo** : aucun argent réel ne circule.

## Ce qui est déjà en place

- **Tout se paie sur Orleoo.** Le site ne propose plus de paiement direct entre membres (main propre en espèces, PayPal…).
- **Paiements extérieurs bloqués.** Les messages, annonces et propositions d'échange qui contiennent les éléments suivants sont refusés :
  - un numéro de téléphone ;
  - un e-mail ;
  - un IBAN ;
  - un moyen de paiement extérieur (PayPal, Lydia, Wero, virement, espèces…) ;
  - une invitation à continuer ailleurs (WhatsApp, Instagram…).

  Le blocage se fait sur le site **et** sur le serveur : on ne peut pas le contourner.
- **Paiement par carte prêt à activer.** Le parcours prévu :
  1. Les articles sont réservés 5 minutes.
  2. L'acheteur paie sur la page sécurisée Mangopay (3-D Secure).
  3. La commande n'est créée qu'après la confirmation de Mangopay.
  4. Si le paiement échoue ou est abandonné, les articles sont remis en vente.
- **Argent bloqué jusqu'à la réception**, puis versé au vendeur.

## Fichiers

| Fichier | Rôle |
|---|---|
| `supabase/sql/supabase-paiement-securise.sql` | À lancer dans Supabase (SQL Editor). Ajoute le blocage, les tables de paiement et le mode de paiement. |
| `supabase/functions/orleoo-paiement/index.ts` | Fonction serveur qui parle à Mangopay. **À tester en sandbox avant toute mise en production.** |

## Étapes, dans l'ordre

1. **Maintenant** : lance `supabase/sql/supabase-paiement-securise.sql` puis `supabase/sql/supabase-frais.sql` dans Supabase > SQL Editor.
2. **Signer avec Mangopay.** Récupère le *Client ID* et la *clé API*, d'abord en **sandbox** (test).
3. **Ranger les clés.** Ajoute-les dans Supabase > Edge Functions > **Secrets** (jamais dans le site, jamais dans un message) :
   - `MANGOPAY_CLIENT_ID`
   - `MANGOPAY_API_KEY`
   - `MANGOPAY_BASE` = `https://api.sandbox.mangopay.com`
   - `SITE_URL` = l'adresse du site
4. **Déployer la fonction** `orleoo-paiement`, avec la vérification JWT désactivée : Mangopay doit pouvoir appeler le webhook.
5. **Déclarer le webhook dans Mangopay** :
   - URL : `https://<ton-projet>.supabase.co/functions/v1/orleoo-paiement`
   - Événements : `PAYIN_NORMAL_SUCCEEDED` et `PAYIN_NORMAL_FAILED`.
6. **Tester en sandbox** avec les cartes de test Mangopay.
7. **Ouvrir pour de vrai** :
   - passe `MANGOPAY_BASE` sur `https://api.mangopay.com` avec les clés de production ;
   - dans Supabase, lance `update public.site_settings set payment_mode = 'mangopay', achats_ouverts = true where id = 1;` (ouvre les achats côté serveur) ;
   - dans `index.html`, mets `revooPayDemo: false` et `vitrine: false`.

## Encore à construire avec Mangopay (avant l'ouverture)

- Remboursements (litiges, annulations).
- IBAN du vendeur et virement vers sa banque.
- Vérification d'identité des vendeurs (KYC), exigée par Mangopay.
- Paiement du complément d'un échange (le champ `topup_paid` est prêt).
- Textes légaux (CGU, CGV) à faire relire par un professionnel.
