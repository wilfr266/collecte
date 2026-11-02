import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_providers.dart';

/// Organisations visibles : celle du profil, ou toutes pour un
/// super-administrateur (RLS `organizations_read_member`).
final adminOrganizationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final profile = await ref.watch(currentProfileProvider.future);
      if (client == null || profile == null) return [];
      final query = client.from('organizations').select('id, name, code');
      return profile.organizationId == null
          ? query.order('name')
          : query.eq('id', profile.organizationId!);
    });

/// Membres de l'organisation et leurs rôles. Requiert `profile.manage`.
final adminMembersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final profile = await ref.watch(currentProfileProvider.future);
      final permissions = await ref.watch(currentPermissionsProvider.future);
      final organizationId = profile?.organizationId;
      if (client == null ||
          organizationId == null ||
          !permissions.contains('profile.manage')) {
        return [];
      }
      final members = await client
          .from('profiles')
          .select('id, display_name, phone, status')
          .eq('organization_id', organizationId)
          .order('display_name');
      final roles = await client
          .from('user_roles')
          .select('user_id, role_key')
          .eq('organization_id', organizationId);
      final rolesByUser = <String, List<String>>{};
      for (final row in roles) {
        rolesByUser
            .putIfAbsent(row['user_id'] as String, () => [])
            .add(row['role_key'] as String);
      }
      return [
        for (final member in members)
          {...member, 'role_keys': rolesByUser[member['id']] ?? <String>[]},
      ];
    });

/// Espace administration mobile — consultation uniquement.
///
/// Les fonctions affichées dépendent des permissions backend
/// (`role_permissions`) ; activation des comptes et attribution des rôles
/// restent dans le back-office via les RPC contrôlées (`assign_user_role`,
/// `link_client_taxpayer`).
class AdminPage extends ConsumerWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organizations = ref.watch(adminOrganizationsProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Administration')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(adminOrganizationsProvider);
          ref.invalidate(adminMembersProvider);
          await ref.read(adminOrganizationsProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Organisations',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            organizations.when(
              loading: () => const LinearProgressIndicator(),
              error: (error, stackTrace) =>
                  const Text('Les organisations ne sont pas disponibles.'),
              data: (items) => items.isEmpty
                  ? const Text('Aucune organisation visible.')
                  : Column(
                      children: [
                        for (final org in items)
                          Card(
                            child: ListTile(
                              leading: const Icon(Icons.apartment_outlined),
                              title: Text(org['name'] as String),
                              subtitle: Text(org['code'] as String),
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            if (permissions.valueOrNull?.contains('profile.manage') ?? false)
              const _MembersSection(),
            const SizedBox(height: 16),
            const Text(
              'L’activation des comptes et l’attribution des rôles se font depuis Terenza Admin.',
            ),
          ],
        ),
      ),
    );
  }
}

class _MembersSection extends ConsumerWidget {
  const _MembersSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(adminMembersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Membres', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        members.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, stackTrace) =>
              const Text('Les membres ne sont pas disponibles.'),
          data: (items) {
            if (items.isEmpty) return const Text('Aucun membre.');
            final pending = items.where((m) => m['status'] == 'pending').length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pending > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('$pending compte(s) en attente d’activation'),
                  ),
                for (final member in items)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(member['display_name'] as String),
                      subtitle: Text(
                        _roleLabels(member['role_keys'] as List<String>),
                      ),
                      trailing: Chip(
                        label: Text(_statusLabel(member['status'] as String)),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

String _roleLabels(List<String> keys) {
  final labels = keys
      .map(UserRole.fromKey)
      .whereType<UserRole>()
      .map((role) => role.label)
      .toList();
  return labels.isEmpty ? 'Aucun rôle' : labels.join(', ');
}

/// Statut du compte (`profiles.status`) — distinct des rôles.
String _statusLabel(String status) => switch (status) {
  'active' => 'Actif',
  'pending' => 'En attente',
  'suspended' => 'Suspendu',
  'disabled' => 'Désactivé',
  _ => status,
};
