import 'package:flutter_test/flutter_test.dart';

import 'package:terenza/features/auth/domain/access_decision.dart';
import 'package:terenza/features/auth/domain/user_profile.dart';
import 'package:terenza/features/auth/domain/user_role.dart';

UserProfile _profile(AccountStatus status, {String? org = 'org-a'}) =>
    UserProfile(
      id: 'u1',
      displayName: 'Test',
      status: status,
      organizationId: org,
    );

AccessDenialReason? _denial(AccessDecision decision) =>
    decision is AccessDenied ? decision.reason : null;

void main() {
  group('AccountStatus', () {
    test('correspond exactement à public.profile_status', () {
      expect(AccountStatus.fromKey('active'), AccountStatus.active);
      expect(AccountStatus.fromKey('pending'), AccountStatus.pending);
      expect(AccountStatus.fromKey('suspended'), AccountStatus.suspended);
      expect(AccountStatus.fromKey('disabled'), AccountStatus.disabled);
    });

    test('approved et rejected ne sont pas assimilés à active', () {
      expect(AccountStatus.fromKey('approved'), AccountStatus.unknown);
      expect(AccountStatus.fromKey('rejected'), AccountStatus.unknown);
    });
  });

  group('resolveAccess', () {
    test('collecteur autorisé → tableau de bord collecteur', () {
      final decision = resolveAccess(
        profile: _profile(AccountStatus.active),
        roles: [UserRole.collector],
      );
      expect((decision as AccessGranted).homeRoute, '/dashboard');
    });

    test('client autorisé → espace client', () {
      final decision = resolveAccess(
        profile: _profile(AccountStatus.active),
        roles: [UserRole.client],
      );
      expect((decision as AccessGranted).homeRoute, '/client');
    });

    test('le statut prime sur le rôle', () {
      for (final (status, reason) in [
        (AccountStatus.pending, AccessDenialReason.pending),
        (AccountStatus.suspended, AccessDenialReason.suspended),
        (AccountStatus.disabled, AccessDenialReason.disabled),
        (AccountStatus.unknown, AccessDenialReason.unknownStatus),
      ]) {
        final decision = resolveAccess(
          profile: _profile(status),
          roles: [UserRole.admin, UserRole.collector],
        );
        expect(_denial(decision), reason, reason: status.key);
      }
    });

    test('profil absent → refus', () {
      expect(
        _denial(resolveAccess(profile: null, roles: [UserRole.collector])),
        AccessDenialReason.missingProfile,
      );
    });

    test('sans organisation → rattachement requis, sauf super-admin', () {
      expect(
        _denial(
          resolveAccess(
            profile: _profile(AccountStatus.active, org: null),
            roles: [UserRole.collector],
          ),
        ),
        AccessDenialReason.unassigned,
      );
      expect(
        resolveAccess(
          profile: _profile(AccountStatus.active, org: null),
          roles: [UserRole.superAdmin],
        ),
        isA<AccessGranted>(),
      );
    });

    test('sans rôle mobile → refus contrôlé', () {
      for (final roles in [
        <UserRole>[],
        [UserRole.auditor],
      ]) {
        expect(
          _denial(
            resolveAccess(
              profile: _profile(AccountStatus.active),
              roles: roles,
            ),
          ),
          AccessDenialReason.noMobileRole,
        );
      }
    });
  });

  group('accessRedirect', () {
    const collector = AccessGranted(
      roles: [UserRole.collector],
      spaces: [MobileSpace.collector],
    );
    const client = AccessGranted(
      roles: [UserRole.client],
      spaces: [MobileSpace.client],
    );

    test('déconnecté : seules les routes publiques restent ouvertes', () {
      const decision = AccessSignedOut();
      expect(accessRedirect(decision, '/auth'), isNull);
      expect(accessRedirect(decision, '/forgot-password'), isNull);
      expect(accessRedirect(decision, '/dashboard'), '/auth');
      expect(accessRedirect(decision, '/reset-password'), '/auth');
    });

    test('vérification en cours, échec ou refus : jamais d’accès protégé', () {
      for (final decision in <AccessDecision>[
        const AccessChecking(),
        const AccessUnavailable('erreur'),
        const AccessDenied(AccessDenialReason.pending),
        const AccessNotConfigured(configured: true),
      ]) {
        expect(accessRedirect(decision, '/dashboard'), '/auth');
        expect(accessRedirect(decision, '/client'), '/auth');
        expect(accessRedirect(decision, '/auth'), isNull);
      }
    });

    test('accordé : /auth renvoie vers l’espace', () {
      expect(accessRedirect(collector, '/auth'), '/dashboard');
      expect(accessRedirect(client, '/auth'), '/client');
    });

    test('un espace étranger renvoie vers l’accueil du rôle', () {
      expect(accessRedirect(client, '/cash'), '/client');
      expect(accessRedirect(client, '/admin'), '/client');
      expect(accessRedirect(collector, '/client'), '/dashboard');
      expect(accessRedirect(collector, '/missions'), isNull);
      expect(accessRedirect(client, '/profile'), isNull);
    });

    test(
      'récupération : la session est dirigée vers le nouveau mot de passe',
      () {
        expect(
          accessRedirect(collector, '/dashboard', recoveryPending: true),
          '/reset-password',
        );
        expect(
          accessRedirect(
            const AccessDenied(AccessDenialReason.suspended),
            '/auth',
            recoveryPending: true,
          ),
          '/reset-password',
        );
        expect(
          accessRedirect(collector, '/reset-password', recoveryPending: true),
          isNull,
        );
      },
    );

    test('sans lien de récupération, /reset-password est inaccessible', () {
      expect(accessRedirect(collector, '/reset-password'), '/dashboard');
      expect(
        accessRedirect(const AccessChecking(), '/reset-password'),
        '/auth',
      );
      expect(
        accessRedirect(const AccessSignedOut(), '/reset-password'),
        '/auth',
      );
    });

    test('hors ligne : espace collecteur restreint au cache', () {
      const offline = AccessGranted(
        roles: [UserRole.collector],
        spaces: [MobileSpace.collector],
        offline: true,
      );
      expect(accessRedirect(offline, '/auth'), '/offline');
      expect(accessRedirect(offline, '/admin'), '/offline');
    });
  });
}
