# TERENZA

TERENZA est une application Flutter Android/iOS pour les collecteurs. L'authentification et les écrans terrain sont conçus pour Supabase; les parcours métier nécessitent un compte actif et les migrations phase 3 appliquées.

## Prérequis

- Flutter stable 3.44.7 et Dart 3.12.2 (versions constatées dans l'environnement)
- Android SDK et licences Android acceptées pour construire et exécuter Android
- macOS avec Xcode pour construire, signer et exécuter iOS

## Démarrage

```powershell
flutter pub get
flutter run `
  --dart-define=APP_ENV=development `
  --dart-define=SUPABASE_URL=https://your-project-ref.supabase.co `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=your-publishable-key
```

Sans ces deux variables, l'application affiche un écran de configuration et ne simule pas de session. Ne fournis jamais une clé `service_role`, un token personnel ou le mot de passe PostgreSQL à Flutter.

## Environnements

`APP_ENV` accepte `development`, `test` ou `production`. La valeur par défaut est `development`.

```sh
flutter run --dart-define=APP_ENV=test
flutter build apk --release --dart-define=APP_ENV=production
```

Le lien de réinitialisation `terenza://auth/reset-password` doit être autorisé dans la configuration Supabase Auth.

## Contrôles

```sh
dart format lib test
flutter analyze
flutter test
flutter build apk --debug
```

## Architecture et décisions

- [Architecture](docs/ARCHITECTURE.md)
- [Feuille de route](docs/ROADMAP.md)
- [Décisions techniques](docs/DECISIONS_TECHNIQUES.md)
- [Sécurité](docs/SECURITY.md)
- [Stockage et synchronisation hors ligne](docs/OFFLINE_SYNC.md)

Les identifiants natifs `com.example.terenza` sont provisoires et doivent être remplacés par le domaine contrôlé par l'organisation avant publication.
