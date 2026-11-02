# Décisions techniques

## 2026-10-21 — Socle mobile

- **Flutter/Dart** : conserver le projet multi-plateforme déjà présent; versions fournies par l'environnement: Flutter 3.44.7, Dart 3.12.2.
- **Nom Dart** : `terenza`, en minuscules conformément aux conventions de packages Dart.
- **État et injection** : `flutter_riverpod ^2.6.1`.
- **Navigation** : `go_router ^14.8.1` avec shell et routes nommées.
- **UI** : Material 3, thèmes clair et sombre centralisés, interface en français.
- **Structure** : feature-first; chaque feature séparera domaine, données et présentation à mesure que ses cas d'usage seront établis.
- **Environnements** : `APP_ENV` via `--dart-define`; valeurs inconnues refusées. Aucune donnée de démonstration n'est utilisée par les écrans connectés.
- **Identifiants natifs** : `com.example.terenza` est temporaire, pas un identifiant de publication.
- **Backend** : aucun projet Supabase distant ni secret supposé; phase 1 n'inclut pas le SDK Supabase.

Les versions de packages ont été sélectionnées pour les contraintes Dart déclarées, mais leur résolution réelle reste à confirmer par `flutter pub get`.
