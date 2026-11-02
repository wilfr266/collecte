import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../auth/presentation/auth_providers.dart';

/// Organisation de rattachement du profil (`organizations_read_member`).
final currentOrganizationProvider =
    FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final profile = await ref.watch(currentProfileProvider.future);
      if (client == null || profile?.organizationId == null) return null;
      return client
          .from('organizations')
          .select('id, name, code')
          .eq('id', profile!.organizationId!)
          .maybeSingle();
    });

class OrganizationCard extends ConsumerWidget {
  const OrganizationCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organization = ref.watch(currentOrganizationProvider);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.apartment_outlined),
        title: Text(
          organization.when(
            loading: () => 'Organisation…',
            error: (error, stackTrace) => 'Organisation indisponible',
            data: (row) => row?['name'] as String? ?? 'Aucune organisation',
          ),
        ),
        subtitle: Text(
          organization.valueOrNull?['code'] as String? ??
              'Organisation de rattachement',
        ),
      ),
    );
  }
}
