import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../../shared/widgets/state_views.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../missions/presentation/missions_page.dart';

/// Zones visibles du collecteur (RLS `can_access_zone` : zones des missions
/// affectées et actives) avec le nombre de missions qu'il y détient.
final collectorZonesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final profile = await ref.watch(currentProfileProvider.future);
      if (client == null || profile?.organizationId == null) return [];
      return client
          .from('zones')
          .select('id, name, code, is_active')
          .eq('organization_id', profile!.organizationId!)
          .order('name');
    });

class ZonesPage extends ConsumerWidget {
  const ZonesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zones = ref.watch(collectorZonesProvider);
    final missions = ref.watch(assignedMissionsProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Mes zones')),
      body: zones.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => StateMessageView.error(
          message: 'Les zones ne sont pas disponibles. Vérifiez le réseau.',
          onRetry: () => ref.invalidate(collectorZonesProvider),
        ),
        data: (items) => items.isEmpty
            ? const StateMessageView(
                icon: Icons.map_outlined,
                message:
                    'Aucune zone ne vous est accessible. Les zones apparaissent avec vos missions affectées ou en cours.',
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(collectorZonesProvider);
                  ref.invalidate(assignedMissionsProvider);
                  await ref.read(collectorZonesProvider.future);
                },
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final zone in items)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.map_outlined),
                          title: Text(zone['name'] as String),
                          subtitle: Text(
                            [
                              zone['code'] as String,
                              if (missions != null)
                                '${missions.where((m) => m.zoneId == zone['id']).length} mission(s)',
                            ].join(' · '),
                          ),
                          trailing: zone['is_active'] == true
                              ? null
                              : const Chip(label: Text('Inactive')),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
