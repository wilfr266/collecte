import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/offline_store.dart';
import '../../../core/network/offline_sync_manager.dart';
import '../../auth/presentation/auth_providers.dart';

class _OfflineOverview {
  const _OfflineOverview({
    required this.missions,
    required this.appointments,
    required this.operations,
    required this.operationsNeedingAttention,
  });

  final List<Map<String, dynamic>> missions;
  final List<Map<String, dynamic>> appointments;
  final List<OutboxOperation> operations;
  final List<OutboxOperation> operationsNeedingAttention;
}

final _offlineOverviewProvider = FutureProvider.autoDispose<_OfflineOverview>((
  ref,
) async {
  final user = ref.watch(authRepositoryProvider)?.currentUser;
  final store = ref.watch(offlineStoreProvider);
  if (user == null || store == null) {
    return const _OfflineOverview(
      missions: [],
      appointments: [],
      operations: [],
      operationsNeedingAttention: [],
    );
  }
  return _OfflineOverview(
    missions: await store.cachedRecordsForUser(
      category: 'missions',
      userId: user.id,
    ),
    appointments: await store.cachedRecordsForUser(
      category: 'appointments',
      userId: user.id,
    ),
    operations: await store.queuedOperations(ownerUserId: user.id),
    operationsNeedingAttention: await store.operationsNeedingAttention(
      ownerUserId: user.id,
    ),
  );
});

class OfflineOverviewPage extends ConsumerWidget {
  const OfflineOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(_offlineOverviewProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Données hors ligne')),
      body: overview.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => const Center(
          child: Text('Les données locales sont indisponibles.'),
        ),
        data: (data) => RefreshIndicator(
          onRefresh: () async {
            await ref
                .read(offlineSyncManagerProvider)
                ?.syncNow(forceRetry: true);
            ref.invalidate(_offlineOverviewProvider);
            await ref.read(_offlineOverviewProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Sans connexion : ces informations sont celles de votre dernière connexion. '
                    'Les montants ne sont pas actualisés et aucun paiement n’est confirmé.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Missions synchronisées',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (data.missions.isEmpty)
                const ListTile(
                  title: Text('Aucune mission enregistrée sur ce téléphone.'),
                )
              else
                for (final mission in data.missions)
                  ListTile(
                    leading: const Icon(Icons.route_outlined),
                    title: Text(mission['title'] as String? ?? 'Mission'),
                    subtitle: Text(
                      '${mission['zone_name'] ?? 'Zone'} · ${mission['scheduled_for'] ?? ''}',
                    ),
                  ),
              const SizedBox(height: 16),
              Text(
                'Rendez-vous synchronisés',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (data.appointments.isEmpty)
                const ListTile(
                  title: Text('Aucun rendez-vous enregistré sur ce téléphone.'),
                )
              else
                for (final appointment in data.appointments)
                  ListTile(
                    leading: const Icon(Icons.event_outlined),
                    title: Text(
                      appointment['establishment_name'] as String? ??
                          'Établissement',
                    ),
                    subtitle: Text(
                      '${appointment['starts_at'] ?? ''} · ${appointment['address'] ?? ''}',
                    ),
                  ),
              const SizedBox(height: 16),
              Text(
                'Opérations à synchroniser (${data.operations.length})',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (data.operations.isEmpty)
                const ListTile(title: Text('Aucune opération en attente.'))
              else
                for (final operation in data.operations)
                  ListTile(
                    leading: Icon(
                      operation.state == OutboxState.needsAttention
                          ? Icons.warning_amber
                          : Icons.cloud_upload_outlined,
                    ),
                    title: Text(
                      operation.operationType == 'collection_payment_request'
                          ? 'Visite et demande de paiement en attente'
                          : 'Opération en attente',
                    ),
                    subtitle: Text(
                      '${_queueState(operation.state)} · ${operation.attempts} tentative(s)',
                    ),
                  ),
              if (data.operationsNeedingAttention.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Intervention requise',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final operation in data.operationsNeedingAttention)
                  ListTile(
                    leading: const Icon(Icons.warning_amber),
                    title: const Text('Opération bloquée'),
                    subtitle: Text(
                      '${blockedOperationReason(operation.technicalError)} · ${operation.attempts} tentative(s)',
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  await ref
                      .read(offlineSyncManagerProvider)
                      ?.syncNow(forceRetry: true);
                  ref.invalidate(_offlineOverviewProvider);
                },
                icon: const Icon(Icons.sync),
                label: const Text('Réessayer la synchronisation'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _queueState(OutboxState state) => switch (state) {
  OutboxState.pending => 'En attente',
  OutboxState.syncing => 'Synchronisation',
  OutboxState.retryable => 'Nouvel essai programmé',
  OutboxState.needsAttention => 'Intervention requise',
  OutboxState.synced => 'Synchronisée',
};

/// Motif lisible d'une opération bloquée ; le code technique reste dans la
/// base locale pour le diagnostic.
String blockedOperationReason(String? code) => switch (code) {
  'retry_limit_reached' => 'Envoi impossible après plusieurs essais',
  '23505' => 'Opération déjà enregistrée',
  '42501' => 'Opération non autorisée pour votre compte',
  '22023' => 'Informations à vérifier',
  'network_or_server_unavailable' => 'Réseau indisponible',
  _ => 'Opération à vérifier',
};
