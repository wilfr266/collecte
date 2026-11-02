import 'package:flutter_test/flutter_test.dart';

import 'package:terenza/features/auth/domain/user_role.dart';
import 'package:terenza/features/auth/presentation/auth_providers.dart';

void main() {
  group('UserRole', () {
    test('résout les clés connues et ignore les rôles futurs', () {
      expect(UserRole.fromKey('client'), UserRole.client);
      expect(UserRole.fromKey('super_admin'), UserRole.superAdmin);
      expect(UserRole.fromKey('inconnu'), isNull);
    });

    test('les rôles de back-office n’ouvrent pas d’espace mobile', () {
      for (final role in [
        UserRole.supervisor,
        UserRole.cashier,
        UserRole.auditor,
        UserRole.direction,
      ]) {
        expect(role.mobileSpace, isNull, reason: role.key);
      }
    });
  });

  group('primaryRoleDestination', () {
    test('administration > collecteur > client', () {
      expect(
        primaryRoleDestination([UserRole.client, UserRole.admin]),
        '/admin',
      );
      expect(
        primaryRoleDestination([UserRole.client, UserRole.collector]),
        '/dashboard',
      );
      expect(primaryRoleDestination([UserRole.client]), '/client');
      expect(primaryRoleDestination([UserRole.superAdmin]), '/admin');
    });

    test('aucun espace sans rôle mobile', () {
      expect(primaryRoleDestination([]), isNull);
      expect(primaryRoleDestination([UserRole.auditor]), isNull);
    });
  });

  group('canAccessRoute', () {
    test('un client ne peut pas ouvrir les écrans collecteur ou admin', () {
      const roles = [UserRole.client];
      expect(canAccessRoute(roles, '/client'), isTrue);
      expect(canAccessRoute(roles, '/profile'), isTrue);
      expect(canAccessRoute(roles, '/cash'), isFalse);
      expect(canAccessRoute(roles, '/new-collection'), isFalse);
      expect(canAccessRoute(roles, '/admin'), isFalse);
    });

    test('un collecteur ne peut pas ouvrir l’administration', () {
      const roles = [UserRole.collector];
      expect(canAccessRoute(roles, '/dashboard'), isTrue);
      expect(canAccessRoute(roles, '/admin'), isFalse);
      expect(canAccessRoute(roles, '/client'), isFalse);
    });

    test(
      'un rôle sans espace mobile n’ouvre même pas les routes partagées',
      () {
        expect(canAccessRoute([UserRole.direction], '/profile'), isFalse);
      },
    );
  });

  group('effectiveRoleKeys', () {
    const org = 'org-a';

    test('ignore les rôles d’une autre organisation', () {
      final keys = effectiveRoleKeys([
        {'role_key': 'collector', 'organization_id': org},
        {'role_key': 'admin', 'organization_id': 'org-b'},
      ], org);
      expect(keys, ['collector']);
    });

    test('conserve le rôle global super_admin sans organisation', () {
      final keys = effectiveRoleKeys([
        {'role_key': 'super_admin', 'organization_id': null},
        {'role_key': 'collector', 'organization_id': 'org-b'},
      ], null);
      expect(keys, ['super_admin']);
    });
  });
}
