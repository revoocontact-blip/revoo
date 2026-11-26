# Scripts de la base de données (Supabase)

**Tous ces scripts sont déjà appliqués sur la base en ligne.** Il n'y a rien à relancer.

Ils servent :
- à reconstruire une base neuve, en les lançant **dans l'ordre ci-dessous** (Supabase > SQL Editor) ;
- à savoir où se trouve chaque règle de la base.

Chaque script peut être relancé sans risque.

| Ordre | Fichier | Contenu |
|---|---|---|
| 1 | `supabase-revoo.sql` | Base de données Supabase |
| 2 | `supabase-profil.sql` | Profil : photo, identifiant unique, données privées |
| 3 | `supabase-parametres.sql` | Paramètres du profil : mode vacances |
| 4 | `supabase-identifiant.sql` | Règle de changement d'identifiant |
| 5 | `supabase-messagerie.sql` | Messagerie entre acheteurs et vendeurs |
| 6 | `supabase-notifications.sql` | E-mail de notification quand on reçoit un nouveau message |
| 7 | `supabase-revoopay.sql` | Commandes (interface ; le paiement Mangopay sera branché plus tard) |
| 8 | `supabase-avis-et-emails.sql` | Avis sur les vendeurs + e-mails de commande |
| 9 | `supabase-signalements.sql` | Signalement d'annonces et modération |
| 10 | `supabase-equipe.sql` | Équipe (fondateur + admins) et outils de modération autonomes |
| 11 | `supabase-securite.sql` | Renforcement de la sécurité (audit complet) |
| 12 | `supabase-orleoo.sql` | Nouveau nom + catégorie Livres |
| 13 | `supabase-styles.sql` | Deux nouveaux styles : Sport et Bohème (6 styles au total) |
| 14 | `supabase-banniere.sql` | Bannière du profil public |
| 15 | `supabase-abonnements.sql` | Abonnements Orleoo Pro / Max / Ultra (étape 1) |
| 16 | `supabase-retirer-abonnements-demo.sql` | Retirer les abonnements de DÉMO (aucun argent réel n'a été payé) |
| 17 | `supabase-impact-visibilite.sql` | Compteur d'impact en temps réel + mise en avant des annonces |
| 18 | `supabase-mainpropre-echange.sql` | Remise en main propre avec code + échanges sécurisés |
| 19 | `supabase-suppression-compte.sql` | « Supprimer mon compte » directement dans le site / l'application |
| 20 | `supabase-paiement-securise.sql` | Paiement 100 % sur Orleoo (préparation Mangopay) |
| 21 | `supabase-frais.sql` | Frais acheteur : 5 % du prix + 0,70 € par article |
| 22 | `supabase-vitrine.sql` | Mode vitrine : liste « Me prévenir » à l'ouverture des achats |
| 23 | `supabase-demo.sql` | La modération peut retirer les annonces de démonstration |
| 24 | `supabase-croissance.sql` | Croissance : alertes de recherche, parrainage, statistiques, badges de confiance |
| 25 | `supabase-contact.sql` | Nouvelle adresse d'expédition des e-mails : orleoo.contact@gmail.com |
| 26 | `supabase-audit-securite.sql` | Corrections de l'audit de sécurité (novembre 2026) |
| 27 | `supabase-qualite.sql` | Qualité des annonces : détection automatique des annonces suspectes, coups de cœur |
| 28 | `supabase-hebdo.sql` | E-mail « Nouveautés de la semaine » (uniquement pour les membres qui l'acceptent) |
| 29 | `supabase-offres-lots.sql` | « Faire une offre » (offre, contre-offre, 48 h) et réductions sur les lots |
| 30 | `supabase-verrou-vitrine.sql` | Mode vitrine : le serveur refuse commandes, paiements et échanges tant que les achats ne sont pas ouverts |
| 31 | `supabase-vendeurs-fondateurs.sql` | Badge « Vendeur fondateur » : les 100 premiers membres avec 5 annonces |

Le script `supabase-contact.sql` suppose que l'adresse d'expédition est validée chez Brevo.

Les clés secrètes (Brevo, Mangopay, service_role…) ne sont **jamais** dans ces fichiers : elles sont rangées dans le coffre de Supabase (Vault et Secrets des Edge Functions).
