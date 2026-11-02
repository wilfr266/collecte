import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:terenza/core/security/supabase_secure_storage.dart';
import 'package:terenza/features/auth/data/auth_repository.dart';
import 'package:terenza/features/auth/domain/login_failure.dart';
import 'package:terenza/features/auth/presentation/auth_providers.dart';
import 'package:terenza/features/auth/presentation/login_page.dart';

/// Dépôt factice : seule la connexion est utilisée par l'écran de connexion.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this.failure);

  final Object? failure;
  String? receivedEmail;
  String? receivedPassword;

  @override
  Future<void> signIn({required String email, required String password}) async {
    receivedEmail = email;
    receivedPassword = password;
    if (failure != null) throw failure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _invalidCredentials = AuthApiException(
  'Invalid login credentials',
  statusCode: '400',
  code: 'invalid_credentials',
);

void main() {
  group('classifyLoginError', () {
    test('cas 2 — mauvais mot de passe (réponse réelle du serveur : 400)', () {
      expect(
        classifyLoginError(_invalidCredentials),
        LoginFailure.invalidCredentials,
      );
    });

    test('cas 9 — réseau absent ou permission INTERNET manquante', () {
      expect(
        classifyLoginError(
          AuthRetryableFetchException(
            message: 'ClientException with SocketException: Failed host lookup',
          ),
        ),
        LoginFailure.network,
      );
      expect(
        classifyLoginError(TimeoutException('signIn')),
        LoginFailure.network,
      );
      expect(
        classifyLoginError(const SocketException('Network is unreachable')),
        LoginFailure.network,
      );
    });

    test('une panne serveur n’est ni réseau ni mot de passe', () {
      expect(
        classifyLoginError(
          AuthRetryableFetchException(message: 'oops', statusCode: '503'),
        ),
        LoginFailure.server,
      );
      expect(
        classifyLoginError(
          const AuthApiException('Database error', statusCode: '500'),
        ),
        LoginFailure.server,
      );
    });

    test('cas 4 — e-mail non confirmé, limite de tentatives, compte banni', () {
      expect(
        classifyLoginError(
          const AuthApiException(
            'Email not confirmed',
            statusCode: '400',
            code: 'email_not_confirmed',
          ),
        ),
        LoginFailure.emailNotConfirmed,
      );
      expect(
        classifyLoginError(
          const AuthApiException('Too many', statusCode: '429'),
        ),
        LoginFailure.rateLimited,
      );
      expect(
        classifyLoginError(
          const AuthApiException(
            'User is banned',
            statusCode: '400',
            code: 'user_banned',
          ),
        ),
        LoginFailure.accountBlocked,
      );
    });

    test('l’existence d’un compte n’est jamais révélée', () {
      expect(
        classifyLoginError(
          const AuthApiException(
            'User not found',
            statusCode: '400',
            code: 'user_not_found',
          ),
        ),
        LoginFailure.invalidCredentials,
      );
    });
  });

  group('describeAccessLoadError (après authentification réussie)', () {
    test('cas 3/6 — refus RLS distinct d’une erreur de mot de passe', () {
      final message = describeAccessLoadError(
        const PostgrestException(message: 'permission denied', code: '42501'),
        subject: 'votre profil',
      );
      expect(message, contains('n’a pas accès'));
      // Le code technique reste dans les journaux, jamais à l'écran.
      expect(message, isNot(contains('42501')));
    });

    test('session expirée', () {
      expect(
        describeAccessLoadError(
          const PostgrestException(message: 'JWT expired', code: 'PGRST303'),
          subject: 'votre profil',
        ),
        'Votre session a expiré. Reconnectez-vous.',
      );
    });

    test('réseau coupé après connexion', () {
      expect(
        describeAccessLoadError(
          const SocketException('down'),
          subject: 'votre profil',
        ),
        contains('Vérifiez votre connexion Internet'),
      );
    });
  });

  group('écran de connexion', () {
    Future<_FakeAuthRepository> submit(
      WidgetTester tester,
      Object? failure,
    ) async {
      final repository = _FakeAuthRepository(failure);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(home: LoginPage()),
        ),
      );
      await tester.enterText(
        find.byType(TextFormField).at(0),
        '  Collecteur@Test.local ',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'Mot de passe 1',
      );
      await tester.tap(find.text('Se connecter'));
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('transmet les identifiants sans altérer le mot de passe', (
      tester,
    ) async {
      final repository = await submit(tester, null);
      expect(repository.receivedPassword, 'Mot de passe 1');
      expect(repository.receivedEmail, '  Collecteur@Test.local ');
    });

    testWidgets('cas 2 — mauvais mot de passe', (tester) async {
      await submit(tester, _invalidCredentials);
      expect(
        find.text('Adresse e-mail ou mot de passe incorrect.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'cas 9 — réseau : message réseau, pas « réessayez plus tard »',
      (tester) async {
        await submit(
          tester,
          AuthRetryableFetchException(message: 'SocketException'),
        );
        expect(find.text(LoginFailure.network.message), findsOneWidget);
        expect(find.text(LoginFailure.unknown.message), findsNothing);
      },
    );
  });

  group('cas 8 — session persistée dans le stockage sécurisé', () {
    test('la session est relue après réouverture puis effacée', () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      const first = SupabaseSecureLocalStorage(storage);
      await first.persistSession('{"access_token":"jeton"}');

      // Nouvelle instance : simule un redémarrage de l'application.
      const reopened = SupabaseSecureLocalStorage(storage);
      expect(await reopened.hasAccessToken(), isTrue);
      expect(await reopened.accessToken(), '{"access_token":"jeton"}');

      await reopened.removePersistedSession();
      expect(await reopened.hasAccessToken(), isFalse);
    });
  });
}
