# Orleoo : activer le captcha anti-robots (Cloudflare Turnstile)

Le site est déjà protégé de deux façons, sans rien à faire :

- un **champ piège invisible** que seuls les robots remplissent ;
- un **délai minimum** : un formulaire d'inscription envoyé en moins de 2,5 secondes est refusé.

Pour aller plus loin, le captcha **Cloudflare Turnstile** est déjà branché sur l'inscription, la connexion et « mot de passe oublié ». Il est gratuit et, la plupart du temps, invisible pour les vrais visiteurs.

## Étapes, dans cet ordre

1. **Créer le captcha chez Cloudflare** (gratuit)
   - Crée un compte sur cloudflare.com, puis ouvre **Turnstile** > **Add widget**.
   - Nom : `Orleoo`. Domaine : `revoocontact-blip.github.io` (et plus tard ton nom de domaine).
   - Mode : **Managed**.
   - Cloudflare te donne deux clés :
     - la **Site Key** (publique) : tu peux me la donner dans le chat ;
     - la **Secret Key** (secrète) : **ne la donne à personne**, elle va seulement dans Supabase (étape 3).

2. **Mettre la clé publique dans le site** : dans `index.html`, remplis `turnstileSiteKey: "ta-site-key"` (ou donne-la-moi). Publie le site.

3. **Activer la vérification dans Supabase**, seulement **après** l'étape 2 :
   - Supabase > **Authentication** > **Attack Protection** > **Enable Captcha protection** ;
   - Provider : **Turnstile by Cloudflare** ;
   - colle la **Secret Key**, puis **Save**.

⚠️ Si tu fais l'étape 3 avant l'étape 2, plus personne ne pourra se connecter : il suffit alors de désactiver l'option dans Supabase.

## Pour désactiver

Supabase > Authentication > Attack Protection : décoche le captcha, puis vide `turnstileSiteKey` dans le site.
