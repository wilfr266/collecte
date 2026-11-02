import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/supabase_client_provider.dart';
import '../../auth/presentation/auth_providers.dart';

final collectorCollectionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final client = ref.watch(supabaseClientProvider);
      final profile = await ref.watch(currentProfileProvider.future);
      if (client == null || profile?.organizationId == null) return [];
      return client
          .from('collections')
          .select('id, visited_at, outcome, status, establishments(name)')
          .eq('organization_id', profile!.organizationId!)
          .eq('collector_id', profile.id)
          .order('visited_at', ascending: false)
          .limit(50);
    });

class CollectionsPage extends ConsumerWidget {
  const CollectionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectorCollectionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Collectes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/new-collection'),
        icon: const Icon(Icons.add),
        label: const Text('Nouvelle visite'),
      ),
      body: collections.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Historique indisponible. Vérifiez la connexion.'),
          ),
        ),
        data: (items) => items.isEmpty
            ? const Center(child: Text('Aucune visite enregistrée.'))
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(collectorCollectionsProvider);
                  await ref.read(collectorCollectionsProvider.future);
                },
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  itemCount: items.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final row = items[index];
                    final establishment =
                        row['establishments'] as Map<String, dynamic>?;
                    final date = DateTime.parse(
                      row['visited_at'] as String,
                    ).toLocal();
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.fact_check_outlined),
                        title: Text(
                          establishment?['name'] as String? ?? 'Établissement',
                        ),
                        subtitle: Text(
                          '${_outcome(row['outcome'] as String)} · ${_dateLabel(date)}',
                        ),
                        trailing: Chip(
                          label: Text(_status(row['status'] as String)),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

String _status(String value) => switch (value) {
  'draft' => 'Brouillon',
  'submitted' => 'Transmise',
  'validated' => 'Validée',
  'rejected' => 'Refusée',
  _ => 'Annulée',
};

String _outcome(String value) => switch (value) {
  'contacted' => 'Contact effectué',
  'unavailable' => 'Absent',
  'refused' => 'Refus',
  _ => 'À revoir',
};

String _dateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
