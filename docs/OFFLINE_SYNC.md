# Stockage local et synchronisation TERENZA

## Données conservées

SQLite conserve uniquement les données nécessaires au travail déjà autorisé :

- missions affectées (identifiant, titre, statut, date, zone) ;
- rendez-vous affectés (identifiant, heure, état, établissement et adresse) ;
- établissements actifs des zones de mission (identifiant, nom, adresse, zone) ;
- profil minimal chiffré (identifiant, organisation, nom d'affichage, état, rôles) pour une fenêtre d'accès hors ligne de 24 heures ;
- opérations de visite ou demande de paiement en attente, avec clé d'idempotence ;
- état, nombre de tentatives, erreur technique non sensible et date du dernier cache.

Les téléphones, e-mails, obligations, soldes, reçus et historiques financiers ne sont pas mis en cache. Le montant et le mode d'une demande créée hors ligne sont nécessaires à sa reprise et sont conservés uniquement chiffrés dans l'outbox. Ils sont effacés du payload local dès que la RPC serveur confirme la création de la demande.

## Protection locale

La base SQLite est sous le stockage privé de l'application. Chaque payload cache/outbox est chiffré AES-256-GCM avec une clé aléatoire conservée dans Keychain/Keystore via `flutter_secure_storage`. Les identifiants techniques, type d'opération, états, dates et clé d'idempotence restent visibles dans les métadonnées SQLite. La sauvegarde/restauration Android est désactivée.

Cette protection ne résiste pas à un appareil compromis, déverrouillé, rooté/jailbreaké, à l'exécution instrumentée ou à une extraction après compromission du coffre natif. La déconnexion purge le cache de l'utilisateur; l'outbox reste liée à son propriétaire et n'est jamais envoyée sous un autre compte. Le cache est limité à sept jours; les droits hors ligne à 24 heures depuis la dernière validation en ligne.

## Outbox et reprise

Chaque opération possède UUID local, propriétaire Auth, type, ressource, date, état, tentatives, erreur technique bornée et clé d'idempotence UUID. Le payload est chiffré. Les états sont `pending`, `syncing`, `retryable`, `needsAttention`, `synced`, `dismissed` (schéma local v4). `dismissed` : opération refusée définitivement par le serveur (permission, validation, doublon) puis close depuis l'écran Nouvelle visite pour être corrigée ; rien n'existe côté serveur, la ligne est conservée sans contenu. Une opération en limite de tentatives n'est jamais close automatiquement (le serveur peut l'avoir reçue).

La mise en file locale précède toute requête. Au retour du réseau, au retour au premier plan ou sur demande de l'utilisateur, le client appelle les RPC Supabase. Les visites seules utilisent `record_offline_visit`; les demandes financières utilisent `record_collection_payment_request` ou sa variante GPS. SQLite réinitialise un état `syncing` abandonné à `retryable` au prochain démarrage.

Les retries automatiques utilisent un délai exponentiel à partir de 15 secondes, plafonné à une heure, et s'arrêtent après huit tentatives. Un retry manuel peut contourner le délai. Erreur de permission, validation serveur, conflit d'idempotence ou limite atteinte -> `needsAttention`; aucun écrasement ni rejeu automatique d'une transaction financière conflictuelle.

Le serveur reste la source de vérité. Les clés uniques côté Postgres permettent de reconnaître une réponse perdue après commit et de retourner la même opération à la reprise. Une visite hors ligne est une visite soumise après synchronisation; une demande financière reste `pending`. Aucun reçu n'est confirmé hors serveur.

## Réseau et limitations mobiles

La synchronisation est déclenchée par Connectivity, au premier plan et manuellement. Connectivity peut signaler un réseau Wi-Fi sans accès Internet; une requête échouée marque l'état instable/échec et conserve l'opération. Aucun mécanisme de tâche continue en arrière-plan n'est promis : iOS et Android peuvent suspendre ou tuer l'application. Il faut rouvrir TERENZA ou demander une synchronisation manuelle.

Sans données mission/cache récentes, l'écran hors ligne n'invente pas de liste. Les obligations financières ne sont pas mises en cache; hors ligne, le collecteur peut saisir une visite seule mais ne peut pas créer une demande de paiement sans avoir obtenu l'obligation via le serveur. Les modifications de mission, contribuable ou rendez-vous ne sont pas mises en file.

## Géolocalisation

La localisation est facultative, demandée uniquement pendant l'utilisation et après activation explicite par l'agent. Android demande coarse/fine location; iOS affiche `NSLocationWhenInUseUsageDescription`. Si permission refusée, service désactivé ou précision supérieure à 100 m, l'agent peut continuer sans position. Les coordonnées ne sont pas mises dans le cache de référence; elles voyagent chiffrées dans l'outbox et sont stockées au niveau de la visite après synchronisation, avec précision et horodatage.

Une position GPS ne prouve ni qu'une visite a eu lieu ni qu'un paiement a été reçu. Les règles de conservation et d'accès doivent être validées avec le responsable de traitement avant l'usage de données réelles.

## Vérifications

Tests ajoutés dans `test/offline_store_test.dart` : persistance après fermeture/réouverture, isolation par utilisateur, reprise d'un état `syncing`, refus d'une clé dupliquée, conflits non réessayés automatiquement et chiffrement du payload. Ils restent à exécuter localement avec `flutter test`.

Après revue des migrations 012–013, appliquer les migrations et tester les RPC GPS/visite seule avec `npx supabase test db`. Les scénarios appareil redémarré, session expirée, coupure pendant réponse serveur, précision GPS, iOS/Android et réseau réel nécessitent des essais sur appareils.
